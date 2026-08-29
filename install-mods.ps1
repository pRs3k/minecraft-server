#Requires -Version 5.1
<#
  Poke Server - client mod sync script

  Phase 1: downloads/updates whatever mods the server currently requires, based on
  mods-manifest.json hosted in the same GitHub repo. Only touches jars it manages,
  verified by SHA1 hash, and leaves any other mods you have installed alone.

  Phase 2: after syncing, checks whether any of your OTHER installed mods have a hard
  dependency (fabric.mod.json "depends") on one of the mods we just synced, and that
  dependency is no longer satisfied by the new version - i.e. something that would
  stop Minecraft from booting. Only in that case, it looks for and installs an updated
  build of the broken mod, after verifying the candidate actually declares
  compatibility. It never touches unrelated mods or updates things "just because a
  newer version exists."

  Run it with:
    irm https://raw.githubusercontent.com/pRs3k/minecraft-server/main/install-mods.ps1 | iex
#>

param(
    [string]$ManifestUrl = "https://raw.githubusercontent.com/pRs3k/minecraft-server/main/mods-manifest.json",
    [string]$MinecraftDir = $null,
    [string]$GameVersion = "1.21.1"
)

# Older Windows PowerShell defaults to TLS 1.0/1.1 on some systems, which GitHub
# and Modrinth's CDN reject. Force TLS 1.2 so downloads don't silently fail.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Finds .minecraft-style folders (ones with a "mods" subfolder or that look like a
# fresh vanilla install) across the launchers people actually use for modded play -
# the vanilla/official launcher, Prism Launcher, MultiMC, the CurseForge app, and the
# Modrinth App. Each third-party launcher keeps its own separate instance folders, so
# there's no single "the" Minecraft directory - this has to actually go looking.
function Find-MinecraftCandidates {
    $candidates = @()

    $vanilla = Join-Path $env:APPDATA ".minecraft"
    if (Test-Path $vanilla) { $candidates += $vanilla }

    $launcherInstanceRoots = @(
        (Join-Path $env:APPDATA "PrismLauncher\instances"),
        (Join-Path $env:APPDATA "MultiMC\instances"),
        (Join-Path $env:USERPROFILE "curseforge\minecraft\Instances"),
        (Join-Path $env:APPDATA "ModrinthApp\profiles")
    )

    foreach ($root in $launcherInstanceRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            # Prism/MultiMC nest an inner ".minecraft"; CurseForge and Modrinth App
            # use the instance folder itself.
            $inner = Join-Path $_.FullName ".minecraft"
            if (Test-Path (Join-Path $inner "mods")) {
                $candidates += $inner
            } elseif (Test-Path (Join-Path $_.FullName "mods")) {
                $candidates += $_.FullName
            }
        }
    }

    # The leading comma is required: without it, PowerShell silently collapses a
    # single-item array back to a plain string when it crosses a function's return
    # boundary - and then $result[0] on a string returns its first CHARACTER, not
    # the string itself. (Confirmed the hard way - this broke exactly this way for
    # anyone with only the vanilla launcher installed.)
    return ,@($candidates | Select-Object -Unique)
}

if (-not $MinecraftDir) {
    $candidates = Find-MinecraftCandidates
    if ($candidates.Count -eq 0) {
        $MinecraftDir = Join-Path $env:APPDATA ".minecraft"
        Write-Host "No existing Minecraft installs found - defaulting to $MinecraftDir" -ForegroundColor Yellow
    } elseif ($candidates.Count -eq 1) {
        $MinecraftDir = $candidates[0]
    } else {
        Write-Host "Found more than one Minecraft install on this computer:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "  [$($i + 1)] $($candidates[$i])"
        }
        $choice = Read-Host "Which one is for the Poke Server? Enter a number"
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $candidates.Count) {
            $MinecraftDir = $candidates[$index - 1]
        } else {
            Write-Host "Didn't recognize that choice. Re-run and try again, or run with -MinecraftDir '<path>' directly." -ForegroundColor Red
            exit 1
        }
    }
}

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Sha1($path) {
    return (Get-FileHash -Path $path -Algorithm SHA1).Hash.ToLower()
}

# Reads fabric.mod.json out of a jar (a jar is just a zip) without extracting it to
# disk. Returns $null for anything that isn't a normal Fabric mod jar.
function Get-FabricModInfo($jarPath) {
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
        try {
            $entry = $zip.GetEntry("fabric.mod.json")
            if (-not $entry) { return $null }
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try {
                $content = $reader.ReadToEnd()
            } finally {
                $reader.Close()
            }
            return $content | ConvertFrom-Json
        } finally {
            $zip.Dispose()
        }
    } catch {
        return $null
    }
}

# --- Fabric version range parsing (per the fabric.mod.json spec) ---
# Supports: =, >=, >, <=, <, ^a.b.c, ~a.b.c, x-ranges (1.2.x, 1.*), *, bare version
# (treated as exact match), space-separated predicates as AND, arrays as OR.

