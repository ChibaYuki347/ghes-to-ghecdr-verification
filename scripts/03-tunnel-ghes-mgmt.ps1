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
    [int]$ResourcePort,
    [switch]$AutoStart,
    [switch]$SkipPreflight,
    [switch]$Force
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

# --- Preflight: verify VM is running before opening tunnel ----------------
if (-not $SkipPreflight) {
    Write-Host '[preflight] Checking GHES VM power state...' -ForegroundColor Cyan
    $powerState = az vm get-instance-view --ids $vmId `
        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" `
        -o tsv 2>$null
    $powerState = $powerState -replace '^PowerState/', ''
    Write-Host "[preflight] GHES VM power state: $powerState"

    switch ($powerState) {
        'running' { }
        { $_ -in 'deallocated', 'stopped', 'stopped (deallocated)', 'deallocating', '' } {
            if ($AutoStart) {
                Write-Host '[preflight] -AutoStart -> starting GHES VM...' -ForegroundColor Yellow
                az vm start --ids $vmId --no-wait
                Write-Host '[preflight] Waiting for VM to reach running state...'
                for ($i = 1; $i -le 30; $i++) {
                    Start-Sleep -Seconds 10
                    $ps = az vm get-instance-view --ids $vmId `
                        --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" `
                        -o tsv 2>$null
                    $ps = $ps -replace '^PowerState/', ''
                    Write-Host "[preflight]   $i/30  state=$ps"
                    if ($ps -eq 'running') {
                        Write-Host '[preflight] VM running. Allowing 90s for GHES service warmup...'
                        Start-Sleep -Seconds 90
                        break
                    }
                }
            } else {
                Write-Error "[preflight] GHES VM is not running (state=$powerState).`nRun with -AutoStart to start it, or:`n  az vm start --ids '$vmId'"
                exit 3
            }
        }
        'starting' {
            Write-Host '[preflight] VM is starting; waiting up to 5 min...'
            for ($i = 1; $i -le 30; $i++) {
                Start-Sleep -Seconds 10
                $ps = az vm get-instance-view --ids $vmId `
                    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" `
                    -o tsv 2>$null
                $ps = $ps -replace '^PowerState/', ''
                if ($ps -eq 'running') {
                    Write-Host '[preflight] VM running. Waiting 90s for GHES warmup...'
                    Start-Sleep -Seconds 90
                    break
                }
            }
        }
        default {
            Write-Warning "[preflight] Unknown VM power state '$powerState'. Continuing anyway."
        }
    }
}
# --------------------------------------------------------------------------

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

# --- Preflight 2: ensure LocalPort is free (or kill stale Bastion tunnel) ---
# Bastion CLI errors with "Defined port is currently unavailable" when the
# port is taken, but does not say which process holds it. A stale tunnel
# (forgotten previous run, VPN switch, PC sleep) is the most common cause.
$existingConn = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($existingConn) {
    $existingPid = $existingConn.OwningProcess
    $existingProc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
    $procName = if ($existingProc) { $existingProc.ProcessName } else { 'unknown' }

    # Best-effort fetch of the command line via WMI/CIM
    $cmdLine = ''
    try {
        $cimProc = Get-CimInstance Win32_Process -Filter "ProcessId=$existingPid" -ErrorAction SilentlyContinue
        if ($cimProc) { $cmdLine = $cimProc.CommandLine }
    } catch {}

    Write-Host "[preflight] Local port $LocalPort is held by PID $existingPid ($procName)"
    if ($cmdLine) { Write-Host "[preflight]   cmd: $cmdLine" }

    $isBastion = $false
    if ($cmdLine -match 'bastion' -or $cmdLine -match 'az network') {
        $isBastion = $true
    } elseif ($procName -match '^(python|python3|az)$') {
        # Bastion CLI worker is python.exe / az.exe; treat as probable Bastion.
        $isBastion = $true
    }

    if ($isBastion) {
        if ($Force) {
            Write-Host "[preflight] -Force -> stopping stale Bastion tunnel PID $existingPid..." -ForegroundColor Yellow
            Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $still = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
            if ($still) {
                Write-Error "[preflight] Could not free port $LocalPort. Kill PID $existingPid manually."
                exit 4
            }
            Write-Host "[preflight] Port $LocalPort is free."
        } else {
            Write-Error "[preflight] Detected stale Bastion tunnel on port $LocalPort.`nRe-run with -Force to terminate it, or:`n  Stop-Process -Id $existingPid -Force"
            exit 4
        }
    } else {
        Write-Error "[preflight] Port $LocalPort is held by a non-Bastion process ($procName). Refusing to kill. Use a different -LocalPort or stop that process manually."
        exit 4
    }
}
# ---------------------------------------------------------------------------

Write-Host "Press Ctrl+C to close the tunnel."
Write-Host ''

az network bastion tunnel `
    --name $BastionName `
    --resource-group $ResourceGroup `
    --target-resource-id $vmId `
    --resource-port $ResourcePort `
    --port $LocalPort
