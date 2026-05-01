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
| `-HubVnetId` | *(empty)* | Resource ID of hub VNet to peer with (for VPN gateway access) |
| `-DisablePublicIp` | `$false` | Disable public IP on the VM (use private IP via VPN instead) |
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

## Connectivity Modes

You can connect to the VM using a **public IP**, **private IP (via VPN)**, or **both**.

### Public IP Only (default)

No extra configuration needed — just run `deploy.ps1`. The VM gets a static public IP and the NSG allows RDP inbound.

```powershell
.\deploy.ps1 -VMPassword 'S3cureP@ssword!'
```

### Private IP Only (via Point-to-Site VPN)

For private-only connectivity, first deploy the hub VPN infrastructure, then deploy the VM without a public IP:

1. Run `deploy-vpn.ps1` to create the hub VNet and P2S VPN Gateway
2. Run `deploy.ps1` with `-HubVnetId` and `-DisablePublicIp`

When `-DisablePublicIp` is set:
- The VM has **no public IP** — all connections go through the private IP via VPN
- The temporary WinRM NSG rule (used during provisioning) is **skipped** since traffic flows over the VPN tunnel
- RDP and VS Code Web must be accessed via the VM's private IP

> **Note:** The hub VPN and the VM can live in different subscriptions. Use `Select-AzSubscription` to switch context between steps.

```powershell
# Step 1 — Deploy hub VPN (can be in a shared/hub subscription)
Select-AzSubscription "Hub-Subscription"
.\deploy-vpn.ps1 -ResourceGroup "hubnet" -Location "Norway East"
# Note the VNet Resource ID from the summary output

# Step 2 — Deploy VM with private connectivity only (can be in a different subscription)
Select-AzSubscription "Dev-Subscription"
.\deploy.ps1 -VMPassword 'S3cureP@ssword!' `
    -HubVnetId "/subscriptions/<hub-sub-id>/resourceGroups/hubnet/providers/Microsoft.Network/virtualNetworks/hub-vnet" `
    -DisablePublicIp
```

### Both Public and Private IP

To have both connectivity options (e.g., public RDP + VPN for internal services), deploy with `-HubVnetId` but **without** `-DisablePublicIp`:

```powershell
Select-AzSubscription "Hub-Subscription"
.\deploy-vpn.ps1 -ResourceGroup "hubnet"

Select-AzSubscription "Dev-Subscription"
.\deploy.ps1 -VMPassword 'S3cureP@ssword!' `
    -HubVnetId "/subscriptions/<hub-sub-id>/resourceGroups/hubnet/providers/Microsoft.Network/virtualNetworks/hub-vnet"
```

This creates VNet peering between the hub and spoke, keeps the public IP, and allows access via either path.

### `deploy-vpn.ps1` Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-LocalVpnProfileName` | `hubnet` | Name for the local Windows VPN connection profile |
| `-ResourceGroup` | `hubnet` | Azure resource group for the hub VNet + gateway |
| `-Location` | `Norway East` | Azure region |
| `-vnetSpace` | `10.0.0.0/23` | VNet address space in CIDR (minimum /23) |
| `-GatewaySku` | `VpnGw1AZ` | VPN Gateway SKU (`VpnGw1AZ` or `VpnGw2AZ`) |
| `-RemoveVpn` | `$false` | Remove VPN gateway and public IP (VNet is kept) |

> **Cost Warning:** VPN Gateways cannot be paused/stopped. To stop charges, delete the gateway:
> ```powershell
> .\deploy-vpn.ps1 -ResourceGroup "hubnet" -RemoveVpn
> ```

---

## Architecture

### Public IP Mode (default)

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

### Private IP Mode (VPN)

```
┌─────────────────────────────────┐     ┌──────────────────────────────────┐
│       Hub Subscription          │     │       Spoke Subscription         │
├─────────────────────────────────┤     ├──────────────────────────────────┤
│                                 │     │                                  │
│  ┌───────────────────────────┐  │     │  ┌────────────────────────────┐  │
│  │  hub-vnet (10.0.0.0/23)   │  │     │  │  spoke-vnet                │  │
│  │                           │  │     │  │                            │  │
│  │  ┌─────────────────────┐  │◄─peering─►│  ┌──────────────────────┐  │  │
│  │  │ GatewaySubnet       │  │  │     │  │  │  Windows 11 Dev VM   │  │  │
│  │  │  ┌───────────────┐  │  │  │     │  │  │  (private IP only)   │  │  │
│  │  │  │ VPN Gateway   │  │  │  │     │  │  └──────────────────────┘  │  │
│  │  │  │ (P2S IKEv2)   │  │  │  │     │  └────────────────────────────┘  │
│  │  │  └───────┬───────┘  │  │  │     │                                  │
│  │  └──────────┼──────────┘  │  │     └──────────────────────────────────┘
│  └─────────────┼─────────────┘  │
└────────────────┼────────────────┘
                 │ IPsec tunnel
         ┌───────▼────────┐
         │  Your machine  │
         │  (VPN client)  │
         └────────────────┘
```

---

## How It Works

1. **Provision infrastructure** — Deploys a Bicep template creating VNet, NSG, NIC, and the VM with a WinRM HTTPS extension. A public IP is included unless `-DisablePublicIp` is set.
2. **VNet peering** *(when `-HubVnetId` is provided)* — Creates spoke→hub and hub→spoke peering with gateway transit enabled, allowing VPN clients to reach the VM's private IP.
3. **Remote configuration** — Opens a temporary WinRM port (skipped when `-DisablePublicIp` is set, since traffic flows over the VPN tunnel), establishes a PowerShell Remoting session to the VM's IP, and runs setup steps with live progress output.
4. **Software installation** — Installs Chocolatey, enables Windows features, then installs Docker (auto-start), Git, Python, PowerShell 7, VS Code, GitHub CLI, Az & Graph modules.
5. **VS Code Web** *(optional)* — Deploys a Node.js HTTPS reverse proxy on port 9443 with password-based login, backed by `code serve-web` on localhost:8080. Desktop extensions are symlinked so they appear in the web UI.
6. **Cleanup & restart** — Removes the WinRM NSG rule (if it was added), restarts the VM to finalize Docker/WSL2 setup.

The deployment is **idempotent** — re-running the script skips the Bicep deployment if the VM already exists.

---

## Security Notes

- WinRM HTTPS is used only during provisioning; In public IP mode, the NSG rule is **automatically removed** after setup completes. In private IP mode, the rule is never added since provisioning happens over the VPN tunnel.
- RDP (3389) and optionally VS Code Web (9443) are open in the NSG. Consider restricting the source IP to your own address, when running in public IP mode.
- VS Code Web uses a self-signed TLS certificate and password-based session cookies.
- Trusted Launch with Secure Boot and vTPM is enabled by default.
- VM password must meet complexity requirements (12+ characters, mixed case, digit).

---

## Project Structure

```
├── deploy.ps1          # Main deployment orchestrator
├── deploy-vpn.ps1      # Hub VNet + P2S VPN Gateway deployment
├── vscodeweb/
│   └── server.js       # HTTPS auth proxy for VS Code Web
├── infra/
│   ├── main.bicep      # Azure infrastructure template
│   └── setup.ps1       # Standalone VM setup script (for manual use)
└── README.md
```

