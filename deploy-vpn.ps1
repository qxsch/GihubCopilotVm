<#
.SYNOPSIS
    Deploys a hub VNet with a Point-to-Site VPN Gateway and creates a local
    Windows VPN connection profile (split-tunnel, VNet prefixes only).

.DESCRIPTION
    1. Creates a hub VNet with a GatewaySubnet
    2. Deploys an Azure VPN Gateway with P2S (IKEv2) using self-signed certificates
    3. Generates a root + client certificate locally for authentication
    4. Creates a Windows VPN connection (split-tunnel — only VNet prefixes routed)
    5. Tests connectivity

.EXAMPLE
    .\deploy-vpn.ps1
    .\deploy-vpn.ps1 -ResourceGroup "myhub" -vnetSpace "10.1.0.0/23"
    .\deploy-vpn.ps1 -LocalVpnProfileName "office-vpn" -Location "West Europe"
    .\deploy-vpn.ps1 -RemoveVpn
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Name for the local Windows VPN connection profile")]
    [string]$LocalVpnProfileName = "hubnet",

    [Parameter(HelpMessage = "Azure resource group name")]
    [string]$ResourceGroup = "hubnet",

    [Parameter(HelpMessage = "Azure region")]
    [string]$Location = "Norway East",

    [Parameter(HelpMessage = "VNet address space in CIDR (minimum /23)")]
    [string]$vnetSpace = "10.0.0.0/23",

    [Parameter(HelpMessage = "VPN Gateway SKU")]
    [ValidateSet("VpnGw1AZ", "VpnGw2AZ")]
    [string]$GatewaySku = "VpnGw1AZ",

    [Parameter(HelpMessage = "Remove VPN gateway, public IP, and local profile (VNet is kept)")]
    [switch]$RemoveVpn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Step { param([string]$Msg) Write-Host "`n▸ $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }

# Detect whether we can use \r-based spinner animation.
# Disabled in CI/CD pipelines (where \r produces garbage in build logs)
# and in hosts that don't expose a cursor (ISE, redirected output, etc.).
$script:CanAnimateSpinner = $false
if (-not ($env:CI -or $env:TF_BUILD -or $env:GITHUB_ACTIONS -or $env:JENKINS_URL -or $env:GITLAB_CI -or $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI)) {
    try { $null = $Host.UI.RawUI.CursorPosition; $script:CanAnimateSpinner = $true } catch {}
}

function Invoke-LocalStep {
    <#
    .SYNOPSIS
        Runs a script block as a background job with tree-line progress output
        and an animated spinner while the command executes.
    #>
    param(
        [string]$StepName,
        [scriptblock]$Script,
        [object[]]$ArgumentList
    )

    Write-Host "  ┌─ $StepName…" -ForegroundColor DarkCyan
    $failed = $false
    $output = $null
    $spinner = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $spinIdx = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $spinnerOnLine = $false

    try {
        $jobParams = @{ ScriptBlock = $Script }
        if ($ArgumentList) { $jobParams['ArgumentList'] = $ArgumentList }
        $job = Start-Job @jobParams

        # Animate spinner while job runs
        while ($job.State -eq 'Running') {
            if ($script:CanAnimateSpinner) {
                $s = $spinner[$spinIdx % $spinner.Count]; $spinIdx++
                $elapsed = [math]::Floor($sw.Elapsed.TotalSeconds)
                Write-Host "`r  │  $s Running… (${elapsed}s)   " -NoNewline -ForegroundColor DarkGray
                $spinnerOnLine = $true
                Start-Sleep -Milliseconds 150
            } else {
                Start-Sleep -Seconds 2
            }
        }

        # Clear spinner line
        if ($spinnerOnLine) {
            Write-Host "`r$(' ' * 70)`r" -NoNewline
            $spinnerOnLine = $false
        }

        $output = Receive-Job -Job $job -ErrorAction Stop 2>&1
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

        foreach ($line in $output) {
            $text = "$line".Trim()
            if (-not $text) { continue }
            if ($line -is [System.Management.Automation.ErrorRecord]) {
                Write-Host "  │  ✗ $text" -ForegroundColor Red
                $failed = $true
            } else {
                Write-Host "  │  $text" -ForegroundColor DarkGray
            }
        }
    } catch {
        if ($spinnerOnLine) { Write-Host "`r$(' ' * 70)`r" -NoNewline }
        Write-Host "  │  ✗ $_" -ForegroundColor Red
        $failed = $true
    }

    $elapsed = [math]::Floor($sw.Elapsed.TotalSeconds)
    if ($failed) {
        Write-Host "  └─ $StepName — completed with warnings (${elapsed}s)" -ForegroundColor Yellow
    } else {
        Write-Host "  └─ $StepName ✓ (${elapsed}s)" -ForegroundColor Green
    }

    # Return last non-error output for callers that need the result
    if ($output) { return ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Select-Object -Last 1 }
}

# ── Remove VPN (early exit) ──────────────────────────────────────────────────
if ($RemoveVpn) {
    Write-Step "Removing VPN resources (VNet will be kept)"

    # Remove local VPN profile
    $existingVpn = Get-VpnConnection -Name $LocalVpnProfileName -ErrorAction SilentlyContinue
    if ($existingVpn) {
        if ($existingVpn.ConnectionStatus -eq 'Connected') {
            rasdial $LocalVpnProfileName /disconnect | Out-Null
            Write-Ok "Disconnected VPN '$LocalVpnProfileName'"
        }
        Remove-VpnConnection -Name $LocalVpnProfileName -Force
        Write-Ok "Removed local VPN profile '$LocalVpnProfileName'"
    } else {
        Write-Ok "Local VPN profile '$LocalVpnProfileName' not found (already removed)"
    }

    # Check Azure login
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Connect-AzAccount
    }

    # Remove VPN Gateway
    $gwName = "hub-vpngw"
    $gw = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroup -Name $gwName -ErrorAction SilentlyContinue
    if ($gw) {
        Write-Host "  Removing VPN Gateway '$gwName' (this takes ~10-20 minutes)…" -ForegroundColor Yellow
        Remove-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroup -Name $gwName -Force
        Write-Ok "VPN Gateway '$gwName' removed"
    } else {
        Write-Ok "VPN Gateway '$gwName' not found (already removed)"
    }

    # Remove Public IP
    $gwPipName = "hub-vpngw-pip"
    $pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName -ErrorAction SilentlyContinue
    if ($pip) {
        Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName -Force
        Write-Ok "Public IP '$gwPipName' removed"
    } else {
        Write-Ok "Public IP '$gwPipName' not found (already removed)"
    }

    Write-Step "Done — VPN removed. VNet 'hub-vnet' preserved."
    Write-Host "  To recreate: .\deploy-vpn.ps1 -ResourceGroup '$ResourceGroup'" -ForegroundColor Green
    return
}

