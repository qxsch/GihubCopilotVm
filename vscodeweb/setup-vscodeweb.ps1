<#
.SYNOPSIS
    Sets up VS Code Web on the VM.
    Uses VS Code serve-web + Node.js HTTPS auth proxy.

.DESCRIPTION
    - Uses VS Code's built-in serve-web as the backend
    - Deploys server.js HTTPS proxy with password login
    - Installs Node.js (if not present)
    - Creates Windows scheduled tasks for auto-start
    - Opens firewall port 9443

.PARAMETER Password
    Password for the VS Code Web login.

.PARAMETER Port
    HTTPS port for the proxy (default 9443).

.PARAMETER CodeServerPort
    Internal port for VS Code serve-web (default 8080).
#>
param(
    [Parameter(Mandatory)]
    [string]$Password,

    [int]$Port = 9443,
    [int]$CodeServerPort = 8080
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$VibeDir = "C:\vscodeweb"

Write-Output "=== VS Code Web Setup ==="

# ─── 1. Install Node.js (if needed) ──────────────────────────────────────────
Write-Output "`n>>> Checking Node.js..."
$nodePath = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodePath) {
    Write-Output "Installing Node.js via Chocolatey..."
    choco install nodejs-lts --yes --no-progress
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}
Write-Output "Node.js: $(node --version)"

# ─── 2. Verify VS Code serve-web ─────────────────────────────────────────────
Write-Output "`n>>> Checking VS Code serve-web..."
$codeBin = "C:\Program Files\Microsoft VS Code\bin\code.cmd"
if (-not (Test-Path $codeBin)) { throw "VS Code not found at $codeBin" }
Write-Output "VS Code serve-web backend ready"

# ─── 3. Deploy proxy ─────────────────────────────────────────────────────────
Write-Output "`n>>> Deploying VS Code Web proxy..."
if (-not (Test-Path $VibeDir)) { New-Item -ItemType Directory -Path $VibeDir -Force | Out-Null }
if (-not (Test-Path "$VibeDir\logs")) { New-Item -ItemType Directory -Path "$VibeDir\logs" -Force | Out-Null }

# Copy server.js from same directory as this script
$serverSrc = Join-Path $PSScriptRoot "server.js"
if (Test-Path $serverSrc) {
    Copy-Item $serverSrc "$VibeDir\server.js" -Force
    Write-Output "server.js deployed"
}

# ─── 4. Install OpenSSL for cert generation (if needed) ──────────────────────
Write-Output "`n>>> Checking OpenSSL..."
$opensslPath = Get-Command openssl -ErrorAction SilentlyContinue
if (-not $opensslPath) {
    Write-Output "Installing OpenSSL via Chocolatey..."
    choco install openssl --yes --no-progress
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}
Write-Output "OpenSSL available"

# ─── 5. Firewall rules ───────────────────────────────────────────────────────
Write-Output "`n>>> Configuring firewall..."
$ruleName = "VSCodeWeb-HTTPS-$Port"
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow | Out-Null
}
Write-Output "Firewall rule: port $Port open"

# ─── 6. Symlink extensions ────────────────────────────────────────────────────
Write-Output "`n>>> Symlinking serve-web extensions to desktop extensions..."
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

# ─── 7. Create startup scripts ───────────────────────────────────────────────
Write-Output "`n>>> Creating startup scripts..."

# VS Code serve-web startup (PS1 wrapper with logging)
@'
$logFile = "C:\vscodeweb\logs\codeserver.log"
& "C:\Program Files\Microsoft VS Code\bin\code.cmd" serve-web --host 127.0.0.1 --port 8080 --without-connection-token *> $logFile
'@ | Out-File -FilePath "$VibeDir\start-codeserver.ps1" -Encoding UTF8 -Force

# Proxy startup (.ps1 to preserve ! in password)
@"
`$env:CODESERVER_PORT = "$CodeServerPort"
`$env:VIBE_PORT = "$Port"
`$env:VIBE_PASSWORD = "$Password"
Set-Location "$VibeDir"
& node server.js *> "$VibeDir\logs\vscodeweb.log"
"@ | Out-File -FilePath "$VibeDir\start-vscodeweb.ps1" -Encoding UTF8 -Force

# ─── 8. Register scheduled tasks (Password logon = runs without interactive login) ─
Write-Output "`n>>> Registering auto-start tasks..."

$csAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$VibeDir\start-codeserver.ps1`""
$csTrigger = New-ScheduledTaskTrigger -AtStartup
$csSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "VSCodeWeb-Backend" -Action $csAction -Trigger $csTrigger -Settings $csSettings -RunLevel Highest -User "$env:USERNAME" -Password $Password -Force | Out-Null

$vibeAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$VibeDir\start-vscodeweb.ps1`""
$vibeTrigger = New-ScheduledTaskTrigger -AtStartup
$vibeSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName "VSCodeWeb-Proxy" -Action $vibeAction -Trigger $vibeTrigger -Settings $vibeSettings -RunLevel Highest -User "$env:USERNAME" -Password $Password -Force | Out-Null

Write-Output "`n>>> Starting services..."
Start-ScheduledTask -TaskName "VSCodeWeb-Backend"
Start-Sleep -Seconds 5
Start-ScheduledTask -TaskName "VSCodeWeb-Proxy"

Write-Output "`n=== VS Code Web Setup Complete ==="
Write-Output "Access: https://<VM-PUBLIC-IP>:$Port"
Write-Output "Password: $Password"
