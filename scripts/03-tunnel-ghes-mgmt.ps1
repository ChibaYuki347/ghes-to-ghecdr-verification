# Azure Bastion tunnel from Windows PowerShell (PoC for WSL+VPN environments)
#
# Why PowerShell instead of WSL bash?
#   When a VPN client (Microsoft Entra Global Secure Access, GlobalProtect, Cisco AnyConnect, etc.)
#   is active on Windows, WSL2's NAT network is not handled cleanly:
#     - WSL DNS / loopback can be hijacked by the VPN client
#     - WSL listeners bound to 127.0.0.1 may not be reachable from Windows
#   This is acknowledged as a Known Issue in Microsoft's internal Global Secure Access guidance.
#   Public workaround: run `az` directly on Windows so traffic does not traverse the WSL VM.
#
# Prerequisites:
#   - Azure CLI for Windows installed (`winget install Microsoft.AzureCLI` or MSI)
#   - `az login` already executed in this PowerShell session
#   - Bastion extension auto-installs on first `az network bastion tunnel`
#
# Usage:
#   .\scripts\03-tunnel-ghes-mgmt.ps1                # Management Console: 8443 -> 8443
#   .\scripts\03-tunnel-ghes-mgmt.ps1 -Mode web      # Web UI / Git HTTPS:  8444 -> 443
#   .\scripts\03-tunnel-ghes-mgmt.ps1 -Mode ssh      # Git SSH:             2200 -> 22
#   .\scripts\03-tunnel-ghes-mgmt.ps1 -Mode adminshell  # GHES admin shell: 2222 -> 122

[CmdletBinding()]
param(
    [ValidateSet('mgmt', 'web', 'ssh', 'adminshell')]
    [string]$Mode = 'mgmt',
    [string]$SubscriptionId,
    [string]$ResourceGroup = 'rg-ghestest-jpe',
    [string]$BastionName = 'bas-ghestest',
    [string]$VmName = 'vm-ghestest-ghes',
    [int]$LocalPort,
    [int]$ResourcePort
)

$ErrorActionPreference = 'Stop'

# Auto-load subscription from .env if not provided
if (-not $SubscriptionId) {
    $envFile = Join-Path $PSScriptRoot '..\.env'
    if (Test-Path $envFile) {
        Get-Content $envFile | ForEach-Object {
            if ($_ -match '^\s*AZURE_SUBSCRIPTION_ID\s*=\s*"?([^"]+)"?\s*$') {
                $SubscriptionId = $Matches[1]
            }
        }
    }
}

if (-not $SubscriptionId) {
    Write-Error 'AZURE_SUBSCRIPTION_ID not found. Pass -SubscriptionId or set it in .env'
    exit 1
}

# Set the active subscription (idempotent)
$current = az account show --query id -o tsv 2>$null
if ($current -ne $SubscriptionId) {
    Write-Host "[INFO] Setting subscription to $SubscriptionId" -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
}

# Resolve VM resource ID
$vmId = az vm show -g $ResourceGroup -n $VmName --query id -o tsv 2>$null
if (-not $vmId) {
    Write-Error "Could not find VM '$VmName' in resource group '$ResourceGroup'"
    exit 1
}

# Mode -> port mapping
switch ($Mode) {
    'mgmt' {
        if (-not $ResourcePort) { $ResourcePort = 8443 }
        if (-not $LocalPort)    { $LocalPort    = 8443 }
        Write-Host '[Management Console]' -ForegroundColor Green
        Write-Host "Browse to: https://localhost:$LocalPort/setup/"
    }
    'web' {
        if (-not $ResourcePort) { $ResourcePort = 443 }
        if (-not $LocalPort)    { $LocalPort    = 8444 }
        Write-Host '[Web UI / Git HTTPS]' -ForegroundColor Green
        Write-Host "Browse to: https://<your-ghes-hostname>:$LocalPort/"
        Write-Host '  -> Make sure that hostname resolves to 127.0.0.1 in your Windows hosts file.'
    }
    'ssh' {
        if (-not $ResourcePort) { $ResourcePort = 22 }
        if (-not $LocalPort)    { $LocalPort    = 2200 }
        Write-Host '[Git SSH]' -ForegroundColor Green
        Write-Host "Connect with: ssh -p $LocalPort <user>@localhost"
    }
    'adminshell' {
        if (-not $ResourcePort) { $ResourcePort = 122 }
        if (-not $LocalPort)    { $LocalPort    = 2222 }
        Write-Host '[GHES Admin Shell]' -ForegroundColor Green
        Write-Host "Connect with: ssh -i ~/.ssh/<your-key> -p $LocalPort admin@localhost"
    }
}

Write-Host "Press Ctrl+C to close the tunnel."
Write-Host ''

az network bastion tunnel `
    --name $BastionName `
    --resource-group $ResourceGroup `
    --target-resource-id $vmId `
    --resource-port $ResourcePort `
    --port $LocalPort
