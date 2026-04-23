$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ReleaseRepo = if ($env:INSPECTOR_RELEASE_REPO) { $env:INSPECTOR_RELEASE_REPO } else { "inspectorai/inspector-releases" }
$InstallRoot = if ($env:INSPECTOR_INSTALL_ROOT) { $env:INSPECTOR_INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA "Inspector" }
$BinDir = if ($env:INSPECTOR_BIN_DIR) { $env:INSPECTOR_BIN_DIR } else { Join-Path $InstallRoot "bin" }
$ConfigHome = if ($env:INSPECTOR_CONFIG_HOME) { $env:INSPECTOR_CONFIG_HOME } else { Join-Path $env:USERPROFILE ".inspector" }
$ForceConfig = $env:INSPECTOR_INSTALL_FORCE_CONFIG -eq "1"

function Normalize-Repo {
    param([string]$Value)

    $Repo = $Value.Trim()
    foreach ($Prefix in @("https://github.com/", "http://github.com/", "github.com/")) {
        if ($Repo.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $Repo = $Repo.Substring($Prefix.Length)
        }
    }
    return $Repo.TrimEnd("/")
}

function Get-TargetTriple {
    $Arch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($Arch.ToUpperInvariant()) {
        "AMD64" { return "x86_64-pc-windows-msvc" }
        default { throw "Inspector installer currently supports Windows x86_64 only." }
    }
}

function Get-Manifest {
    param([string]$ManifestUrl)

    $Response = Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl
    return $Response.Content | ConvertFrom-Json
}

function Get-ManifestSha256 {
    param(
        $Manifest,
        [string]$AssetName
    )

    if (-not $Manifest.assets) {
        return $null
    }

    foreach ($Asset in $Manifest.assets) {
        if ($Asset.name -eq $AssetName -and $Asset.sha256) {
            return [string]$Asset.sha256
        }
    }

    return $null
}

function Get-ChecksumFromSumsFile {
    param(
        [string]$ChecksumsUrl,
        [string]$AssetName
    )

    $Content = Invoke-WebRequest -UseBasicParsing -Uri $ChecksumsUrl | Select-Object -ExpandProperty Content
    foreach ($Line in ($Content -split "`r?`n")) {
        if ($Line -match "^([0-9a-fA-F]+)\s+\*?(.+)$" -and $Matches[2] -eq $AssetName) {
            return $Matches[1].ToLowerInvariant()
        }
    }

    return $null
}

function Remove-ExistingPath {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $Item = Get-Item -LiteralPath $Path -Force
    $IsReparsePoint = ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    if ($IsReparsePoint) {
        Remove-Item -LiteralPath $Path -Force
        return
    }

    if ($Item.PSIsContainer) {
        Remove-Item -LiteralPath $Path -Recurse -Force
        return
    }

    Remove-Item -LiteralPath $Path -Force
}