# ── Validate CIDR ────────────────────────────────────────────────────────────
Write-Step "Validating parameters"

if ($vnetSpace -notmatch '^(\d{1,3}\.){3}\d{1,3}/(\d{1,2})$') {
    throw "Invalid CIDR format for vnetSpace: '$vnetSpace'. Expected format: x.x.x.x/n"
}
$cidrPrefix = [int]($vnetSpace -split '/')[1]
if ($cidrPrefix -gt 23) {
    throw "vnetSpace must be /23 or larger (lower prefix number). Got /$cidrPrefix. A VPN Gateway requires at least a /27 GatewaySubnet plus usable space."
}
Write-Ok "VNet space: $vnetSpace (/$cidrPrefix)"

# ── Derive subnets ───────────────────────────────────────────────────────────
# GatewaySubnet: first /27 of the VNet space
# Default subnet: second half of the space
$baseIp = ($vnetSpace -split '/')[0]
$octets = $baseIp -split '\.'

# GatewaySubnet = baseIp/27 (first 32 IPs)
$gatewaySubnetPrefix = "$baseIp/27"

# Default subnet = baseIp with 3rd octet +1, /24
$defaultSubnetOctet3 = [int]$octets[2] + 1
$defaultSubnetPrefix = "$($octets[0]).$($octets[1]).$defaultSubnetOctet3.0/24"

# VPN client address pool (non-overlapping with VNet)
$vpnClientPoolPrefix = "172.16.201.0/24"

Write-Ok "GatewaySubnet: $gatewaySubnetPrefix"
Write-Ok "Default subnet: $defaultSubnetPrefix"
Write-Ok "VPN client pool: $vpnClientPoolPrefix"

# ── Pre-flight: Az module + login ────────────────────────────────────────────
Write-Step "Checking Az PowerShell module"
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    throw "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser"
}

