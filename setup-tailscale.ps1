# Tailscale setup for connecting to the family Minecraft server.
#
# Run with:
#   irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/setup-tailscale.ps1 | iex

$ErrorActionPreference = 'Stop'

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

# Re-launch elevated if not already admin (needed to install Tailscale).
# Re-downloads and re-runs this same script rather than relying on a local
# file path, since piping via `irm | iex` never saves one to disk.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "This needs to run as Administrator - relaunching..." -ForegroundColor Yellow
    $relaunch = 'irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/setup-tailscale.ps1 | iex'
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$relaunch`""
    exit
}

Write-Host "==================================================" -ForegroundColor Green
Write-Host " Family Minecraft Server - Tailscale Setup" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green

$tailscaleExe = "C:\Program Files\Tailscale\tailscale.exe"

if (Test-Path $tailscaleExe) {
    Write-Step "Tailscale is already installed."
} else {
    Write-Step "Installing Tailscale..."
    $installed = $false

    # Prefer winget if available - cleanest, most reliable
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            winget install --id Tailscale.Tailscale -e --silent --accept-package-agreements --accept-source-agreements
            $installed = $true
        } catch {
            Write-Host "winget install failed, trying direct download instead..." -ForegroundColor Yellow
        }
    }

    if (-not $installed) {
        $installerPath = "$env:TEMP\tailscale-setup.exe"
        Write-Host "Downloading Tailscale installer..."
        Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" -OutFile $installerPath
        Write-Host "Running installer (this may take a minute)..."
        Start-Process -FilePath $installerPath -ArgumentList "/quiet" -Wait
        Remove-Item $installerPath -ErrorAction SilentlyContinue
    }

    # Give the service a moment to register after install
    Start-Sleep -Seconds 5

    if (-not (Test-Path $tailscaleExe)) {
        Write-Host "Installation may not have completed. Please install Tailscale manually from https://tailscale.com/download and re-run this script." -ForegroundColor Red
        Read-Host "Press Enter to exit"
        exit 1
    }
    Write-Host "Tailscale installed successfully." -ForegroundColor Green
}

Write-Step "Checking connection status..."
$status = & $tailscaleExe status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue

if ($status -and $status.Self -and $status.Self.Online) {
    Write-Host "Already signed in and connected as '$($status.Self.HostName)'." -ForegroundColor Green
} else {
    Write-Step "Signing in to the family Tailscale network..."
    Write-Host "A browser window will open - log in (or create a free account) and accept the invite you were sent." -ForegroundColor Yellow
    Write-Host "Waiting for you to finish in the browser..." -ForegroundColor Yellow

    Start-Process $tailscaleExe -ArgumentList "up" -NoNewWindow

    # Poll for connection, up to 3 minutes
    $connected = $false
    for ($i = 0; $i -lt 36; $i++) {
        Start-Sleep -Seconds 5
        $status = & $tailscaleExe status --json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($status -and $status.Self -and $status.Self.Online) {
            $connected = $true
            break
        }
    }

    if ($connected) {
        Write-Host "Connected successfully!" -ForegroundColor Green
    } else {
        Write-Host "Still waiting on sign-in. Once you finish logging in in the browser, you're done - no need to re-run this." -ForegroundColor Yellow
    }
}

Write-Step "Setup complete!"
Write-Host ""
Write-Host "Ask whoever invited you for the Minecraft server address to add in-game." -ForegroundColor Cyan
Write-Host "(You must stay signed in to Tailscale for the server to be reachable - it runs quietly in the background automatically.)" -ForegroundColor Gray
Write-Host ""
Read-Host "Press Enter to close"
