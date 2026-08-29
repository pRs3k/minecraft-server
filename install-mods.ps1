#Requires -Version 5.1
<#
  Webercraft / Poke Server - client mod sync script
  Downloads/updates whatever mods the server currently requires, based on
  mods-manifest.json hosted in the same GitHub repo. Safe to re-run any time -
  it only touches jars it manages, verified by SHA1 hash, and leaves any other
  mods you have installed alone.

  Run it with:
    irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.ps1 | iex
#>

param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/pRs3k/minecraft-server/main/mods-manifest.json",
    [string]$MinecraftDir = (Join-Path $env:APPDATA ".minecraft")
)

# Older Windows PowerShell defaults to TLS 1.0/1.1 on some systems, which GitHub
# and Modrinth's CDN reject. Force TLS 1.2 so downloads don't silently fail.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ErrorActionPreference = "Stop"

function Get-Sha1($path) {
    return (Get-FileHash -Path $path -Algorithm SHA1).Hash.ToLower()
}

Write-Host "=== Poke Server mod sync ===" -ForegroundColor Cyan
Write-Host "Minecraft folder: $MinecraftDir"

$modsDir = Join-Path $MinecraftDir "mods"
if (-not (Test-Path $modsDir)) {
    Write-Host "Creating mods folder at $modsDir"
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
}

$stateFile = Join-Path $modsDir ".server-mod-sync-state.json"

Write-Host "Fetching mod list from $ManifestUrl ..."
try {
    $manifestJson = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing
} catch {
    Write-Host "Could not download the mod manifest. Check your internet connection and try again." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# Load the set of filenames this script has managed before, so we know what's
# safe to remove later (an old version being replaced) without ever touching
# mods you added yourself.
$previouslyManaged = @{}
if (Test-Path $stateFile) {
    $stateObj = Get-Content $stateFile -Raw | ConvertFrom-Json
    foreach ($prop in $stateObj.PSObject.Properties) {
        $previouslyManaged[$prop.Name] = $true
    }
}

$currentFilenames = @{}
$downloaded = 0
$upToDate = 0
$failed = @()

foreach ($mod in $manifestJson.mods) {
    $currentFilenames[$mod.filename] = $true
    $destPath = Join-Path $modsDir $mod.filename

    $needsDownload = $true
    if (Test-Path $destPath) {
        $localHash = Get-Sha1 $destPath
        if ($localHash -eq $mod.sha1.ToLower()) {
            $needsDownload = $false
        }
    }

    if (-not $needsDownload) {
        $upToDate++
        continue
    }

    if (-not $mod.url) {
        Write-Host "  [SKIP] $($mod.filename) - no download URL available, get this one manually." -ForegroundColor Yellow
        $failed += $mod.filename
        continue
    }

    Write-Host "  Downloading $($mod.filename) ..."
    try {
        Invoke-WebRequest -Uri $mod.url -OutFile $destPath -UseBasicParsing
        $newHash = Get-Sha1 $destPath
        if ($newHash -ne $mod.sha1.ToLower()) {
            Write-Host "  [WARN] $($mod.filename) downloaded but its hash doesn't match what the server expects." -ForegroundColor Yellow
            $failed += $mod.filename
        } else {
            $downloaded++
        }
    } catch {
        Write-Host "  [FAIL] Could not download $($mod.filename): $($_.Exception.Message)" -ForegroundColor Red
        $failed += $mod.filename
    }
}

# Remove mods that this script installed previously but are no longer required
# (e.g. the server dropped a mod, or replaced it with a differently-named jar).
# Anything not tracked as "managed" is left alone, even if it's not in the manifest.
$removed = 0
foreach ($oldFile in $previouslyManaged.Keys) {
    if (-not $currentFilenames.ContainsKey($oldFile)) {
        $oldPath = Join-Path $modsDir $oldFile
        if (Test-Path $oldPath) {
            Write-Host "  Removing outdated mod: $oldFile"
            Remove-Item $oldPath -Force
            $removed++
        }
    }
}

# Save the new managed-file state for next time.
$newManaged = New-Object PSObject
foreach ($mod in $manifestJson.mods) {
    $newManaged | Add-Member -NotePropertyName $mod.filename -NotePropertyValue $true
}
$newManaged | ConvertTo-Json | Set-Content $stateFile

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
Write-Host "Up to date: $upToDate"
Write-Host "Downloaded: $downloaded"
Write-Host "Removed:    $removed"
if ($failed.Count -gt 0) {
    Write-Host "Needs attention: $($failed -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "Your mods folder matches the server. You're good to connect!" -ForegroundColor Green
}
