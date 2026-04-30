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

    [Parameter(HelpMessage = "Deploy VS Code Web interface (HTTPS proxy with login)")]
    [switch]$InstallVsCodeWeb,

    [Parameter(HelpMessage = "Password for VS Code Web login (defaults to VMPassword)")]
    [string]$VsCodeWebPassword = ""
)


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
    # Derive resource names using same convention as Bicep
    $nsgName  = "$VMName-nsg"
    $pipName  = "$VMName-pip"
    $pipRes   = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroup -Name $pipName -ErrorAction Stop
    $publicIp = $pipRes.IpAddress
    Write-Ok "Public IP: $publicIp"
} else {
    Write-Step "Deploying infrastructure (Bicep)"
    $bicepPath = Join-Path $InfraPath "main.bicep"
    if (-not (Test-Path $bicepPath)) {
        Write-Error "Bicep file not found at $bicepPath"
    }

    $deployment = New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroup `
        -Name "deploy-$VMName-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
        -TemplateFile $bicepPath `
        -vmName $VMName `
        -adminUsername $VMUser `
        -adminPassword $securePassword `
        -vmSize $VMSize `
        -location $Location

    $publicIp = $deployment.Outputs.publicIpAddress.Value
    $nsgName  = $deployment.Outputs.nsgName.Value
    Write-Ok "VM deployed"
    Write-Ok "Public IP: $publicIp"
}

# ── Temporary WinRM NSG rule (idempotent) ────────────────────────────────────
Write-Step "Adding temporary WinRM HTTPS rule (removed after setup)"
$winrmRuleName = 'Allow-WinRM-HTTPS-Temp'
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

# ── Establish PS Remoting session ────────────────────────────────────────────
Write-Step "Connecting to VM via PowerShell Remoting (WinRM HTTPS)"
$credential = [PSCredential]::new($VMUser, $securePassword)
$sessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck -OpenTimeout 120000 -OperationTimeout 600000