function Ensure-UserPathContains {
    param([string]$PathEntry)

    $ExistingUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $Entries = @()
    if ($ExistingUserPath) {
        $Entries = $ExistingUserPath.Split(";") | Where-Object { $_.Trim() -ne "" }
    }

    foreach ($Existing in $Entries) {
        if ([string]::Equals(
            [IO.Path]::GetFullPath($Existing),
            [IO.Path]::GetFullPath($PathEntry),
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            if (-not ($env:Path.Split(";") | Where-Object { $_.Trim() -ne "" } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Where-Object {
                [string]::Equals($_, [IO.Path]::GetFullPath($PathEntry), [System.StringComparison]::OrdinalIgnoreCase)
            })) {
                $env:Path = "$PathEntry;$env:Path"
            }
            return $false
        }
    }

    $NewUserPath = if ($ExistingUserPath) {
        "$ExistingUserPath;$PathEntry"
    } else {
        $PathEntry
    }
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    $env:Path = "$PathEntry;$env:Path"
    return $true
}

function Write-InspectorShim {
    param(
        [string]$DestinationPath
    )

    $Shim = @"
@echo off
"%~dp0..\current\bin\inspector.exe" %*
"@

    Set-Content -LiteralPath $DestinationPath -Value $Shim -Encoding ASCII
}

$Repo = Normalize-Repo $ReleaseRepo
$Target = Get-TargetTriple
$ManifestUrl = "https://github.com/$Repo/releases/latest/download/release-manifest.json"

Write-Host "Fetching latest Inspector release metadata..."
$Manifest = Get-Manifest -ManifestUrl $ManifestUrl
$Version = [string]$Manifest.version
$Tag = [string]$Manifest.tag

if (-not $Version -or -not $Tag) {
    throw "Release manifest is missing version or tag."
}

$AssetName = "inspector-bundle-$Version-$Target.zip"
$DownloadUrl = "https://github.com/$Repo/releases/download/$Tag/$AssetName"
$ChecksumsUrl = "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt"

Write-Host "Resolving checksum for $AssetName..."
$ExpectedSha = Get-ManifestSha256 -Manifest $Manifest -AssetName $AssetName
if (-not $ExpectedSha) {
    $ExpectedSha = Get-ChecksumFromSumsFile -ChecksumsUrl $ChecksumsUrl -AssetName $AssetName
}
if (-not $ExpectedSha) {
    throw "Latest release does not publish $AssetName yet."
}

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("inspector-install-" + [guid]::NewGuid().ToString("N"))
$ArchivePath = Join-Path $TempDir $AssetName
$ExtractRoot = Join-Path $TempDir "extract"
$ReleaseRoot = Join-Path $InstallRoot "releases"
$ReleaseDir = Join-Path $ReleaseRoot $Version
$CurrentDir = Join-Path $InstallRoot "current"
$InstalledConfig = Join-Path $ConfigHome "config.toml"
$ShimPath = Join-Path $BinDir "inspector.cmd"

New-Item -ItemType Directory -Path $TempDir, $ExtractRoot, $ReleaseRoot, $BinDir, $ConfigHome -Force | Out-Null

try {
    Write-Host "Downloading $AssetName..."
    Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $ArchivePath

    $ActualSha = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha.ToLowerInvariant()) {
        throw "Checksum mismatch for $AssetName. Expected $ExpectedSha, got $ActualSha."
    }

    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force

    $BundleRoot = Join-Path $ExtractRoot ("inspector-bundle-$Version-$Target")
    if (-not (Test-Path -LiteralPath (Join-Path $BundleRoot "bundle.json"))) {
        throw "Downloaded archive does not contain a valid Inspector bundle."
    }

    Remove-ExistingPath -Path $ReleaseDir
    Move-Item -LiteralPath $BundleRoot -Destination $ReleaseDir

    Remove-ExistingPath -Path $CurrentDir
    New-Item -ItemType Junction -Path $CurrentDir -Target $ReleaseDir | Out-Null

    Write-InspectorShim -DestinationPath $ShimPath

    $BundleConfig = Join-Path $ReleaseDir "config\config.toml"
    if (Test-Path -LiteralPath $BundleConfig) {
        if (-not (Test-Path -LiteralPath $InstalledConfig) -or $ForceConfig) {
            Copy-Item -LiteralPath $BundleConfig -Destination $InstalledConfig -Force
            Write-Host "Installed Inspector config: $InstalledConfig"
        } else {
            Write-Host "Keeping existing Inspector config: $InstalledConfig"
            Write-Host "Set INSPECTOR_INSTALL_FORCE_CONFIG=1 to replace it."
        }
    }

    $PathUpdated = Ensure-UserPathContains -PathEntry $BinDir

    Write-Host ""
    Write-Host "Inspector $Version installed successfully."
    Write-Host "Launcher: $ShimPath"
    Write-Host "Bundle:   $ReleaseDir"

    if ($PathUpdated) {
        Write-Host ""
        Write-Host "Added $BinDir to your user PATH."
        Write-Host "Open a new shell to run 'inspector'."
    } elseif ($env:Path -notmatch [regex]::Escape($BinDir)) {
        Write-Host ""
        Write-Host "Open a new shell to run 'inspector'."
    }
} finally {
    Remove-ExistingPath -Path $TempDir
}
