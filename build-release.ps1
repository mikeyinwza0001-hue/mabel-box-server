# ═══════════════════════════════════════════════════════
# Mabel Bedrock Box — Release Packaging Script
# ═══════════════════════════════════════════════════════
# Usage: .\build-release.ps1
# Creates a clean zip for distribution (no sensitive data)

param(
    [string]$OutputDir = ".\release"
)

$ErrorActionPreference = "Stop"

# Read version
$versionFile = Get-Content ".\server-version.json" | ConvertFrom-Json
$version = $versionFile.version
$zipName = "mabel-box-server-v$version.zip"

Write-Host "=== Building release v$version ===" -ForegroundColor Cyan

# Clean output dir
if (Test-Path $OutputDir) { Remove-Item $OutputDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDir | Out-Null

$tempDir = "$OutputDir\mabel-server"
New-Item -ItemType Directory -Path $tempDir | Out-Null

# ─── Files/Folders to EXCLUDE from release ────────────
$excludeFiles = @(
    "ops.json",
    "whitelist.json",
    "banned-players.json",
    "banned-ips.json",
    "usercache.json",
    "server.properties",
    ".console_history",
    "build-release.ps1",
    ".gitignore",
    ".gitattributes",
    "skills-lock.json"
)

$excludeDirs = @(
    ".git",
    ".vscode",
    ".agents",
    ".windsurf",
    "backup dont push",
    "logs",
    "cache",
    "versions",
    "libraries",
    "release",
    "plugins\.paper-remapped",
    "plugins\bStats",
    "plugins\spark"
)

# ─── Copy everything first ────────────────────────────
Write-Host "Copying server files..." -ForegroundColor Yellow

$allItems = Get-ChildItem -Path "." -Force
foreach ($item in $allItems) {
    $name = $item.Name
    $skip = $false

    # Skip excluded files
    if ($excludeFiles -contains $name) { $skip = $true }

    # Skip excluded directories
    foreach ($dir in $excludeDirs) {
        if ($name -eq $dir -or $name -eq $dir.Split("\")[-1]) { $skip = $true; break }
    }

    if (-not $skip) {
        if ($item.PSIsContainer) {
            Copy-Item -Path $item.FullName -Destination "$tempDir\$name" -Recurse -Force
        } else {
            Copy-Item -Path $item.FullName -Destination "$tempDir\$name" -Force
        }
    }
}

# ─── Remove sensitive plugin files ────────────────────
$sensitivePluginFiles = @(
    "$tempDir\plugins\MabelBedrock\config.yml"
)
foreach ($f in $sensitivePluginFiles) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# ─── Strip cache/runtime folders inside plugins ───────
# Top-level $excludeDirs only checks the root, so nested excludes like
# "plugins\.paper-remapped" never match in the copy loop. Clean them here.
$nestedExcludeDirs = @(
    "$tempDir\plugins\.paper-remapped",
    "$tempDir\plugins\bStats",
    "$tempDir\plugins\spark"
)
foreach ($d in $nestedExcludeDirs) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
}

# ─── Keep only the newest MabelBedrock-*.jar in plugins/ ──
# Avoid shipping stale plugin jars (e.g. an older MabelBedrock-2.5.x.jar that
# the user forgot to delete locally).
$mbbJars = Get-ChildItem -LiteralPath "$tempDir\plugins" -Filter "MabelBedrock-*.jar" -File -ErrorAction SilentlyContinue
if ($mbbJars -and $mbbJars.Count -gt 1) {
    $sorted = $mbbJars | Sort-Object {
        if ($_.Name -match 'MabelBedrock-(\d+)\.(\d+)\.(\d+)\.jar') {
            [int]$matches[1] * 1000000 + [int]$matches[2] * 1000 + [int]$matches[3]
        } else { 0 }
    } -Descending
    $keep = $sorted[0].Name
    foreach ($j in $sorted | Select-Object -Skip 1) {
        Write-Host "  - dropping stale plugin: $($j.Name)" -ForegroundColor DarkYellow
        Remove-Item $j.FullName -Force
    }
    Write-Host "  - keeping plugin: $keep" -ForegroundColor DarkGreen
}

# ─── Copy template as server.properties ───────────────
if (Test-Path ".\server.properties.template") {
    Copy-Item ".\server.properties.template" "$tempDir\server.properties" -Force
}

# ─── Create empty required files ──────────────────────
"[]" | Set-Content "$tempDir\ops.json"
"[]" | Set-Content "$tempDir\whitelist.json"
"[]" | Set-Content "$tempDir\banned-players.json"
"[]" | Set-Content "$tempDir\banned-ips.json"

# ─── Create zip ───────────────────────────────────────
# NOTE: We intentionally do NOT use Compress-Archive — it stores entries with
# backslash path separators, which Expand-Archive on the client side then
# mis-handles (jar files get silently dropped when a sibling directory with the
# same prefix also exists). Use .NET's ZipFile.CreateFromDirectory instead,
# which writes spec-compliant forward-slash entries.
Write-Host "Creating $zipName..." -ForegroundColor Yellow
$zipPath = "$OutputDir\$zipName"
$absZipPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $zipPath))
$absTempDir = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $tempDir))
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $absZipPath) { Remove-Item $absZipPath -Force }

# Manually build the archive so entry names are guaranteed to use '/' (per zip
# spec). Some .NET Framework versions still write '\' in CreateFromDirectory,
# which breaks Expand-Archive on the client (silently drops files when a
# sibling directory exists).
$fs = [System.IO.File]::Open($absZipPath, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $baseLen = $absTempDir.Length
        if (-not $absTempDir.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $baseLen++ }

        Get-ChildItem -LiteralPath $absTempDir -Recurse -Force | ForEach-Object {
            $rel = $_.FullName.Substring($baseLen).Replace('\', '/')
            if ($_.PSIsContainer) {
                # Directory entry (trailing slash, no content)
                [void]$archive.CreateEntry($rel + '/')
            } else {
                $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $fileStream = [System.IO.File]::OpenRead($_.FullName)
                    try { $fileStream.CopyTo($entryStream) } finally { $fileStream.Dispose() }
                } finally { $entryStream.Dispose() }
            }
        }
    } finally { $archive.Dispose() }
} finally { $fs.Dispose() }

# Cleanup temp
Remove-Item $tempDir -Recurse -Force

$size = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
Write-Host ""
Write-Host "=== Release built! ===" -ForegroundColor Green
Write-Host "  File: $zipPath" -ForegroundColor White
Write-Host "  Size: ${size} MB" -ForegroundColor White
Write-Host "  Version: $version" -ForegroundColor White
Write-Host ""
Write-Host "Next: Upload $zipName to GitHub Releases" -ForegroundColor Cyan
