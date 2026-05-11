<#
.SYNOPSIS
    Deploys a Windows 11 dev VM to Azure with Docker Desktop, Python, PowerShell 7, Az module, and VS Code.

.DESCRIPTION
    Creates an Azure resource group, deploys the Bicep infrastructure template, and
    installs software on the VM via PowerShell Remoting (WinRM HTTPS) with step-by-step
    streaming output.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ResourceGroup myRg -Location eastus
    .\deploy.ps1 -VMUser admin -VMPassword 'MyP@ss1234!'
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage = "Resource group name")]
    [string]$ResourceGroup = "ghcpshell",

    [Parameter(HelpMessage = "VM admin username")]
    [string]$VMUser = "ghcpdev",

    [Parameter(HelpMessage = "VM admin password")]
    [string]$VMPassword = "",

    [Parameter(HelpMessage = "Azure region")]
    [string]$Location = "Norway East",

    [Parameter(HelpMessage = "VM resource name")]
    [string]$VMName = "ghcp-vm",

    [Parameter(HelpMessage = "VM size (must support nested virtualization)")]
    [string]$VMSize = "Standard_D4s_v5",

    [Parameter(HelpMessage = "Path to write an .rdp profile file (empty = skip generation)")]
    [string]$MstscProfilePath = "",

    [Parameter(HelpMessage = "Launch mstsc with the generated .rdp profile after deployment")]
    [switch]$OpenMstsc,

    [Parameter(HelpMessage = "Resource ID of hub VNet to peer with (for VPN gateway access)")]
    [string]$HubVnetId = "",

    [Parameter(HelpMessage = "Disable public IP on the VM (use private IP via VPN instead)")]
    [switch]$DisablePublicIp,

    [Parameter(HelpMessage = "Deploy VS Code Web interface (HTTPS proxy with login)")]
    [switch]$InstallVsCodeWeb,

    [Parameter(HelpMessage = "Password for VS Code Web login (defaults to VMPassword)")]
    [string]$VsCodeWebPassword = "",

    [Parameter(HelpMessage = "Domain name for VS Code Web (enables ACME cert renewal)")]
    [string]$VsCodeWebHost = ""
)

if($VsCodeWebPassword -ne "" -and -not $InstallVsCodeWeb) {
    Write-Warn "VsCodeWebPassword provided without -InstallVsCodeWeb. Enabling VS Code Web installation. Next time please also add -InstallVsCodeWeb and this warning will not appear."
    $InstallVsCodeWeb = $true
}
if($VsCodeWebHost -ne "" -and -not $InstallVsCodeWeb) {
    if(-not $DisablePublicIp) {
        Write-Warn "VsCodeWebHost provided without -InstallVsCodeWeb. Enabling VS Code Web installation. Next time please also add -InstallVsCodeWeb and this warning will not appear."
        $InstallVsCodeWeb = $true
    }
}
if ($DisablePublicIp -and $VsCodeWebHost) {
    throw "Unsupported configuration: -DisablePublicIp and -VsCodeWebHost are mutually exclusive. Host-based VS Code Web uses certbot and requires a public IP. Please remove one of these parameters and rerun the script."
}

if($VMPassword.Length -lt 12 -or -not ($VMPassword -match '[A-Z]') -or -not ($VMPassword -match '[a-z]') -or -not ($VMPassword -match '\d')) {
    throw "VMPassword must be at least 12 characters long and contain at least one uppercase letter, one lowercase letter, and one digit."
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InfraPath = Join-Path $PSScriptRoot "infra"

# ── Helpers ──────────────────────────────────────────────────────────────────
function Write-Step { param([string]$Msg) Write-Host "`n▸ $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  ✓ $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  ⚠ $Msg" -ForegroundColor Yellow }

function Invoke-InSubscription {
    <#
    .SYNOPSIS
        Executes a script block in the context of a different Azure subscription,
        then restores the original subscription. No-op if already in that subscription.
    .PARAMETER SubscriptionId
        The subscription GUID to switch to.
    .PARAMETER ResourceId
        An Azure resource ID — the subscription is extracted automatically.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'BySub')]
        [string]$SubscriptionId,

        [Parameter(Mandatory, ParameterSetName = 'ByResource')]
        [string]$ResourceId,

        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    if ($PSCmdlet.ParameterSetName -eq 'ByResource') {
        if ($ResourceId -notmatch '^/subscriptions/[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}/') {
            throw "Invalid ResourceId: expected format /subscriptions/{guid}/... — got: $ResourceId"
        }
        $SubscriptionId = ($ResourceId -split '/')[2]
    }
    $private:__invSub_originalId = (Get-AzContext).Subscription.Id
    $private:__invSub_switched = $false
    try {
        if ($SubscriptionId -ne $__invSub_originalId) {
            Set-AzContext -SubscriptionId $SubscriptionId -Scope Process | Out-Null
            $__invSub_switched = $true
        }
        & $ScriptBlock
    } finally {
        if ($__invSub_switched) {
            Set-AzContext -SubscriptionId $__invSub_originalId -Scope Process | Out-Null
        }
    }
}

function Resolve-VmNetworkResources {
    <#
    .SYNOPSIS
        Resolves NSG name, PIP name, and public IP for an existing VM.
        Tries convention-based names first, falls back to drilling through NIC/subnet.
    .OUTPUTS
        Hashtable with keys: NsgName, PipName, PublicIp
    #>
    param(
        [string]$ResourceGroup,
        [string]$VMName,
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM
    )
    $nsgName = "$VMName-nsg"
    $pipName = "$VMName-pip"
    $pipId = $null
    $nsgConv = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName -ErrorAction SilentlyContinue
    $pipConv = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $pipName -ErrorAction SilentlyContinue
    if (-not $nsgConv -or -not $pipConv) {
        Write-Host "  Convention names not found — resolving via VM network interfaces..." -ForegroundColor Yellow
        $nicId = $VM.NetworkProfile.NetworkInterfaces[0].Id
        $nic   = Get-AzNetworkInterface -ResourceId $nicId
        # PIP from NIC IP configuration
        $pipId = $nic.IpConfigurations[0].PublicIpAddress.Id
        if ($pipId) { $pipName = $pipId.Split('/')[-1] }
        # NSG: check NIC first, then subnet
        $nsgId = $nic.NetworkSecurityGroup.Id
        if (-not $nsgId) {
            $subnetId   = $nic.IpConfigurations[0].Subnet.Id
            $vnetName   = $subnetId.Split('/')[8]
            $subnetName = $subnetId.Split('/')[10]
            $vnet       = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroup -Name $vnetName
            $subnet     = $vnet.Subnets | Where-Object { $_.Name -eq $subnetName }
            $nsgId      = $subnet.NetworkSecurityGroup.Id
        }
        if ($nsgId) { $nsgName = $nsgId.Split('/')[-1] }
    }
    if ($pipConv -or ($pipId -and $pipId -ne '')) {
        $pipRes = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $pipName -ErrorAction SilentlyContinue
        $ip = if ($pipRes) { $pipRes.IpAddress } else { $null }
    } else {
        $ip = $null
    }
    # Fall back to private IP if no public IP
    if (-not $ip) {
        $nicId = $VM.NetworkProfile.NetworkInterfaces[0].Id
        $nicObj = Get-AzNetworkInterface -ResourceId $nicId
        $ip = $nicObj.IpConfigurations[0].PrivateIpAddress
    }
    return @{ NsgName = $nsgName; PipName = $pipName; ConnectIp = $ip }
}