function ConvertTo-VersionParts($v) {
    $core = $v -replace '\+.*$', ''
    $prerelease = $null
    if ($core -match '^(.*?)-(.*)$') {
        $core = $matches[1]
        $prerelease = $matches[2]
    }
    $parts = @($core -split '\.' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_, [ref]$n)) { $n } else { $_ }
    })
    return @{ Parts = $parts; Prerelease = $prerelease }
}

function Compare-FabricVersion($v1, $v2) {
    $p1 = ConvertTo-VersionParts $v1
    $p2 = ConvertTo-VersionParts $v2
    $maxLen = [Math]::Max($p1.Parts.Count, $p2.Parts.Count)
    for ($i = 0; $i -lt $maxLen; $i++) {
        $a = if ($i -lt $p1.Parts.Count) { $p1.Parts[$i] } else { 0 }
        $b = if ($i -lt $p2.Parts.Count) { $p2.Parts[$i] } else { 0 }
        if ($a -is [int] -and $b -is [int]) {
            if ($a -ne $b) { return [Math]::Sign($a - $b) }
        } else {
            $cmp = [string]::Compare([string]$a, [string]$b, [StringComparison]::Ordinal)
            if ($cmp -ne 0) { return [Math]::Sign($cmp) }
        }
    }
    if (-not $p1.Prerelease -and $p2.Prerelease) { return 1 }
    if ($p1.Prerelease -and -not $p2.Prerelease) { return -1 }
    if ($p1.Prerelease -and $p2.Prerelease) {
        return [Math]::Sign([string]::Compare($p1.Prerelease, $p2.Prerelease, [StringComparison]::Ordinal))
    }
    return 0
}

function Test-SinglePredicate($version, $predicate) {
    $predicate = $predicate.Trim()
    if ($predicate -eq '*' -or $predicate -eq '') { return $true }

    if ($predicate -match '^\^(.+)$') {
        $base = $matches[1]
        $baseParts = (ConvertTo-VersionParts $base).Parts
        $major = if ($baseParts.Count -gt 0 -and $baseParts[0] -is [int]) { $baseParts[0] } else { 0 }
        $nextMajor = "$($major + 1).0.0"
        return ((Compare-FabricVersion $version $base) -ge 0) -and ((Compare-FabricVersion $version $nextMajor) -lt 0)
    }
    if ($predicate -match '^~(.+)$') {
        $base = $matches[1]
        $baseParts = (ConvertTo-VersionParts $base).Parts
        $major = if ($baseParts.Count -gt 0 -and $baseParts[0] -is [int]) { $baseParts[0] } else { 0 }
        $minor = if ($baseParts.Count -gt 1 -and $baseParts[1] -is [int]) { $baseParts[1] } else { 0 }
        $nextMinor = "$major.$($minor + 1).0"
        return ((Compare-FabricVersion $version $base) -ge 0) -and ((Compare-FabricVersion $version $nextMinor) -lt 0)
    }
    if ($predicate -match '^(>=|<=|>|<|=)(.+)$') {
        $op = $matches[1]
        $target = $matches[2].Trim()
        $cmp = Compare-FabricVersion $version $target
        switch ($op) {
            '>=' { return $cmp -ge 0 }
            '<=' { return $cmp -le 0 }
            '>'  { return $cmp -gt 0 }
            '<'  { return $cmp -lt 0 }
            '='  { return $cmp -eq 0 }
        }
    }
    if ($predicate -match '^([\d\.]*?)\.?[xX*]$') {
        $prefix = $matches[1].TrimEnd('.')
        if (-not $prefix) { return $true }
        return ($version -eq $prefix) -or ($version.StartsWith("$prefix."))
    }
    # Bare version with no operator - treat as exact match.
    return (Compare-FabricVersion $version $predicate) -eq 0
}

function Test-VersionSatisfiesRange($version, $rangeValue) {
    if ($null -eq $rangeValue) { return $true }
    if ($rangeValue -is [array]) {
        foreach ($alt in $rangeValue) {
            if (Test-VersionSatisfiesRange $version $alt) { return $true }
        }
        return $false
    }
    $predicates = @($rangeValue -split '\s+' | Where-Object { $_ -ne '' })
    foreach ($p in $predicates) {
        if (-not (Test-SinglePredicate $version $p)) { return $false }
    }
    return $true
}

# =============================== Phase 1: sync ===============================

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

$newManaged = New-Object PSObject
foreach ($mod in $manifestJson.mods) {
    $newManaged | Add-Member -NotePropertyName $mod.filename -NotePropertyValue $true
}
$newManaged | ConvertTo-Json | Set-Content $stateFile

Write-Host ""
Write-Host "=== Sync done ===" -ForegroundColor Cyan
Write-Host "Up to date: $upToDate"
Write-Host "Downloaded: $downloaded"
Write-Host "Removed:    $removed"
if ($failed.Count -gt 0) {
    Write-Host "Needs attention: $($failed -join ', ')" -ForegroundColor Yellow
}