Write-Step "Checking Azure login"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Host "  Not logged in. Running Connect-AzAccount…" -ForegroundColor Yellow
    Connect-AzAccount
    $ctx = Get-AzContext
}
Write-Ok "Signed in as $($ctx.Account.Id) — subscription: $($ctx.Subscription.Name)"

# ── Resource Group ───────────────────────────────────────────────────────────
Write-Step "Ensuring resource group '$ResourceGroup' in '$Location'"
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    Invoke-LocalStep -StepName "Creating resource group" -Script {
        param($rg, $loc)
        New-AzResourceGroup -Name $rg -Location $loc | Out-Null
        "Resource group '$rg' created in $loc"
    } -ArgumentList @($ResourceGroup, $Location)
    $rg = Get-AzResourceGroup -Name $ResourceGroup
} else {
    Write-Ok "Resource group already exists"
}

# ── Virtual Network ──────────────────────────────────────────────────────────
Write-Step "Creating VNet 'hub-vnet'"
$vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name "hub-vnet" -ErrorAction SilentlyContinue
if (-not $vnet) {
    Invoke-LocalStep -StepName "Provisioning hub-vnet" -Script {
        param($rg, $loc, $addrSpace, $gwPrefix, $defPrefix)
        $gwSub = New-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -AddressPrefix $gwPrefix
        $defSub = New-AzVirtualNetworkSubnetConfig -Name "default" -AddressPrefix $defPrefix
        New-AzVirtualNetwork -ResourceGroupName $rg -Name "hub-vnet" `
            -Location $loc -AddressPrefix $addrSpace -Subnet $gwSub, $defSub | Out-Null
        "hub-vnet created ($addrSpace) with GatewaySubnet ($gwPrefix) + default ($defPrefix)"
    } -ArgumentList @($ResourceGroup, $Location, $vnetSpace, $gatewaySubnetPrefix, $defaultSubnetPrefix)
    $vnet = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name "hub-vnet"
} else {
    Write-Ok "hub-vnet already exists"
}

# ── Public IP for VPN Gateway ────────────────────────────────────────────────
Write-Step "Creating Public IP for VPN Gateway"
$gwPipName = "hub-vpngw-pip"
$gwPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName -ErrorAction SilentlyContinue
if (-not $gwPip) {
    Invoke-LocalStep -StepName "Allocating public IP (zone-redundant)" -Script {
        param($rg, $loc, $name)
        $pip = New-AzPublicIpAddress -ResourceGroupName $rg -Name $name `
            -Location $loc -AllocationMethod Static -Sku Standard -Zone @("1","2","3")
        "Public IP allocated: $($pip.IpAddress)"
    } -ArgumentList @($ResourceGroup, $Location, $gwPipName)
    $gwPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName
} else {
    # If existing PIP has no zones, recreate it (required for AZ gateway SKUs)
    if (-not $gwPip.Zones -or $gwPip.Zones.Count -eq 0) {
        Write-Warn "Existing PIP has no zones — recreating for AZ SKU compatibility"
        Remove-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName -Force
        Invoke-LocalStep -StepName "Re-allocating public IP (zone-redundant)" -Script {
            param($rg, $loc, $name)
            $pip = New-AzPublicIpAddress -ResourceGroupName $rg -Name $name `
                -Location $loc -AllocationMethod Static -Sku Standard -Zone @("1","2","3")
            "Public IP allocated: $($pip.IpAddress)"
        } -ArgumentList @($ResourceGroup, $Location, $gwPipName)
        $gwPip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $gwPipName
    } else {
        Write-Ok "Public IP already exists: $($gwPip.IpAddress)"
    }
}

# ── Self-Signed Certificates ────────────────────────────────────────────────
Write-Step "Generating VPN certificates"
$rootCertName = "HubVpnRootCA"
$clientCertName = "HubVpnClient"

# Check if root cert already exists in CurrentUser\My
$rootCert = Get-ChildItem -Path "Cert:\CurrentUser\My" | Where-Object { $_.Subject -eq "CN=$rootCertName" } | Select-Object -First 1

if (-not $rootCert) {
    $rootCert = New-SelfSignedCertificate -Type Custom -KeySpec Signature `
        -Subject "CN=$rootCertName" -KeyExportPolicy Exportable `
        -HashAlgorithm sha256 -KeyLength 4096 `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyUsageProperty Sign -KeyUsage CertSign `
        -NotAfter (Get-Date).AddYears(5)
    Write-Ok "Generated root certificate: $rootCertName"
} else {
    Write-Ok "Root certificate already exists: $rootCertName"
}

$clientCert = Get-ChildItem -Path "Cert:\CurrentUser\My" | Where-Object { $_.Subject -eq "CN=$clientCertName" } | Select-Object -First 1
if (-not $clientCert) {
    $clientCert = New-SelfSignedCertificate -Type Custom -KeySpec Signature `
        -Subject "CN=$clientCertName" -KeyExportPolicy Exportable `
        -HashAlgorithm sha256 -KeyLength 4096 `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -Signer $rootCert `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.2") `
        -NotAfter (Get-Date).AddYears(3)
    Write-Ok "Generated client certificate: $clientCertName"
} else {
    Write-Ok "Client certificate already exists: $clientCertName"
}

# Export root cert public key as Base64
$rootCertBase64 = [Convert]::ToBase64String($rootCert.RawData)

# ── VPN Gateway ──────────────────────────────────────────────────────────────
Write-Step "Deploying VPN Gateway (this typically takes 20-40 minutes)"
$gwName = "hub-vpngw"
$gw = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroup -Name $gwName -ErrorAction SilentlyContinue

if (-not $gw) {
    $gwSubnet = Get-AzVirtualNetworkSubnetConfig -Name "GatewaySubnet" -VirtualNetwork $vnet
    $gwSubnetId = $gwSubnet.Id
    $gwPipId = $gwPip.Id

    Invoke-LocalStep -StepName "Provisioning VPN Gateway ($GatewaySku, P2S IKEv2)" -Script {
        param($rg, $loc, $name, $subnetId, $pipId, $clientPool, $certName, $certData, $sku)
        $ipCfg = New-AzVirtualNetworkGatewayIpConfig -Name "gwIpConfig" `
            -SubnetId $subnetId -PublicIpAddressId $pipId
        $rootCert = New-AzVpnClientRootCertificate -Name $certName -PublicCertData $certData
        New-AzVirtualNetworkGateway -ResourceGroupName $rg -Name $name `
            -Location $loc -IpConfigurations $ipCfg `
            -GatewayType Vpn -VpnType RouteBased -GatewaySku $sku `
            -VpnClientAddressPool $clientPool `
            -VpnClientProtocol @("IkeV2") `
            -VpnClientRootCertificates $rootCert | Out-Null
        "VPN Gateway '$name' deployed with P2S IKEv2 ($clientPool), SKU=$sku"
    } -ArgumentList @($ResourceGroup, $Location, $gwName, $gwSubnetId, $gwPipId, $vpnClientPoolPrefix, $rootCertName, $rootCertBase64, $GatewaySku)
    $gw = Get-AzVirtualNetworkGateway -ResourceGroupName $ResourceGroup -Name $gwName -ErrorAction SilentlyContinue
    if (-not $gw) {
        throw "VPN Gateway creation failed. Check the errors above."
    }
} else {
    Write-Ok "VPN Gateway already exists"

    # Ensure root cert is configured on existing gateway
    $existingRootCerts = $gw.VpnClientConfiguration.VpnClientRootCertificates
    $certExists = $existingRootCerts | Where-Object { $_.Name -eq $rootCertName }
    if (-not $certExists) {
        Invoke-LocalStep -StepName "Adding root certificate to gateway" -Script {
            param($certName, $gwName, $rg, $certData)
            Add-AzVpnClientRootCertificate -VpnClientRootCertificateName $certName `
                -VirtualNetworkGatewayName $gwName -ResourceGroupName $rg `
                -PublicCertData $certData | Out-Null
            "Root certificate '$certName' added"
        } -ArgumentList @($rootCertName, $gwName, $ResourceGroup, $rootCertBase64)
    }
}

# ── Create Windows VPN Profile (Split Tunnel) ───────────────────────────────
Write-Step "Creating local Windows VPN connection profile '$LocalVpnProfileName'"

# Generate the VPN client configuration package from the gateway
# This package contains the correct FQDN, EAP-TLS XML, and gateway root certificate
Write-Host "  Generating VPN client configuration from gateway…" -ForegroundColor DarkGray
$vpnProfile = New-AzVpnClientConfiguration -ResourceGroupName $ResourceGroup -Name $gwName -AuthenticationMethod "EapTls"
$vpnProfileUrl = $vpnProfile.VPNProfileSASUrl
if (-not $vpnProfileUrl) {
    throw "Failed to generate VPN client configuration package from gateway."
}

# Download and extract the VPN client config package
$vpnZipPath = Join-Path $env:TEMP "vpnclientconfig_$ResourceGroup.zip"
$vpnExtractPath = Join-Path $env:TEMP "vpnclientconfig_$ResourceGroup"
Invoke-WebRequest -Uri $vpnProfileUrl -OutFile $vpnZipPath
if (Test-Path $vpnExtractPath) { Remove-Item $vpnExtractPath -Recurse -Force }
Expand-Archive $vpnZipPath -DestinationPath $vpnExtractPath -Force

# Parse VpnSettings.xml for the gateway FQDN
$vpnSettingsXml = [xml](Get-Content (Join-Path $vpnExtractPath "Generic\VpnSettings.xml"))
$vpnServerAddress = $vpnSettingsXml.VpnProfile.VpnServer
Write-Ok "Gateway FQDN: $vpnServerAddress"

# Read the EAP-TLS XML from the Microsoft-generated PowerShell setup script
$setupScript = Get-Content (Join-Path $vpnExtractPath "WindowsPowershell\VpnProfileSetup.ps1") -Raw
if ($setupScript -match "(?s)\`\$EAP\s*=\s*'(.*?)'") {
    $eapXml = $Matches[1]
} else {
    throw "Could not extract EAP configuration from VPN client package."
}

# Remove existing VPN connection with same name if present
$existingVpn = Get-VpnConnection -Name $LocalVpnProfileName -ErrorAction SilentlyContinue
if ($existingVpn) {
    Remove-VpnConnection -Name $LocalVpnProfileName -Force
    Write-Warn "Removed existing VPN profile '$LocalVpnProfileName'"
}

# Create VPN connection with EAP-TLS (cert from CurrentUser\My)
Add-VpnConnection -Name $LocalVpnProfileName `
    -ServerAddress $vpnServerAddress `
    -TunnelType Ikev2 `
    -AuthenticationMethod Eap `
    -EncryptionLevel Optional `
    -SplitTunneling `
    -RememberCredential `
    -EapConfigXmlStream $eapXml `
    -PassThru | Out-Null

# Adjust PBK file settings for proper IKEv2 routing
$pbkPath = Join-Path $env:APPDATA "Microsoft\Network\Connections\Pbk\rasphone.pbk"
if (Test-Path $pbkPath) {
    $pbk = Get-Content -Raw -Path $pbkPath
    $pbk = $pbk -replace "(?s)(.*)DisableClassBasedDefaultRoute=0(.*)", "`$1DisableClassBasedDefaultRoute=1`$2"
    $pbk = $pbk -replace "(?s)(.*)PlumbIKEv2TSAsRoutes=0(.*)", "`$1PlumbIKEv2TSAsRoutes=1`$2"
    Set-Content -Path $pbkPath -Value $pbk
}

# Add routes for VNet and VPN client pool (split tunnel)
Add-VpnConnectionRoute -ConnectionName $LocalVpnProfileName `
    -DestinationPrefix $vnetSpace -PassThru | Out-Null
Add-VpnConnectionRoute -ConnectionName $LocalVpnProfileName `
    -DestinationPrefix $vpnClientPoolPrefix -PassThru | Out-Null

Write-Ok "VPN profile created with EAP-TLS (split tunneling)"
Write-Ok "Routes added: $vnetSpace, $vpnClientPoolPrefix → VPN tunnel"
Write-Host "  (No default 0.0.0.0/0 route — only VNet traffic goes through VPN)" -ForegroundColor DarkGray

# ── Test Connection ──────────────────────────────────────────────────────────
Write-Step "Testing VPN connection"

Write-Host "  ┌─ Connecting to VPN '$LocalVpnProfileName'…" -ForegroundColor DarkCyan
try {
    rasdial $LocalVpnProfileName | Out-Null
    Start-Sleep -Seconds 5

    # Get VPN connection status
    $vpnStatus = Get-VpnConnection -Name $LocalVpnProfileName
    if ($vpnStatus.ConnectionStatus -eq 'Connected') {
        Write-Host "  │  VPN connected" -ForegroundColor DarkGray

        # Test connectivity to an IP in the VNet
        $testIp = $baseIp
        Write-Host "  │  Testing route to $testIp…" -ForegroundColor DarkGray

        $routeTest = Test-NetConnection -ComputerName $testIp -Port 443 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
        if ($routeTest.PingSucceeded -or $routeTest.TcpTestSucceeded) {
            Write-Host "  │  Network reachability confirmed to $testIp" -ForegroundColor DarkGray
        } else {
            Write-Host "  │  No response from $testIp (expected if no resources running yet)" -ForegroundColor DarkGray
            Write-Host "  │  VPN tunnel is UP — deploy resources to test further" -ForegroundColor DarkGray
        }

        # Show routing table for VPN
        Write-Host "  │" -ForegroundColor DarkCyan
        Write-Host "  │  Active routes via VPN:" -ForegroundColor DarkGray
        Get-NetRoute -InterfaceAlias $LocalVpnProfileName -ErrorAction SilentlyContinue |
            Format-Table DestinationPrefix, NextHop, RouteMetric -AutoSize |
            Out-String -Stream | Where-Object { $_.Trim() } |
            ForEach-Object { Write-Host "  │    $_" -ForegroundColor DarkGray }

        Write-Host "  └─ Connection test ✓" -ForegroundColor Green
    } else {
        Write-Host "  │  VPN status: $($vpnStatus.ConnectionStatus)" -ForegroundColor DarkGray
        Write-Host "  └─ Connection test — not connected" -ForegroundColor Yellow
        Write-Host "  Try manually: rasdial '$LocalVpnProfileName'" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  │  ✗ Could not auto-connect: $_" -ForegroundColor Red
    Write-Host "  └─ Connection test — skipped" -ForegroundColor Yellow
    Write-Host "  Connect manually via Windows Settings > Network > VPN, or run:" -ForegroundColor Yellow
    Write-Host "    rasdial '$LocalVpnProfileName'" -ForegroundColor Yellow
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Step "Summary"
Write-Host ""
Write-Host "  VPN Gateway:       $gwName" -ForegroundColor White
Write-Host "  Server Address:    $vpnServerAddress" -ForegroundColor White
Write-Host "  VNet:              hub-vnet ($vnetSpace)" -ForegroundColor White
Write-Host "  VNet Resource ID:  $($vnet.Id)" -ForegroundColor White
Write-Host "  GatewaySubnet:     $gatewaySubnetPrefix" -ForegroundColor White
Write-Host "  Default Subnet:    $defaultSubnetPrefix" -ForegroundColor White
Write-Host "  VPN Client Pool:   $vpnClientPoolPrefix" -ForegroundColor White
Write-Host "  Local Profile:     $LocalVpnProfileName" -ForegroundColor White
Write-Host "  Tunnel Type:       IKEv2 + EAP-TLS (split-tunnel)" -ForegroundColor White
Write-Host "  Root Cert:         $rootCertName (Cert:\CurrentUser\My)" -ForegroundColor White
Write-Host "  Client Cert:       $clientCertName (Cert:\CurrentUser\My)" -ForegroundColor White
Write-Host ""
Write-Host "  To connect:    rasdial '$LocalVpnProfileName'" -ForegroundColor Green
Write-Host "  To disconnect: rasdial '$LocalVpnProfileName' /disconnect" -ForegroundColor Green
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  💰 COST WARNING — VPN Gateway" -ForegroundColor Yellow
Write-Host "" -ForegroundColor Yellow
Write-Host "  VPN Gateways CANNOT be paused/stopped. To stop charges," -ForegroundColor Yellow
Write-Host "  you must DELETE the gateway (takes ~20-40 min to recreate):" -ForegroundColor Yellow
Write-Host "" -ForegroundColor Yellow
Write-Host "  🗑  DELETE (stop all charges):" -ForegroundColor Yellow
Write-Host "     .\deploy-vpn.ps1 -ResourceGroup '$ResourceGroup' -RemoveVpn" -ForegroundColor White
Write-Host "" -ForegroundColor Yellow
Write-Host "  ▶  RECREATE (re-run this script — it's idempotent):" -ForegroundColor Yellow
Write-Host "     .\deploy-vpn.ps1 -ResourceGroup '$ResourceGroup'" -ForegroundColor White
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