# Detect whether we can use \r-based spinner animation.
# Disabled in CI/CD pipelines (where \r produces garbage in build logs)
# and in hosts that don't expose a cursor (ISE, redirected output, etc.).
$script:CanAnimateSpinner = $false
if (-not ($env:CI -or $env:TF_BUILD -or $env:GITHUB_ACTIONS -or $env:JENKINS_URL -or $env:GITLAB_CI -or $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI)) {
    try { $null = $Host.UI.RawUI.CursorPosition; $script:CanAnimateSpinner = $true } catch {}
}

function Invoke-RemoteStep {
    <#
    .SYNOPSIS
        Runs a script block on the remote session with tree-line progress output
        and an animated spinner while the command executes.
    #>
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$StepName,
        [scriptblock]$Script,
        [object[]]$ArgumentList
    )

    Write-Host "  ┌─ $StepName…" -ForegroundColor DarkCyan
    $failed = $false
    $spinner = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
    $spinIdx = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $spinnerOnLine = $false

    try {
        # Run remote command as a job so we can animate while it executes
        $jobParams = @{ Session = $Session; ScriptBlock = $Script }
        if ($ArgumentList) { $jobParams['ArgumentList'] = $ArgumentList }
        $job = Invoke-Command @jobParams -AsJob

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
}

# ── Pre-flight: Az module + login ────────────────────────────────────────────
Write-Step "Checking Az PowerShell module"
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az PowerShell module not found. Install with: Install-Module -Name Az -Scope CurrentUser"
}

Write-Step "Checking Azure login"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-Host "  Not logged in. Running Connect-AzAccount…" -ForegroundColor Yellow
    Connect-AzAccount
    $ctx = Get-AzContext
}
Write-Ok "Signed in as $($ctx.Account.Id) — subscription: $($ctx.Subscription.Name)"

# ── Configuration ────────────────────────────────────────────────────────────
Write-Step "Configuration"
Write-Host ""
Write-Host "  Resource Group : $ResourceGroup"   -ForegroundColor White
Write-Host "  Location       : $Location"         -ForegroundColor White
Write-Host "  VM Name        : $VMName"            -ForegroundColor White
Write-Host "  VM Size        : $VMSize"            -ForegroundColor White
Write-Host "  Admin User     : $VMUser"            -ForegroundColor White

# ── Start overall deployment timer ───────────────────────────────────────────
$deployStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ── Resource Group ───────────────────────────────────────────────────────────
Write-Step "Ensuring resource group '$ResourceGroup' in '$Location'"
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $ResourceGroup -Location $Location -Force | Out-Null
    Write-Ok "Created resource group"
} else {
    Write-Ok "Resource group already exists"
}

# ── Bicep deployment (idempotent — skipped if VM already exists) ─────────────
$securePassword = ConvertTo-SecureString $VMPassword -AsPlainText -Force
$existingVm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction SilentlyContinue

if ($existingVm) {
    Write-Step "VM '$VMName' already exists — skipping Bicep deployment"
    $resolved = Resolve-VmNetworkResources -ResourceGroup $ResourceGroup -VMName $VMName -VM $existingVm
    $nsgName  = $resolved.NsgName
    $publicIp = $resolved.ConnectIp
    Write-Ok "Resolved: NSG=$nsgName  IP=$publicIp"
} else {
    Write-Step "Deploying infrastructure (Bicep)"
    $bicepPath = Join-Path $InfraPath "main.bicep"
    if (-not (Test-Path $bicepPath)) {
        Write-Error "Bicep file not found at $bicepPath"
    }

    $bicepParams = @{
        ResourceGroupName = $ResourceGroup
        Name              = "deploy-$VMName-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        TemplateFile      = $bicepPath
        vmName            = $VMName
        adminUsername     = $VMUser
        adminPassword     = $securePassword
        vmSize            = $VMSize
        location          = $Location
    }
    if ($HubVnetId) {
        $bicepParams['peerVnetId'] = $HubVnetId
    }
    if ($DisablePublicIp) {
        $bicepParams['enablePublicIp'] = $false
    }
    $deployment = New-AzResourceGroupDeployment @bicepParams

    $nsgName = $deployment.Outputs.nsgName.Value
    if ($DisablePublicIp) {
        $publicIp = $deployment.Outputs.privateIpAddress.Value
        Write-Ok "VM deployed (no public IP — using private IP via VPN)"
        Write-Ok "Private IP: $publicIp"
    } else {
        $publicIp = $deployment.Outputs.publicIpAddress.Value
        Write-Ok "VM deployed"
        Write-Ok "Public IP: $publicIp"
    }

    # ── Hub → Spoke peering (allowGatewayTransit) ────────────────────────
    if ($HubVnetId) {
        $spokeVnetId = $deployment.Outputs.vnetId.Value
        $hubRg = ($HubVnetId -split '/')[4]
        $hubVnetName = ($HubVnetId -split '/')[-1]
        $spokeName = ($spokeVnetId -split '/')[-1]
        $peeringName = "peer-to-$spokeName"

        Invoke-InSubscription -ResourceId $HubVnetId -ScriptBlock {
            $existingPeering = Get-AzVirtualNetworkPeering -ResourceGroupName $hubRg -VirtualNetworkName $hubVnetName -Name $peeringName -ErrorAction SilentlyContinue
            if (-not $existingPeering) {
                Write-Step "Creating hub → spoke peering ($hubVnetName → $spokeName)"
                Add-AzVirtualNetworkPeering -ResourceGroupName $hubRg -VirtualNetworkName $hubVnetName `
                    -Name $peeringName -RemoteVirtualNetworkId $spokeVnetId `
                    -AllowGatewayTransit -AllowForwardedTraffic | Out-Null
                Write-Ok "Peering '$peeringName' created with AllowGatewayTransit"
            } else {
                Write-Ok "Hub → spoke peering '$peeringName' already exists"
            }
        }
    }
}

