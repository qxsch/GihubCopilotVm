# GitHub Copilot Dev VM

One-command deployment of a fully configured **Windows 11 development VM** on Azure - batteries included.

```powershell
.\deploy.ps1 -VMPassword 'YourSecureP@ss1'
```

Optionally enable **VS Code Web** — a browser-based VS Code accessible via HTTPS on Port 9443 with password login:

```powershell
.\deploy.ps1 -VMPassword 'YourSecureP@ss1' -InstallVsCodeWeb
```

The script provisions the VM, connects via WinRM, installs all dev tools, and hands you an RDP-ready machine in minutes.

---

## What You Get

| Layer | Details |
|-------|---------|
| **OS** | Windows 11 Pro 24H2, Trusted Launch (Secure Boot + vTPM) |
| **Compute** | Standard_D4s_v5 (4 vCPU, 16 GB RAM, nested virtualization) |
| **Storage** | 256 GB Premium SSD |
| **Network** | Static public IP, NSG with RDP access |

### Pre-installed Software

| Tool | Version |
|------|---------|
| Docker Desktop | Latest (Hyper-V / WSL2 backend, auto-starts at boot) |
| Git | Latest |
| Python | 3.12 |
| PowerShell | 7.x |
| Visual Studio Code | Latest |
| GitHub CLI + GitHub Copilot CLI | Latest |
| Az PowerShell module | Latest |
| Microsoft.Graph module | Latest |
| Node.js (LTS) | Latest |
| Chocolatey | Latest |

### VS Code Extensions (auto-installed on first login)

- GitHub Copilot & Copilot Chat
- Python & Debugpy
- Azure Account & Resource Groups
- Azure Functions
- PowerShell
- Markdown All in One & Mermaid
- Remote - WSL
- Docker
- Azure Tools
- Dev Containers

---

## Prerequisites

- **Azure subscription** with permissions to create resources
- **Az PowerShell module** installed locally (`Install-Module Az`)
- Authenticated session (`Connect-AzAccount`)

---

## Quick Start

```powershell
# Clone the repo
git clone https://github.com/qxsch/GihubCopilotVm.git
cd GihubCopilotVm

# Deploy with defaults (Norway East, Standard_D4s_v5) and open mstsc at the end
.\deploy.ps1 -VMPassword 'S3cureP@ssword!' -MstscProfilePath ./ghcp-vm.rdp -OpenMstsc
```

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | `ghcpshell` | Azure resource group name |
| `-VMUser` | `ghcpdev` | VM admin username |
| `-VMPassword` | *(required)* | VM admin password (12+ chars, mixed case + digit) |
| `-Location` | `Norway East` | Azure region |
| `-VMName` | `ghcp-vm` | VM resource name |
| `-VMSize` | `Standard_D4s_v5` | VM SKU (must support nested virtualization) |
| `-MstscProfilePath` | *(empty)* | Path to write an `.rdp` profile file |
| `-OpenMstsc` | `$false` | Launch Remote Desktop after deployment |
| `-InstallVsCodeWeb` | `$false` | Deploy VS Code Web (HTTPS proxy with login on port 9443) |
| `-VsCodeWebPassword` | *(VMPassword)* | Password for VS Code Web login |

### Examples

```powershell
# Custom region and size
.\deploy.ps1 -Location "West Europe" -VMSize "Standard_D8s_v5" -VMPassword 'P@ss1234abcd'

# Generate and open RDP profile
.\deploy.ps1 -VMPassword 'P@ss1234abcd' -MstscProfilePath ./connect.rdp -OpenMstsc

# Deploy with VS Code Web interface
.\deploy.ps1 -VMPassword 'P@ss1234abcd' -InstallVsCodeWeb
# Then open https://<public-ip>:9443 in your browser
```

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                  Azure Resource Group                │
├──────────────────────────────────────────────────────┤
│                                                      │
│  ┌───────────┐    ┌─────┐    ┌────────────────────┐  │
│  │ Public IP │◄──►│ NIC │◄──►│    Windows 11      │  │
│  │ (Static)  │    │     │    │    Dev VM          │  │
│  └───────────┘    └─────┘    │                    │  │
│                      │       │  ┌──────────────┐  │  │
│               ┌──────┴────┐  │  │ VS Code Web  │  │  │
│               │  VNet/NSG │  │  │ :9443 HTTPS  │  │  │
│               │ RDP+9443  │  │  └──────┬───────┘  │  │
│               └───────────┘  │         │          │  │
│                              │  ┌──────▼───────┐  │  │
│                              │  │ serve-web    │  │  │
│                              │  │ :8080 local  │  │  │
│                              │  └──────────────┘  │  │
│                              └────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

---

## How It Works

1. **Provision infrastructure** — Deploys a Bicep template creating VNet, NSG, public IP, NIC, and the VM with a WinRM HTTPS extension.
2. **Remote configuration** — Opens a temporary WinRM port, establishes a PowerShell Remoting session, and runs setup steps with live progress output.
3. **Software installation** — Installs Chocolatey, enables Windows features, then installs Docker (auto-start), Git, Python, PowerShell 7, VS Code, GitHub CLI, Az & Graph modules.
4. **VS Code Web** *(optional)* — Deploys a Node.js HTTPS reverse proxy on port 9443 with password-based login, backed by `code serve-web` on localhost:8080. Desktop extensions are symlinked so they appear in the web UI.
5. **Cleanup & restart** — Removes the WinRM NSG rule, restarts the VM to finalize Docker/WSL2 setup.

The deployment is **idempotent** — re-running the script skips the Bicep deployment if the VM already exists.

---

## Security Notes

- WinRM HTTPS is used only during provisioning; the NSG rule is **automatically removed** after setup completes.
- RDP (3389) and optionally VS Code Web (9443) are open in the NSG. Consider restricting the source IP to your own address.
- VS Code Web uses a self-signed TLS certificate and password-based session cookies.
- Trusted Launch with Secure Boot and vTPM is enabled by default.
- VM password must meet complexity requirements (12+ characters, mixed case, digit).

---

## Project Structure

```
├── deploy.ps1          # Main deployment orchestrator
├── vscodeweb/
│   └── server.js       # HTTPS auth proxy for VS Code Web
├── infra/
│   ├── main.bicep      # Azure infrastructure template
│   └── setup.ps1       # Standalone VM setup script (for manual use)
└── README.md
```