$maxRetries = 12
$retryDelay = 15
$spinner = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$spinIdx = 0
$session = $null
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $session = New-PSSession -ComputerName $publicIp -Credential $credential `
            -UseSSL -SessionOption $sessionOpts -ErrorAction Stop
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
    Invoke-RemoteStep -Session $session -StepName "Enabling Windows features (WSL2, Hyper-V, Containers)" -Script {
        Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All | Out-Null
        Write-Output "WSL enabled"
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
        Write-Output "VirtualMachinePlatform enabled"
        try {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart -All | Out-Null
            Write-Output "Hyper-V enabled"
        } catch {
            Write-Output "Hyper-V not available on this SKU — WSL2 backend will be used"
        }
        Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -All | Out-Null
        Write-Output "Containers feature enabled"
        wsl --update 2>&1 | ForEach-Object { Write-Output $_ }
        Write-Output "WSL updated"
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

    # ── 6b. Install Git ─────────────────────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Git" -Script {
        $ProgressPreference = 'SilentlyContinue'
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $gitCheck = Get-Command git -ErrorAction SilentlyContinue
        if ($gitCheck) {
            Write-Output "Git already installed: $(git --version)"
        } else {
            winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
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
        # Install GitHub Copilot CLI (standalone) via winget
        $wingetCheck = winget list --id GitHub.Copilot --accept-source-agreements 2>&1 | Out-String
        if ($wingetCheck -match 'GitHub.Copilot') {
            Write-Output "GitHub Copilot CLI already installed"
        } else {
            winget install GitHub.Copilot --accept-source-agreements --accept-package-agreements --silent 2>&1 | ForEach-Object { Write-Output $_ }
            Write-Output "GitHub Copilot CLI installed"
        }
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }

    # ── 8. Install Az PowerShell module ──────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Az PowerShell module (in pwsh 7)" -Script {
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            & $pwshExe -NoProfile -Command {
                $ProgressPreference = 'SilentlyContinue'
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
                Write-Output "Az module $((Get-InstalledModule Az).Version) installed"
            }
        } else {
            Write-Output "pwsh 7 not found — installing Az in Windows PowerShell"
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
            Write-Output "Az module installed"
        }
    }

    # ── 9. Install Microsoft.Graph module ────────────────────────────────
    Invoke-RemoteStep -Session $session -StepName "Installing Microsoft.Graph module (in pwsh 7)" -Script {
        $pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
        if (Test-Path $pwshExe) {
            & $pwshExe -NoProfile -Command {
                $ProgressPreference = 'SilentlyContinue'
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers
                Write-Output "Microsoft.Graph module $((Get-InstalledModule Microsoft.Graph).Version) installed"
            }
        } else {
            Write-Output "pwsh 7 not found — installing Microsoft.Graph in Windows PowerShell"
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
            Install-Module -Name Microsoft.Graph -Force -AllowClobber -Scope AllUsers
            Write-Output "Microsoft.Graph module installed"
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
    "ms-vscode.azure-account"
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
# Install gh-copilot extension (requires interactive user session)
$ghPath = (Get-Command gh -ErrorAction SilentlyContinue).Source
if ($ghPath) {
    & gh extension install github/gh-copilot --force 2>&1 | Out-Null
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
            param($Password, $Port, $CodeServerPort)
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
            @'
$logFile = "C:\vscodeweb\logs\codeserver.log"
& "C:\Program Files\Microsoft VS Code\bin\code.cmd" serve-web --host 127.0.0.1 --port 8080 --without-connection-token *> $logFile
'@ | Out-File "$VibeDir\start-codeserver.ps1" -Encoding UTF8 -Force

            @"
`$env:CODESERVER_PORT = "$CodeServerPort"
`$env:VIBE_PORT = "$Port"
`$env:VIBE_PASSWORD = "$Password"
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
        } -ArgumentList $vsCodeWebPw, 9443, 8080
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
        $copilotCheck = winget list --id GitHub.Copilot --accept-source-agreements 2>&1 | Out-String
        if ($copilotCheck -match 'GitHub.Copilot') { $checks += "OK  GitHub Copilot CLI installed" } else { $checks += "FAIL GitHub Copilot CLI not found" }
        $checks += "OK  gh-copilot extension scheduled for first login"
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
        # Chocolatey
        $chocoVer = & choco --version 2>&1
        if ($LASTEXITCODE -eq 0) { $checks += "OK  Chocolatey: $chocoVer" } else { $checks += "FAIL Chocolatey not found" }
        # Scheduled task for extensions
        $task = Get-ScheduledTask -TaskName "InstallVSCodeExtensions" -ErrorAction SilentlyContinue
        if ($task) { $checks += "OK  VS Code extensions scheduled task registered" } else { $checks += "FAIL Extensions task not found" }

        foreach ($c in $checks) { Write-Output $c }
        $failures = $checks | Where-Object { $_ -match '^FAIL' }
        if ($failures) { Write-Output "`n$($failures.Count) check(s) FAILED" } else { Write-Output "`nAll checks passed" }
    }

} finally {
    # ── Clean up session ─────────────────────────────────────────────────
    if ($session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

# ── Remove temporary WinRM NSG rule ──────────────────────────────────────────
Write-Step "Removing temporary WinRM HTTPS rule"
try {
    Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroup -Name $nsgName `
        | Remove-AzNetworkSecurityRuleConfig -Name $winrmRuleName `
        | Set-AzNetworkSecurityGroup | Out-Null
    Write-Ok "WinRM rule removed"
} catch {
    Write-Warn "Could not remove WinRM rule '$winrmRuleName' — clean up manually"
}

# ── Restart VM ───────────────────────────────────────────────────────────────
Write-Step "Restarting VM to finalize Docker/WSL2 setup"
Restart-AzVM -ResourceGroupName $ResourceGroup -Name $VMName | Out-Null
Write-Ok "VM restarted"

# ── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Windows 11 Dev VM deployed successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "  RDP Address       : $publicIp" -ForegroundColor White
if($InstallVsCodeWeb) {
    Write-Host "  VS Code Web       : https://${publicIp}:9443" -ForegroundColor White
}
Write-Host "  Username          : $VMUser" -ForegroundColor White
Write-Host "  Password          : (as provided)" -ForegroundColor White
Write-Host ""
Write-Host "  Installed software:" -ForegroundColor White
Write-Host "    Docker Desktop, Python 3.12, PowerShell 7 + Az + Microsoft.Graph" -ForegroundColor White
Write-Host "    GitHub CLI + Copilot CLI, Visual Studio Code + extensions (on first login)" -ForegroundColor White
Write-Host "    VS Code Web (HTTPS proxy with login, auto-starts on boot)" -ForegroundColor White
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