# ── Validate DNS (after IaC) ────────────────────────────────────────────────
if ($VsCodeWebHost) {
    if (-not $publicIp) {
        throw "Unsupported configuration: -VsCodeWebHost requires a public IP, but no public IP was found."
    }

    if ($publicIp -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|127\.)') {
        throw "Unsupported configuration: -VsCodeWebHost requires a public IP, but the VM currently resolves to private IP '$publicIp'."
    }

    Write-Step "Validating DNS for VS Code Web host '$VsCodeWebHost'"
    $maxDnsChecks = 12
    $dnsDelaySeconds = 10
    $expectedIp = $publicIp
    $lastResolvedIp = $null
    $dnsOk = $false

    for ($i = 1; $i -le $maxDnsChecks; $i++) {
        try {
            $aRecord = Resolve-DnsName -Name $VsCodeWebHost -Type A -ErrorAction Stop |
                Select-Object -First 1 -ExpandProperty IPAddress
            $lastResolvedIp = $aRecord
            if ($aRecord -eq $expectedIp) {
                $dnsOk = $true
                break
            }
            Write-Host "  │  Attempt $i/$maxDnsChecks — currently resolves to '$aRecord' (expected '$expectedIp')" -ForegroundColor DarkGray
        } catch {
            Write-Host "  │  Attempt $i/$maxDnsChecks — no A record found yet" -ForegroundColor DarkGray
        }

        if ($i -lt $maxDnsChecks) {
            Start-Sleep -Seconds $dnsDelaySeconds
        }
    }

    if (-not $dnsOk) {
        if ($lastResolvedIp) {
            throw "DNS validation failed for '$VsCodeWebHost'. Please update the A record to '$expectedIp' (current: '$lastResolvedIp') and then rerun this script."
        }
        throw "DNS validation failed for '$VsCodeWebHost'. Please create an A record with IP '$expectedIp' and then rerun this script."
    }

    Write-Ok "DNS validated: $VsCodeWebHost → $expectedIp"
}

# ── Temporary WinRM NSG rule (idempotent) ────────────────────────────────────
$winrmRuleName = 'Allow-WinRM-HTTPS-Temp'
$acmeHttpRuleName = 'Allow-ACME-HTTP'

if (-not $DisablePublicIp) {
    Write-Step "Adding temporary WinRM HTTPS rule (removed after setup)"
    $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName
    $existingRule = $nsg.SecurityRules | Where-Object { $_.Name -eq $winrmRuleName }
    if ($existingRule) {
        Write-Ok "WinRM rule already exists — skipping"
    } else {
        $nsg | Add-AzNetworkSecurityRuleConfig `
            -Name $winrmRuleName `
            -Priority 1010 `
            -Direction Inbound `
            -Access Allow `
            -Protocol Tcp `
            -SourcePortRange '*' `
            -DestinationPortRange '5986' `
            -SourceAddressPrefix '*' `
            -DestinationAddressPrefix '*' `
        | Set-AzNetworkSecurityGroup | Out-Null
        Write-Ok "WinRM rule added (will be removed after setup)"
    }

    if ($VsCodeWebHost) {
        Write-Step "Adding ACME HTTP rule for certificate validation and renewal"
        $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName
        $existingAcmeRule = $nsg.SecurityRules | Where-Object { $_.Name -eq $acmeHttpRuleName }
        if ($existingAcmeRule) {
            Write-Ok "ACME HTTP rule already exists — skipping"
        } else {
            $nsg | Add-AzNetworkSecurityRuleConfig `
                -Name $acmeHttpRuleName `
                -Priority 1200 `
                -Direction Inbound `
                -Access Allow `
                -Protocol Tcp `
                -SourcePortRange '*' `
                -DestinationPortRange '80' `
                -SourceAddressPrefix '*' `
                -DestinationAddressPrefix '*' `
            | Set-AzNetworkSecurityGroup | Out-Null
            Write-Ok "ACME HTTP rule added"
        }
    }
} else {
    Write-Step "Skipping temporary WinRM NSG rule (private connectivity via VPN)"
    Write-Ok "Not needed — VM accessed via private IP"
}

# ── Establish PS Remoting session ────────────────────────────────────────────
Write-Step "Connecting to VM via PowerShell Remoting (WinRM HTTPS)"
$credential = [PSCredential]::new($VMUser, $securePassword)
$connectSessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 10000 -OperationTimeout 600000

$maxRetries = 30
$retryDelay = 15
$spinner = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$spinIdx = 0
$session = $null
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $session = New-PSSession -ComputerName $publicIp -Credential $credential `
            -UseSSL -SessionOption $connectSessionOpts -ErrorAction Stop
        break
    } catch {
        if ($i -eq $maxRetries) {
            if ($script:CanAnimateSpinner) { Write-Host "`r$(' ' * 70)`r" -NoNewline }
            Write-Error "Failed to connect after $maxRetries attempts: $_"
        }
        if ($script:CanAnimateSpinner) {
            $tickCount = [math]::Floor($retryDelay * 1000 / 150)
            for ($tick = 0; $tick -lt $tickCount; $tick++) {
                $s = $spinner[$spinIdx % $spinner.Count]; $spinIdx++
                $elapsed = ($i - 1) * $retryDelay + [math]::Floor($tick * 150 / 1000)
                Write-Host "`r  $s Attempt $i/$maxRetries — waiting for VM… (${elapsed}s)   " -NoNewline -ForegroundColor DarkGray
                Start-Sleep -Milliseconds 150
            }
        } else {
            Write-Host "  │  Attempt $i/$maxRetries — VM not ready yet, retrying in ${retryDelay}s…" -ForegroundColor DarkGray
            Start-Sleep -Seconds $retryDelay
        }
    }
}
if ($script:CanAnimateSpinner) { Write-Host "`r$(' ' * 70)`r" -NoNewline }
Write-Ok "Remote session established"

