param(
    [string]$VMUser = "ghcpdev"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Output "=== Windows 11 Dev VM Setup Script ==="
Write-Output "Setting up for user: $VMUser"

# ---------- Helper ----------
function Refresh-Path {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}

# ---------- 1. Install Chocolatey ----------
Write-Output "`n>>> Installing Chocolatey..."
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
Refresh-Path

# ---------- 2. Enable Windows Features for Docker (WSL2 + Hyper-V) ----------
Write-Output "`n>>> Enabling Windows features (WSL2, Hyper-V, Containers)..."
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux -NoRestart -All | Out-Null
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart -All | Out-Null
try {
    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart -All | Out-Null
} catch {
    Write-Output "Hyper-V feature not available on this SKU, continuing with WSL2 backend..."
}
Enable-WindowsOptionalFeature -Online -FeatureName Containers -NoRestart -All | Out-Null

# ---------- 3. Install Python ----------
Write-Output "`n>>> Installing Python..."
choco install python312 --yes --no-progress
Refresh-Path

# ---------- 4. Install PowerShell 7 ----------
Write-Output "`n>>> Installing PowerShell 7..."
choco install pwsh --yes --no-progress
Refresh-Path

# ---------- 5. Install Docker Desktop ----------
Write-Output "`n>>> Installing Docker Desktop..."
choco install docker-desktop --yes --no-progress
Refresh-Path

# ---------- 6. Install Visual Studio Code ----------
Write-Output "`n>>> Installing Visual Studio Code..."
choco install vscode --yes --no-progress --params "/NoDesktopIcon"
Refresh-Path

# ---------- 7. Install Az PowerShell Module ----------
Write-Output "`n>>> Installing Az PowerShell module..."
$pwshExe = "C:\Program Files\PowerShell\7\pwsh.exe"
if (Test-Path $pwshExe) {
    & $pwshExe -NoProfile -Command "Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name Az -Force -AllowClobber -Scope AllUsers"
} else {
    Write-Output "PowerShell 7 not found at expected path, installing Az module in Windows PowerShell..."
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name Az -Force -AllowClobber -Scope AllUsers
}

# ---------- 8. Setup VS Code Extensions (first-login task) ----------
Write-Output "`n>>> Configuring VS Code extensions for first login..."

$setupDir = "C:\setup"
if (-not (Test-Path $setupDir)) { New-Item -ItemType Directory -Path $setupDir -Force | Out-Null }

$extensionsScript = @'
$ErrorActionPreference = 'SilentlyContinue'
$codePath = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
if (-not (Test-Path $codePath)) {
    $codePath = (Get-Command code -ErrorAction SilentlyContinue).Source
}
if (-not $codePath) {
    Write-Output "VS Code not found, skipping extension installation."
    exit 0
}

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
)

foreach ($ext in $extensions) {
    Write-Output "Installing extension: $ext"
    & $codePath --install-extension $ext --force 2>&1 | Out-Null
}

# Self-cleanup
Unregister-ScheduledTask -TaskName "InstallVSCodeExtensions" -Confirm:$false -ErrorAction SilentlyContinue
'@

$extensionsScript | Out-File -FilePath "$setupDir\install-extensions.ps1" -Encoding UTF8 -Force

# Create scheduled task to run on user logon
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File C:\setup\install-extensions.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $VMUser
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName "InstallVSCodeExtensions" -Action $action -Trigger $trigger -Settings $settings -RunLevel Highest -Force | Out-Null

Write-Output "`n>>> VS Code extensions will be installed on first login of user '$VMUser'."

# ---------- 9. Add user to docker-users group ----------
Write-Output "`n>>> Adding $VMUser to docker-users group..."
try {
    net localgroup "docker-users" $VMUser /add 2>&1 | Out-Null
} catch {
    Write-Output "Could not add to docker-users group (may not exist until Docker starts)."
}

# ---------- Done ----------
Write-Output "`n=== Setup complete! A reboot is required for Docker/WSL2 features. ==="
