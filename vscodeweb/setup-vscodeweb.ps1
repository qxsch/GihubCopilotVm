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

.PARAMETER Host
    Hostname / domain for the proxy (default localhost). Used for VIBE_HOST env var.

.PARAMETER CertPath
    Path to TLS certificate (fullchain.pem). Falls back to self-signed in C:\vscodeweb\certs.

.PARAMETER KeyPath
    Path to TLS private key (privkey.pem). Falls back to self-signed in C:\vscodeweb\certs.
#>
param(
    [Parameter(Mandatory)]
    [string]$Password,

    [int]$Port = 9443,
    [int]$CodeServerPort = 8080,
    [string]$Host = 'localhost',
    [string]$CertPath,
    [string]$KeyPath
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
$serveWebBase = "$env:USERPROFILE\.vscode\cli\serve-web"
$commitDir = Get-ChildItem $serveWebBase -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $commitDir) { throw "VS Code serve-web not found. Run 'code.cmd serve-web' once to initialize." }
$nodePath = Join-Path $commitDir.FullName "node.exe"
$serverMainPath = Join-Path $commitDir.FullName "out\server-main.js"
if (-not (Test-Path $nodePath)) { throw "node.exe not found at $nodePath" }
if (-not (Test-Path $serverMainPath)) { throw "server-main.js not found at $serverMainPath" }
Write-Output "VS Code serve-web backend ready at $($commitDir.Name)"

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

# Install ws dependency (required by server.js for WebSocket proxying)
Push-Location $VibeDir
if (-not (Test-Path "$VibeDir\node_modules\ws")) {
    Write-Output "Installing ws npm package..."
    & npm init -y 2>&1 | Out-Null
    & npm install ws 2>&1 | Out-Null
}
Pop-Location
Write-Output "ws dependency ready"

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

# ─── 7. Patch VS Code server for 30-day session persistence ──────────────────
Write-Output "`n>>> Patching VS Code serve-web for 30-day reconnection grace time..."
$serveWebDir = "$env:USERPROFILE\.vscode\cli\serve-web"
if (Test-Path $serveWebDir) {
    Get-ChildItem $serveWebDir -Filter "server-main.js" -Recurse | ForEach-Object {
        $c = Get-Content $_.FullName -Raw
        $old = 'reconnection-grace-time"],108e5)'
        $new = 'reconnection-grace-time"],2592e6)'
        if ($c.Contains($old)) {
            $c = $c.Replace($old, $new)
            [System.IO.File]::WriteAllText($_.FullName, $c)
            Write-Output "  Patched: $($_.FullName) (3h -> 30d)"
        } else {
            Write-Output "  Already patched or not needed: $($_.FullName)"
        }
    }
}

# ─── 8. VS Code Machine settings (terminal persistence) ──────────────────────
Write-Output "`n>>> Configuring VS Code Machine settings..."
$machineDir = "$env:USERPROFILE\.vscode-server\data\Machine"
if (-not (Test-Path $machineDir)) { New-Item -ItemType Directory -Path $machineDir -Force | Out-Null }
@'
{
  "terminal.integrated.enablePersistentSessions": true,
  "terminal.integrated.persistentSessionReviveProcess": "onExitAndWindowClose",
  "terminal.integrated.persistentSessionScrollback": 10000
}
'@ | Out-File -FilePath "$machineDir\settings.json" -Encoding UTF8 -Force
Write-Output "Machine settings written"

# ─── 9. Create startup scripts ───────────────────────────────────────────────
Write-Output "`n>>> Creating startup scripts..."

# VS Code serve-web startup (PS1 wrapper with logging)
# Launches server-main.js directly (bypasses code-tunnel.exe which breaks WebSocket)
# Also re-applies 30-day reconnection grace time patch on each start (survives VS Code updates)
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
'@ | Out-File -FilePath "$VibeDir\start-codeserver.ps1" -Encoding UTF8 -Force

# Resolve certificate paths (use ACME certs if available, else self-signed)
if (-not $CertPath) {
    $acmeCert = "C:\Certbot\live\$Host\fullchain.pem"
    if ($Host -ne 'localhost' -and (Test-Path $acmeCert)) {
        $CertPath = $acmeCert
        $KeyPath = "C:\Certbot\live\$Host\privkey.pem"
    } else {
        $CertPath = "$VibeDir\certs\cert.pem"
        $KeyPath = "$VibeDir\certs\key.pem"
    }
}

# Proxy startup (.ps1 to preserve ! in password)
@"
`$env:CODESERVER_PORT = "$CodeServerPort"
`$env:VIBE_PORT = "$Port"
`$env:VIBE_PASSWORD = "$Password"
`$env:VIBE_HOST = "$Host"
`$env:VIBE_CERT = "$CertPath"
`$env:VIBE_KEY = "$KeyPath"
Set-Location "$VibeDir"
& node server.js *> "$VibeDir\logs\vscodeweb.log"
"@ | Out-File -FilePath "$VibeDir\start-vscodeweb.ps1" -Encoding UTF8 -Force

# ─── 10. Register scheduled tasks (Password logon = runs without interactive login) ─
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