# ===================== Phase 2: dependency conflict check =====================

Write-Host ""
Write-Host "=== Checking for mods broken by this update ===" -ForegroundColor Cyan

# Read fabric.mod.json out of every jar now in the folder so we know exactly what's
# actually installed (id + version), not just what the manifest says should be there.
$installedById = @{}
$jarInfoByFile = @{}
Get-ChildItem -Path $modsDir -Filter "*.jar" | ForEach-Object {
    $info = Get-FabricModInfo $_.FullName
    if ($info -and $info.id -and $info.version) {
        $installedById[$info.id] = @{ Version = $info.version; Filename = $_.Name }
        $jarInfoByFile[$_.Name] = $info
    }
}

# Which mod ids do we manage (i.e. mods that were just possibly updated by phase 1)?
$managedIds = @{}
foreach ($filename in $currentFilenames.Keys) {
    if ($jarInfoByFile.ContainsKey($filename)) {
        $managedIds[$jarInfoByFile[$filename].id] = $true
    }
}

$broken = @()
foreach ($filename in $jarInfoByFile.Keys) {
    if ($currentFilenames.ContainsKey($filename)) { continue } # skip our own managed mods
    $info = $jarInfoByFile[$filename]
    if (-not $info.depends) { continue }

    foreach ($depProp in $info.depends.PSObject.Properties) {
        $depId = $depProp.Name
        if ($depId -eq "minecraft" -or $depId -eq "fabricloader" -or $depId -eq "java") { continue }
        if (-not $managedIds.ContainsKey($depId)) { continue } # only care about deps on OUR mods

        $installedVersion = $installedById[$depId].Version
        if (-not (Test-VersionSatisfiesRange $installedVersion $depProp.Value)) {
            $broken += [PSCustomObject]@{
                ModId       = $info.id
                Filename    = $filename
                RequiresId  = $depId
                RequiresRange = ($depProp.Value -join ", ")
                InstalledDepVersion = $installedVersion
            }
        }
    }
}

if ($broken.Count -eq 0) {
    Write-Host "Nothing else on your system depends on the mods we just updated. All good." -ForegroundColor Green
} else {
    foreach ($b in $broken) {
        Write-Host ""
        Write-Host "  [BROKEN] $($b.Filename) requires $($b.RequiresId) $($b.RequiresRange), but $($b.InstalledDepVersion) is now installed." -ForegroundColor Yellow
        Write-Host "  Looking for an updated build of $($b.ModId) on Modrinth ..."

        $fixed = $false
        try {
            $project = Invoke-RestMethod -Uri "https://api.modrinth.com/v2/project/$($b.ModId)" -UseBasicParsing
        } catch {
            $project = $null
        }

        if ($project) {
            $versionsUrl = "https://api.modrinth.com/v2/project/$($project.id)/version?loaders=%5B%22fabric%22%5D&game_versions=%5B%22$GameVersion%22%5D"
            try {
                $candidates = Invoke-RestMethod -Uri $versionsUrl -UseBasicParsing
            } catch {
                $candidates = @()
            }

            foreach ($candidate in $candidates) {
                $file = $candidate.files | Where-Object { $_.primary } | Select-Object -First 1
                if (-not $file) { $file = $candidate.files | Select-Object -First 1 }
                if (-not $file) { continue }

                $tempPath = Join-Path $env:TEMP $file.filename
                try {
                    Invoke-WebRequest -Uri $file.url -OutFile $tempPath -UseBasicParsing
                    $candidateInfo = Get-FabricModInfo $tempPath
                    $requiredRange = $null
                    if ($candidateInfo -and $candidateInfo.depends) {
                        $depProp = $candidateInfo.depends.PSObject.Properties | Where-Object { $_.Name -eq $b.RequiresId }
                        if ($depProp) { $requiredRange = $depProp.Value }
                    }

                    $nowInstalledVersion = $installedById[$b.RequiresId].Version
                    if ($null -eq $requiredRange -or (Test-VersionSatisfiesRange $nowInstalledVersion $requiredRange)) {
                        $oldPath = Join-Path $modsDir $b.Filename
                        if (Test-Path $oldPath) { Remove-Item $oldPath -Force }
                        $destPath = Join-Path $modsDir $file.filename
                        Move-Item $tempPath $destPath -Force
                        Write-Host "  [FIXED] Updated $($b.ModId) to $($candidate.version_number), which supports the new $($b.RequiresId)." -ForegroundColor Green
                        $fixed = $true
                        break
                    } else {
                        Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                    }
                } catch {
                    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $fixed) {
            Write-Host "  Could not find a compatible update automatically. Check manually:" -ForegroundColor Red
            Write-Host "  https://modrinth.com/mod/$($b.ModId)/versions" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
if ($failed.Count -eq 0 -and $broken.Count -eq 0) {
    Write-Host "Your mods folder matches the server and nothing else was broken. You're good to connect!" -ForegroundColor Green
}