try {
    # ── 1. Install Chocolatey ────────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Chocolatey" -Script {
        $ProgressPreference = 'SilentlyContinue'
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        Write-Output "Chocolatey $(choco --version) installed"
    }

    # ── 2. Enable Windows features (WSL2, Hyper-V, Containers) ───────────
    $needsReboot = Invoke-Command -Session $session -ScriptBlock {
        $reboot = $false
        $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All
        if ($r.RestartNeeded) { $reboot = $true }
        Write-Output "WSL enabled"
        $r = Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All
        if ($r.RestartNeeded) { $reboot = $true }
        Write-Output "VirtualMachinePlatform enabled"
        try {
            $r = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart -All
            if ($r.RestartNeeded) { $reboot = $true }
            Write-Output "Hyper-V enabled"
        } catch {
            Write-Output "Hyper-V not available on this SKU — WSL2 backend will be used"
        }
        $r = Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -All
        if ($r.RestartNeeded) { $reboot = $true }
        Write-Output "Containers feature enabled"
        return $reboot
    } 2>&1
    # Last value returned is the boolean; preceding lines are output strings
    $featuresRebootNeeded = $needsReboot | Select-Object -Last 1
    $featOutput = $needsReboot | Select-Object -SkipLast 1
    Write-Host "  ┌─ Enabling Windows features (WSL2, Hyper-V, Containers)…" -ForegroundColor DarkCyan
    foreach ($line in $featOutput) {
        $text = "$line".Trim()
        if ($text) { Write-Host "  │  $text" -ForegroundColor DarkGray }
    }
    Write-Host "  └─ Enabling Windows features ✓" -ForegroundColor Green

    # If features were newly enabled, reboot to activate them before WSL setup
    if ($featuresRebootNeeded -eq $true) {
        Write-Step "Rebooting VM to activate Windows features"
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        Restart-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
        Write-Ok "VM restarted — waiting for WinRM to come back"

        # Re-establish session after reboot
        Start-Sleep -Seconds 15
        $session = $null
        for ($i = 1; $i -le $maxRetries; $i++) {
            try {
                $session = New-PSSession -ComputerName $publicIp -Credential $credential `
                    -UseSSL -SessionOption $connectSessionOpts -ErrorAction Stop
                break
            } catch {
                if ($i -eq $maxRetries) {
                    Write-Error "Failed to reconnect after reboot ($maxRetries attempts): $_"
                }
                if ($script:CanAnimateSpinner) {
                    $tickCount = [math]::Floor($retryDelay * 1000 / 150)
                    for ($tick = 0; $tick -lt $tickCount; $tick++) {
                        $s = $spinner[$spinIdx % $spinner.Count]; $spinIdx++
                        $elapsed = ($i - 1) * $retryDelay + [math]::Floor($tick * 150 / 1000)
                        Write-Host "`r  $s Reconnecting… attempt $i/$maxRetries (${elapsed}s)   " -NoNewline -ForegroundColor DarkGray
                        Start-Sleep -Milliseconds 150
                    }
                } else {
                    Write-Host "  │  Reconnect attempt $i/$maxRetries — retrying in ${retryDelay}s…" -ForegroundColor DarkGray
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
        if ($script:CanAnimateSpinner) { Write-Host "`r$(' ' * 70)`r" -NoNewline }
        Write-Ok "Reconnected after reboot"
    }

    # ── 2b. Complete WSL setup (requires features active after reboot) ────
    Invoke-RemoteStep -Session $session -StepName "Installing WSL" -Script {
        # Check if WSL is already properly installed. Try the MSI-installed path first,
        # then fall back to the system wsl.exe (which may work outside session 0).
        $wslExe = "$env:ProgramFiles\WSL\wsl.exe"
        if (-not (Test-Path $wslExe)) { $wslExe = "$env:SystemRoot\System32\wsl.exe" }
        if (Test-Path $wslExe) {
            # wsl.exe outputs UTF-16LE which gets embedded NUL chars in WinRM sessions
            $wslVer = (& $wslExe --version 2>&1 | Select-Object -First 1) -replace '\x00',''
            if ($LASTEXITCODE -eq 0 -and $wslVer -match 'WSL') {
                Write-Output "WSL already installed: $wslVer"
                return
            }
        }

        # DO NOT replace this with "wsl --install". The in-box wsl.exe is just a stub
        # that launches the Microsoft Store / AppInstaller — which silently fails in
        # WinRM session 0 (non-interactive). The --web-download flag doesn't help either.
        # The only reliable method is the official MSI from the GitHub releases page.
        $wslMsi = "$env:TEMP\wsl.msi"
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/WSL/releases/latest" -UseBasicParsing
        $asset = $release.assets | Where-Object { $_.name -match '\.x64\.msi$' } | Select-Object -First 1
        if (-not $asset) { throw "Could not find x64 MSI in latest WSL release ($($release.tag_name))" }
        $wslUrl = $asset.browser_download_url
        Write-Output "Downloading WSL $($release.tag_name) MSI…"
        Invoke-WebRequest -Uri $wslUrl -OutFile $wslMsi -UseBasicParsing
        $proc = Start-Process msiexec.exe -ArgumentList "/i `"$wslMsi`" /quiet /norestart" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) { throw "WSL MSI install failed with exit code $($proc.ExitCode)" }
        Remove-Item $wslMsi -Force -ErrorAction SilentlyContinue
        wsl --update 2>&1 | Out-Null
        wsl --set-default-version 2 2>&1 | Out-Null
        $ver = (wsl --version 2>&1 | Select-Object -First 1) -replace '\x00',''
        Write-Output "WSL installed: $ver"
    }

    # ── 3. Install Python ────────────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Python 3.12" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install python312 --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $pyVer = & python --version 2>&1
        Write-Output "$pyVer installed"
    }

    # ── 3b. Install Node.js LTS ───────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Node.js LTS" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install nodejs-lts --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $nodeVer = & node --version 2>&1
        Write-Output "Node.js $nodeVer installed"
    }

    # ── 4. Install PowerShell 7 ──────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing PowerShell 7" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install pwsh --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            $ver = & $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            Write-Output "PowerShell $ver installed"
        }
    }

    # ── 5. Install Docker Desktop ────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Docker Desktop" -Script {
        param($Password)
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install docker-desktop --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        # Set Docker service to auto-start
        $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name "com.docker.service" -StartupType Automatic
            Write-Output "Docker service set to Automatic start"
        }

        # Register scheduled task to launch Docker Desktop at startup (headless, for Linux containers)
        $ddPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $ddPath) {
            $action   = New-ScheduledTaskAction -Execute $ddPath -Argument "--minimize"
            $trigger  = New-ScheduledTaskTrigger -AtStartup
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
            Register-ScheduledTask -TaskName "DockerDesktop-AutoStart" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -User "$env:USERNAME" -Password $Password -Force | Out-Null
            Write-Output "Docker Desktop scheduled to start at boot"
        }

        Write-Output "Docker Desktop installed"
    } -ArgumentList $VMPassword

    # ── 6. Install Visual Studio Code ────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Visual Studio Code" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install vscode --yes --no-progress --params "/NoDesktopIcon /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath" 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $codePath = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $codePath) { Write-Output "VS Code installed" }
    }

    # ── 6a. Install Git ─────────────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Git" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $gitCheck = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCheck) {
            Write-Output "Git already installed: $(git --version)"
        } else {
            choco install git --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Output "$(git --version) installed"
        }
    }

    # ── 7. Install GitHub CLI + Copilot CLI ─────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing GitHub CLI + Copilot CLI" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install gh --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $ghVer = & gh --version 2>&1 | Select-Object -First 1
        Write-Output "$ghVer installed"
        # Install GitHub Copilot CLI via Chocolatey (standalone copilot.exe)
        choco install github-copilot-cli --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $copilotVer = & copilot.exe --version 2>&1 | Select-Object -First 1
        Write-Output "Copilot CLI: $copilotVer"
    }

    # ── 7b. Install psmux (terminal multiplexer for PowerShell) ────────
    Invoke-RemoteStep -Session $session -StepName "Installing psmux" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        choco install psmux --yes --no-progress 2>&1 | Select-String -Pattern '(install|downloaded|The install)' | ForEach-Object { Write-Output $_.Line.Trim() }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $psmuxCheck = Get-Command psmux -ErrorAction SilentlyContinue
        if ($psmuxCheck) { Write-Output "psmux installed" } else { Write-Output "psmux installed (may require new shell)" }
    }

    # ── 8. Install Az PowerShell module ──────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Az PowerShell module (in pwsh 7)" -Script {
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            & $pwshExe -NoProfile -Command {
                $existing = Get-InstalledModule Az -ErrorAction SilentlyContinue
                if ($existing) {
                    Write-Output "Az module $($existing.Version) already installed — skipping"
                    return
                }
                $ProgressPreference = 'SilentlyContinue'
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
                Write-Output "Az module $((Get-InstalledModule Az).Version) installed"
            }
        } else {
            $existing = Get-InstalledModule Az -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Output "Az module $($existing.Version) already installed — skipping"
            } else {
                Write-Output "pwsh 7 not found — installing Az in Windows PowerShell"
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
                Write-Output "Az module installed"
            }
        }
    }

    # ── 9. Install Microsoft.Graph module ────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Microsoft.Graph module (in pwsh 7)" -Script {
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            & $pwshExe -NoProfile -Command {
                $existing = Get-InstalledModule Microsoft.Graph -ErrorAction SilentlyContinue
                if ($existing) {
                    Write-Output "Microsoft.Graph module $($existing.Version) already installed — skipping"
                    return
                }
                $ProgressPreference = 'SilentlyContinue'
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers
                Write-Output "Microsoft.Graph module $((Get-InstalledModule Microsoft.Graph).Version) installed"
            }
        } else {
            $existing = Get-InstalledModule Microsoft.Graph -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Output "Microsoft.Graph module $($existing.Version) already installed — skipping"
            } else {
                Write-Output "pwsh 7 not found — installing Microsoft.Graph in Windows PowerShell"
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers
                Write-Output "Microsoft.Graph module installed"
            }
        }
    }

    # ── 10. Configure VS Code extensions for first login ─────────────────
    Invoke-RemoteStep -Session $session -StepName "Configuring VS Code extensions (scheduled for first login)" -Script {
        param($User)
        $setupDir = "C:\setup"
        if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

        $extensionsScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$codePath = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
if (-not (Test-Path $codePath)) {
    $codePath = (Get-Command code -ErrorAction SilentlyContinue).Source
}
if (-not $codePath) { exit 0 }

$extensions = @(
    "GitHub.copilot"
    "GitHub.copilot-chat"
    "ms-python.python"
    "ms-python.debugpy"
    "ms-azuretools.vscode-azureresourcegroups"
    "ms-azuretools.vscode-azurefunctions"
    "ms-vscode.powershell"
    "yzhang.markdown-all-in-one"
    "bierner.markdown-mermaid"
    "ms-vscode-remote.remote-wsl"
    "ms-azuretools.vscode-docker"
    "ms-vscode.vscode-node-azure-pack"
    "ms-vscode-remote.remote-containers"
)
foreach ($ext in $extensions) {
    & $codePath --install-extension $ext --force 2>&1 | Out-Null
}

Unregister-ScheduledTask -TaskName "InstallVSCodeExtensions" -Confirm:$false -ErrorAction SilentlyContinue
'@
        $extensionsScript | Out-File -FilePath "$setupDir\install-extensions.ps1" -Encoding UTF8 -Force

        $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\setup\install-extensions.ps1"
        $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $User
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName "InstallVSCodeExtensions" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null

        $extList = @("GitHub.copilot","GitHub.copilot-chat","ms-python.python","ms-vscode.azure-account","ms-vscode.powershell","yzhang.markdown-all-in-one","bierner.markdown-mermaid","ms-azuretools.vscode-docker","ms-vscode.vscode-node-azure-pack","ms-vscode-remote.remote-containers")
        Write-Output "$($extList.Count)+ extensions scheduled for first login of '$User'"
    } -ArgumentList $VMUser

    # ── 11. Add user to docker-users group ───────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Adding $VMUser to docker-users group" -Script {
        param($User)
        try {
            net localgroup "docker-users" $User /add 2>&1 | Out-Null
            Write-Output "User '$User' added to docker-users"
        } catch {
            Write-Output "docker-users group may not exist yet — Docker will create it on first start"
        }
    } -ArgumentList $VMUser

    # ── 11b. Copy VS Code Web proxy to VM ──────────────────────────────
    if ($InstallVsCodeWeb) {
        $vsCodeWebPw = if ($VsCodeWebPassword) { $VsCodeWebPassword } else { $VMPassword }
        Invoke-RemoteStep -Session $session -StepName "Copying VS Code Web proxy to VM" -Script {
            $VibeDir = "C:\vscodeweb"
            if (-not (Test-Path $VibeDir)) { New-Item -ItemType Directory -Path $VibeDir -Force | Out-Null }
            Write-Output "Target directory ready: $VibeDir"
        }
        # Copy server.js via session
        $vsCodeWebSrc = Join-Path $PSScriptRoot "vscodeweb"
        $localPath = Join-Path $vsCodeWebSrc "server.js"
        if (Test-Path $localPath) {
            $content = Get-Content $localPath -Raw
            Invoke-Command -Session $session -ScriptBlock {
                param($fileContent)
                $fileContent | Out-File -FilePath "C:\vscodeweb\server.js" -Encoding UTF8 -Force
            } -ArgumentList $content
        }
        Write-Ok "VS Code Web proxy copied"

        # ── 12. Install VS Code Web interface ─────────────────────────────────
        Invoke-RemoteStep -Session $session -StepName "Installing VS Code Web interface" -Script {
            param($Password, $Port, $CodeServerPort, $Domain)
            $ProgressPreference = 'SilentlyContinue'
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            $VibeDir = "C:\vscodeweb"

            # Install Node.js
            $nodePath = Get-Command node -ErrorAction SilentlyContinue
            if (-not $nodePath) {
                choco install nodejs-lts --yes --no-progress 2>&1 | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            }
            Write-Output "Node.js: $(node --version)"

            # Install ws dependency (required by server.js for WebSocket proxying)
            Push-Location $VibeDir
            if (-not (Test-Path "$VibeDir\node_modules\ws")) {
                & npm init -y 2>&1 | Out-Null
                & npm install ws 2>&1 | Out-Null
            }
            Pop-Location
            Write-Output "ws dependency ready"

            # VS Code serve-web is used as the backend (built into VS Code, no extra install needed)
            $codeBin = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
            if (-not (Test-Path $codeBin)) { throw "VS Code not found at $codeBin" }
            Write-Output "VS Code serve-web backend: $codeBin"

            # Ensure directories
            if (-not (Test-Path "$VibeDir\logs")) { New-Item -ItemType Directory -Path "$VibeDir\logs" -Force | Out-Null }

            # Install OpenSSL for self-signed cert
            $opensslPath = Get-Command openssl -ErrorAction SilentlyContinue
            if (-not $opensslPath) {
                choco install openssl --yes --no-progress 2>&1 | Out-Null
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            }
            Write-Output "OpenSSL available"

            # Setup certificates and renewal lifecycle
            $CertsDir = "$VibeDir\certs"
            $certPath = "$CertsDir\cert.pem"
            $keyPath = "$CertsDir\key.pem"
            $metadataPath = "$CertsDir\cert-metadata.txt"
            $certbotExe = (Get-Command certbot -ErrorAction SilentlyContinue).Source
            if (-not $certbotExe) {
                $pyDir = Split-Path (Get-Command python -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
                if ($pyDir) { $certbotExe = Join-Path $pyDir 'Scripts\certbot.exe' }
            }
            $activeCertPath = $certPath
            $activeKeyPath = $keyPath

            if (-not (Test-Path $CertsDir)) {
                New-Item -ItemType Directory -Path $CertsDir -Force | Out-Null
            }

            function Get-CertificateCN {
                param([string]$Path)
                if (-not (Test-Path $Path)) { return $null }
                try {
                    $subject = openssl x509 -in $Path -noout -subject 2>$null
                    if ($subject -match 'CN=([^,/]+)') {
                        return $matches[1]
                    }
                } catch {
                    return $null
                }
                return $null
            }

            $previous = @{}
            if (Test-Path $metadataPath) {
                Get-Content $metadataPath | ForEach-Object {
                    if ($_ -match '=') {
                        $k, $v = $_ -split '=', 2
                        $previous[$k.Trim()] = $v.Trim()
                    }
                }
            }
            $previousMode = $previous['mode']
            $previousDomain = $previous['domain']

            if ($Domain) {
                Write-Output "Setting up certificate for domain: $Domain"
                $currentCn = Get-CertificateCN -Path $certPath
                if (-not (Test-Path $certPath) -or $currentCn -ne $Domain) {
                    if ($currentCn) {
                        Write-Output "Certificate CN changed ($currentCn -> $Domain), regenerating"
                    }
                    openssl req -x509 -newkey rsa:2048 -keyout $keyPath -out $certPath -days 365 -nodes -subj "/CN=$Domain" 2>&1 | Out-Null
                } else {
                    Write-Output "Certificate already matches domain: $Domain"
                }

                if (-not (Test-Path $certbotExe)) {
                    Write-Output "Installing certbot via pip..."
                    python -m pip install certbot 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Output $_ }
                    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
                    $certbotExe = (Get-Command certbot -ErrorAction SilentlyContinue).Source
                    if (-not $certbotExe) {
                        $pyDir = Split-Path (Get-Command python -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
                        if ($pyDir) { $certbotExe = Join-Path $pyDir 'Scripts\certbot.exe' }
                    }
                }

                if (-not (Test-Path $certbotExe)) {
                    throw "Certbot is not available at '$certbotExe'. Install Python first, then rerun the script."
                }

                $acmeFirewallRule = "ACME-HTTP-80"
                $existingAcmeFwRule = Get-NetFirewallRule -DisplayName $acmeFirewallRule -ErrorAction SilentlyContinue
                if (-not $existingAcmeFwRule) {
                    New-NetFirewallRule -DisplayName $acmeFirewallRule -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
                }

                $leConfigDir = "C:\Certbot"
                $leWorkDir = "$leConfigDir\work"
                $leLogsDir = "$leConfigDir\logs"
                $leLiveDir = "$leConfigDir\live\$Domain"
                $leFullChain = "$leLiveDir\fullchain.pem"
                $lePrivKey = "$leLiveDir\privkey.pem"

                if (-not ((Test-Path $leFullChain) -and (Test-Path $lePrivKey))) {
                    Write-Output "Requesting ACME certificate via certbot for $Domain"
                    & $certbotExe certonly --standalone --preferred-challenges http --non-interactive --agree-tos --register-unsafely-without-email --keep-until-expiring -d $Domain --config-dir $leConfigDir --work-dir $leWorkDir --logs-dir $leLogsDir 2>&1 | ForEach-Object { Write-Output $_ }
                    if ($LASTEXITCODE -ne 0) {
                        throw "ACME certificate issuance failed for '$Domain'. Ensure TCP/80 is reachable from internet, DNS A record points to '$Domain', then rerun the script."
                    }
                } else {
                    Write-Output "Existing ACME certificate found for $Domain"
                }

                if (-not ((Test-Path $leFullChain) -and (Test-Path $lePrivKey))) {
                    throw "ACME issuance did not produce expected certificate files under '$leLiveDir'."
                }

                $activeCertPath = $leFullChain
                $activeKeyPath = $lePrivKey

                $renewScript = @"
`$certbotExe = "$certbotExe"
`$logFile = "$VibeDir\logs\cert-renewal.log"
`$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
if (Test-Path `$certbotExe) {
    Add-Content `$logFile "`$ts - Starting certificate renewal"
    & `$certbotExe renew --quiet --agree-tos --config-dir "C:\Certbot" --work-dir "C:\Certbot\work" --logs-dir "C:\Certbot\logs" 2>&1 | Add-Content `$logFile
    Add-Content `$logFile "`$ts - Renewal exit code: `$LASTEXITCODE"
} else {
    Add-Content `$logFile "`$ts - Certbot not installed"
}
"@
                $renewScript | Out-File "$VibeDir\renew-cert.ps1" -Encoding UTF8 -Force

                $existingRenewTask = Get-ScheduledTask -TaskName "CertbotRenewal" -ErrorAction SilentlyContinue
                if ($existingRenewTask -and $previousMode -eq 'acme' -and $previousDomain -eq $Domain) {
                    Write-Output "Certbot renewal task already configured for $Domain"
                } else {
                    if ($existingRenewTask) {
                        Unregister-ScheduledTask -TaskName "CertbotRenewal" -Confirm:$false -ErrorAction SilentlyContinue
                    }
                    $renewAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$VibeDir\renew-cert.ps1`""
                    $renewTrigger = New-ScheduledTaskTrigger -Daily -At ([DateTime]"02:00:00")
                    $renewSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -StartWhenAvailable
                    Register-ScheduledTask -TaskName "CertbotRenewal" -Action $renewAction -Trigger $renewTrigger -Settings $renewSettings -RunLevel Highest -Force | Out-Null
                }

                @"
domain=$Domain
mode=acme
lastUpdate=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@ | Out-File $metadataPath -Encoding UTF8 -Force
            } else {
                $currentCn = Get-CertificateCN -Path $certPath
                if (-not (Test-Path $certPath) -or $currentCn -ne 'localhost') {
                    openssl req -x509 -newkey rsa:2048 -keyout $keyPath -out $certPath -days 365 -nodes -subj '/CN=localhost' 2>&1 | Out-Null
                }
                if ($previousMode -eq 'acme') {
                    Unregister-ScheduledTask -TaskName "CertbotRenewal" -Confirm:$false -ErrorAction SilentlyContinue
                }
                @"
domain=localhost
mode=self-signed
lastUpdate=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@ | Out-File $metadataPath -Encoding UTF8 -Force
            }
            Write-Output "Certificates ready at $CertsDir"

            # Firewall rule
            $ruleName = "VSCodeWeb-HTTPS-$Port"
            $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            if (-not $existing) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
            }
            Write-Output "Firewall: port $Port open"

            # Symlink server extensions to desktop extensions (so serve-web sees all installed extensions)
            $serverExtDir = "$env:USERPROFILE\.vscode-server\extensions"
            $desktopExtDir = "$env:USERPROFILE\.vscode\extensions"
            if (-not (Test-Path $desktopExtDir)) { New-Item -ItemType Directory -Path $desktopExtDir -Force | Out-Null }
            if ((Get-Item $serverExtDir -ErrorAction SilentlyContinue).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Output "Extensions symlink already exists"
            } else {
                if (Test-Path $serverExtDir) { Remove-Item $serverExtDir -Recurse -Force }
                $parent = Split-Path $serverExtDir -Parent
                if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
                cmd /c mklink /D "$serverExtDir" "$desktopExtDir" | Out-Null
                Write-Output "Symlinked serve-web extensions -> desktop extensions"
            }

            # Create startup scripts (PS1 wrappers to avoid cmd.exe issues with special chars)
            # Run the Node.js VS Code server directly (bypassing code-tunnel.exe whose
            # Rust WebSocket proxy has a bug that immediately closes connections).
            @'
$logFile = "C:\vscodeweb\logs\codeserver.log"
$serveWebBase = "$env:USERPROFILE\.vscode\cli\serve-web"
$commitDir = Get-ChildItem $serveWebBase -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $commitDir) { throw "No serve-web directory found" }
$serverMainPath = Join-Path $commitDir.FullName "out\server-main.js"
$c = Get-Content $serverMainPath -Raw
if ($c.Contains('reconnection-grace-time"],108e5)')) {
    $c = $c.Replace('reconnection-grace-time"],108e5)', 'reconnection-grace-time"],2592e6)')
    [System.IO.File]::WriteAllText($serverMainPath, $c)
}

# Patch workbench to enable persistent secret storage (GitHub Copilot auth)
$wbPath = Join-Path $commitDir.FullName "out\vs\workbench\workbench.web.main.internal.js"
if (Test-Path $wbPath) {
    $wb = [System.IO.File]::ReadAllText($wbPath)
    $changed = $false
    # Patch 1: Disable forced in-memory storage for SecretStorageService
    if ($wb.Contains('extends Zke{constructor(i,e,t,o){super(!0,i,e,o)')) {
        $wb = $wb.Replace(
            'extends Zke{constructor(i,e,t,o){super(!0,i,e,o)',
            'extends Zke{constructor(i,e,t,o){super(!1,i,e,o)'
        )
        $changed = $true
    }
    # Patch 2: Make encryption service report as available (uses identity encrypt/decrypt)
    if ($wb.Contains('isEncryptionAvailable(){return Promise.resolve(!1)}')) {
        $wb = $wb.Replace(
            'isEncryptionAvailable(){return Promise.resolve(!1)}',
            'isEncryptionAvailable(){return Promise.resolve(!0)}'
        )
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllText($wbPath, $wb, [System.Text.Encoding]::UTF8)
    }
}

$nodePath = Join-Path $commitDir.FullName "node.exe"
& $nodePath $serverMainPath --host 127.0.0.1 --port 8080 --without-connection-token --accept-server-license-terms *> $logFile
'@ | Out-File "$VibeDir\start-codeserver.ps1" -Encoding UTF8 -Force

            @"
`$env:CODESERVER_PORT = "$CodeServerPort"
`$env:VIBE_PORT = "$Port"
`$env:VIBE_PASSWORD = "$Password"
`$env:VIBE_HOST = "$(if ($Domain) { $Domain } else { 'localhost' })"
`$env:VIBE_CERT = "$activeCertPath"
`$env:VIBE_KEY = "$activeKeyPath"
Set-Location "$VibeDir"
& node server.js *> "$VibeDir\logs\vscodeweb.log"
"@ | Out-File "$VibeDir\start-vscodeweb.ps1" -Encoding UTF8 -Force

            # Scheduled tasks for auto-start (Password logon = runs without interactive login)
            $csAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$VibeDir\start-codeserver.ps1`""
            $csTrigger = New-ScheduledTaskTrigger -AtStartup
            $csSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName "VSCodeWeb-Backend" -Action $csAction -Trigger $csTrigger -Settings $csSettings -RunLevel Highest -User "$env:USERNAME" -Password $Password -Force | Out-Null

            $vibeAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$VibeDir\start-vscodeweb.ps1`""
            $vibeTrigger = New-ScheduledTaskTrigger -AtStartup
            $vibeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName "VSCodeWeb-Proxy" -Action $vibeAction -Trigger $vibeTrigger -Settings $vibeSettings -RunLevel Highest -User "$env:USERNAME" -Password $Password -Force | Out-Null

            Write-Output "VS Code Web services registered (auto-start on boot)"
        } -ArgumentList $vsCodeWebPw, 9443, 8080, $VsCodeWebHost
    }

    # ── 13. Verify all software installed ────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Verifying installed software" -Script {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $checks = @()
        # Python
        $py = & python --version 2>&1
        if ($LASTEXITCODE -eq 0) { $checks += "OK  Python: $py" } else { $checks += "FAIL Python not found" }
        # PowerShell 7
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            $ver = & $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
            $checks += "OK  PowerShell 7: $ver"
        } else { $checks += "FAIL PowerShell 7 not found" }
        # Docker Desktop
        $docker = Get-ItemProperty "HKLM:\SOFTWARE\Docker Inc.\Docker\*" -ErrorAction SilentlyContinue
        if ($docker -or (Test-Path "C:\Program Files\Docker\Docker\Docker Desktop.exe")) {
            $checks += "OK  Docker Desktop installed"
        } else { $checks += "FAIL Docker Desktop not found" }
        # VS Code
        $codePath = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $codePath) { $checks += "OK  VS Code installed" } else { $checks += "FAIL VS Code not found" }
        # GitHub CLI + Copilot
        $ghVer = & gh --version 2>&1 | Select-Object -First 1
        if ($LASTEXITCODE -eq 0) { $checks += "OK  GitHub CLI: $ghVer" } else { $checks += "FAIL GitHub CLI not found" }
        # GitHub Copilot CLI (standalone)
        $copilotVer = & copilot.exe --version 2>&1 | Select-Object -First 1
        if ($LASTEXITCODE -eq 0) { $checks += "OK  Copilot CLI: $copilotVer" } else { $checks += "FAIL Copilot CLI (copilot.exe) not found" }
        # Az module
        if (Test-Path $pwshExe) {
            $azVer = & $pwshExe -NoProfile -Command '(Get-InstalledModule Az -ErrorAction SilentlyContinue).Version'
            if ($azVer) { $checks += "OK  Az module: $azVer" } else { $checks += "FAIL Az module not found" }
        }
        # Microsoft.Graph module
        if (Test-Path $pwshExe) {
            $graphVer = & $pwshExe -NoProfile -Command '(Get-InstalledModule Microsoft.Graph -ErrorAction SilentlyContinue).Version'
            if ($graphVer) { $checks += "OK  Microsoft.Graph module: $graphVer" } else { $checks += "FAIL Microsoft.Graph module not found" }
        }
        # psmux
        $psmuxPath = Get-Command psmux -ErrorAction SilentlyContinue
        if ($psmuxPath) { $checks += "OK  psmux installed" } else { $checks += "FAIL psmux not found" }
        # Chocolatey
        $chocoVer = & choco --version 2>&1
        if ($LASTEXITCODE -eq 0) { $checks += "OK  Chocolatey: $chocoVer" } else { $checks += "FAIL Chocolatey not found" }
        # WSL
        $wslExe = "$env:SystemRoot\System32\wsl.exe"
        if (Test-Path $wslExe) {
            $wslVersion = (& $wslExe --version 2>&1 | Select-Object -First 1) -replace '\x00',''
            if ($LASTEXITCODE -eq 0 -and $wslVersion) { $checks += "OK  WSL: $wslVersion" } else { $checks += "OK  WSL installed (version check requires reboot)" }
        } else { $checks += "FAIL WSL not installed" }
        # Scheduled task for extensions
        $task = Get-ScheduledTask -TaskName "InstallVSCodeExtensions" -ErrorAction SilentlyContinue
        if ($task) { $checks += "OK  VS Code extensions scheduled task registered" } else { $checks += "FAIL Extensions task not found" }

        foreach ($c in $checks) { Write-Output $c }
        $failures = $checks | Where-Object { $_ -match '^FAIL' }
        if ($failures) { Write-Error "$($failures.Count) check(s) FAILED" } else { Write-Output "`nAll checks passed" }
    }

} finally {
    # ── Clean up session ─────────────────────────────────────────────────
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

# ── Remove temporary WinRM NSG rule ──────────────────────────────────────────
if (-not $DisablePublicIp) {
    Write-Step "Removing temporary WinRM HTTPS rule"
    try {
        Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName `
            | Remove-AzNetworkSecurityRuleConfig -Name $winrmRuleName `
            | Set-AzNetworkSecurityGroup | Out-Null
        Write-Ok "WinRM rule removed"
    } catch {
        Write-Warn "Could not remove WinRM rule '$winrmRuleName' — clean up manually"
    }
}

# ── Restart VM ───────────────────────────────────────────────────────────────
Write-Step "Restarting VM to finalize Docker setup"
Restart-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
Write-Ok "VM restarted"

# ── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Windows 11 Dev VM deployed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  RDP Address       : $publicIp" -ForegroundColor White
if($InstallVsCodeWeb) {
    $vsCodeWebEndpoint = if ($VsCodeWebHost) { "https://${VsCodeWebHost}:9443" } else { "https://${publicIp}:9443" }
    Write-Host "  VS Code Web       : $vsCodeWebEndpoint" -ForegroundColor White
}
Write-Host "  Username          : $VMUser" -ForegroundColor White
Write-Host "  Password          : (as provided)" -ForegroundColor White
Write-Host ""
Write-Host "  Installed software:" -ForegroundColor White
Write-Host "    Docker Desktop, Python 3.12, PowerShell 7 + Az + Microsoft.Graph" -ForegroundColor White
Write-Host "    GitHub CLI + Copilot CLI, Visual Studio Code + extensions (on first login)" -ForegroundColor White
if($InstallVsCodeWeb) {
    Write-Host "    VS Code Web (HTTPS proxy with login, auto-starts on boot)" -ForegroundColor White
}
Write-Host ""
Write-Host "  VS Code extensions install automatically on first RDP login." -ForegroundColor Yellow
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# ── MSTSC profile generation ─────────────────────────────────────────────────
if ($MstscProfilePath) {
    # Fix path: if it's an existing directory or has no extension, treat as directory and append filename
    if ((Test-Path $MstscProfilePath -PathType Container) -or
        (-not [System.IO.Path]::GetExtension($MstscProfilePath))) {
        $MstscProfilePath = Join-Path $MstscProfilePath "$VMName.rdp"
        Write-Warn "Path was a directory — resolved to '$MstscProfilePath'"
    }
    # Ensure .rdp extension
    if ([System.IO.Path]::GetExtension($MstscProfilePath) -ne '.rdp') {
        $MstscProfilePath = [System.IO.Path]::ChangeExtension($MstscProfilePath, '.rdp')
        Write-Warn "Fixed extension — profile path is now '$MstscProfilePath'"
    }

    Write-Step "Generating MSTSC profile at '$MstscProfilePath'"
    $rdpContent = @"
full address:s:$publicIp
username:s:$VMUser
screen mode id:i:2
use multimon:i:0
session bpp:i:32
audiomode:i:0
authentication level:i:0
prompt for credentials:i:1
redirectclipboard:i:1
"@
    $profileDir = Split-Path $MstscProfilePath -Parent
    if ($profileDir -and -not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
        Write-Warn "Fixed missing directory — created '$profileDir'"
    }
    $rdpContent | Out-File -FilePath $MstscProfilePath -Encoding UTF8 -Force
    Write-Ok "RDP profile saved to: $MstscProfilePath"
}

if ($OpenMstsc) {
    if (-not $MstscProfilePath) {
        Write-Warn "Cannot open mstsc: -MstscProfilePath was not specified, so no .rdp profile was generated."
    } elseif (-not (Test-Path $MstscProfilePath)) {
        Write-Warn "Cannot open mstsc: RDP profile not found at '$MstscProfilePath'."
    } else {
        Write-Step "Launching mstsc with profile '$MstscProfilePath'"
        Start-Process mstsc -ArgumentList "`"$MstscProfilePath`""
        Write-Ok "mstsc started"
    }
}

# ── Summary ──────────────────────────────────────────────────────────────────
$deployStopwatch.Stop()
$totalMin = [math]::Floor($deployStopwatch.Elapsed.TotalMinutes)
$totalSec = $deployStopwatch.Elapsed.Seconds
Write-Host ""
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Deployment completed in ${totalMin}m ${totalSec}s" -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
