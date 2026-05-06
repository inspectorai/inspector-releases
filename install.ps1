$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ReleaseRepo = if ($env:INSPECTOR_RELEASE_REPO) { $env:INSPECTOR_RELEASE_REPO } else { "inspectorai/inspector-releases" }
$InstallRoot = if ($env:INSPECTOR_INSTALL_ROOT) { $env:INSPECTOR_INSTALL_ROOT } else { Join-Path $env:LOCALAPPDATA "Inspector" }
$BinDir = if ($env:INSPECTOR_BIN_DIR) { $env:INSPECTOR_BIN_DIR } else { Join-Path $InstallRoot "bin" }
$ConfigHome = if ($env:INSPECTOR_CONFIG_HOME) { $env:INSPECTOR_CONFIG_HOME } else { Join-Path $env:USERPROFILE ".inspector" }
$ForceConfig = if ($env:INSPECTOR_INSTALL_FORCE_CONFIG) { $env:INSPECTOR_INSTALL_FORCE_CONFIG } else { "1" }

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

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name
    )

    $Property = $Object.PSObject.Properties[$Name]
    if ($Property -and $null -ne $Property.Value) {
        return [string]$Property.Value
    }

    return $null
}

function Find-ManifestAsset {
    param(
        $Manifest,
        [string]$Target
    )

    foreach ($Asset in $Manifest.assets) {
        if ((Get-ObjectPropertyValue -Object $Asset -Name "target") -eq $Target) {
            return $Asset
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

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Add-UserPathEntry {
    param([string]$Path)

    $NormalizedPath = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $CurrentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $Entries = @()
    if ($CurrentUserPath) {
        $Entries = $CurrentUserPath -split ";" | Where-Object { $_ }
    }

    foreach ($Entry in $Entries) {
        if ([IO.Path]::GetFullPath($Entry).TrimEnd("\").Equals($NormalizedPath, [StringComparison]::OrdinalIgnoreCase)) {
            $env:Path = "$NormalizedPath;$env:Path"
            return
        }
    }

    $NewUserPath = if ($CurrentUserPath) { "$CurrentUserPath;$NormalizedPath" } else { $NormalizedPath }
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    $env:Path = "$NormalizedPath;$env:Path"
    Write-Host "Added Inspector to user PATH: $NormalizedPath"
}

function Write-InspectorShim {
    param(
        [string]$BinDir,
        [string]$InspectorExe
    )

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $ShimPath = Join-Path $BinDir "inspector.cmd"
    $Shim = @"
@echo off
"$InspectorExe" %*
"@
    Set-Content -LiteralPath $ShimPath -Value $Shim -Encoding ASCII
    return $ShimPath
}

function Write-ProductionConfig {
    param(
        [string]$ConfigHome,
        [string]$BundleConfigPath,
        [string]$ForceConfig
    )

    $ConfigPath = Join-Path $ConfigHome "config.toml"
    New-Item -ItemType Directory -Path $ConfigHome -Force | Out-Null

    if ((Test-Path -LiteralPath $ConfigPath) -and $ForceConfig -ne "1") {
        Write-Host "Keeping existing Inspector config: $ConfigPath"
        Write-Host "Set INSPECTOR_INSTALL_FORCE_CONFIG=1 to replace it."
        return
    }

    if (Test-Path -LiteralPath $BundleConfigPath) {
        Copy-Item -LiteralPath $BundleConfigPath -Destination $ConfigPath -Force
    } else {
        $Config = @'
inspector_base_url = "https://api.dev.inspectorai.pro/api"
inspector_frontend_base_url = "https://dev.inspectorai.pro"
inspector_auth_base_url = "https://auth.dev.inspectorai.pro/hydra"
ai_local_ws_sso_url = "ws://127.0.0.1:8000/ws/sso"
ai_runtime_ws_url = "wss://api.dev.inspectorai.pro/api/ai/runtime/ws"
inspector_sso_fallback = true
inspector_sso_force_old = false
inspector_sso_force_new = false
inspector_sso_timeout_secs = 300
'@
        Set-Content -LiteralPath $ConfigPath -Value $Config -Encoding ASCII
    }

    Write-Host "Installed Inspector config: $ConfigPath"
}

$Repo = Normalize-Repo $ReleaseRepo
$Target = Get-TargetTriple
$ManifestUrl = "https://github.com/$Repo/releases/latest/download/release-manifest.json"
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("inspector-install-" + [guid]::NewGuid().ToString("N"))

try {
    Write-Host "Fetching latest Inspector release metadata..."
    $Manifest = Invoke-RestMethod -UseBasicParsing -Uri $ManifestUrl
    $Version = Get-ObjectPropertyValue -Object $Manifest -Name "version"
    $Tag = Get-ObjectPropertyValue -Object $Manifest -Name "tag"
    if (-not $Version -or -not $Tag) {
        throw "Release manifest is missing version or tag."
    }

    $Asset = Find-ManifestAsset -Manifest $Manifest -Target $Target
    if (-not $Asset) {
        throw "Latest release does not publish an Inspector bundle for $Target yet."
    }

    $AssetName = Get-ObjectPropertyValue -Object $Asset -Name "name"
    $DownloadUrl = Get-ObjectPropertyValue -Object $Asset -Name "url"
    $ExpectedSha = Get-ObjectPropertyValue -Object $Asset -Name "sha256"
    if (-not $AssetName -or -not $DownloadUrl) {
        throw "Release manifest asset for $Target is missing name or url."
    }
    if (-not $ExpectedSha) {
        $ChecksumsUrl = "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt"
        $ExpectedSha = Get-ChecksumFromSumsFile -ChecksumsUrl $ChecksumsUrl -AssetName $AssetName
    }
    if (-not $ExpectedSha) {
        throw "Latest release does not publish a SHA256 checksum for $AssetName."
    }

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
    $ArchivePath = Join-Path $TempDir $AssetName
    $ExtractRoot = Join-Path $TempDir "extract"

    Write-Host "Downloading $AssetName..."
    Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $ArchivePath

    $ActualSha = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha.ToLowerInvariant()) {
        throw "Checksum mismatch for $AssetName. Expected $ExpectedSha, got $ActualSha."
    }

    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force

    $BundleRoot = Join-Path $ExtractRoot "inspector-bundle-$Version-$Target"
    $BundleJson = Join-Path $BundleRoot "bundle.json"
    if (-not (Test-Path -LiteralPath $BundleJson)) {
        throw "Downloaded archive does not contain a valid Inspector bundle."
    }

    $ReleasesDir = Join-Path $InstallRoot "releases"
    $ReleaseDir = Join-Path $ReleasesDir $Version
    New-Item -ItemType Directory -Path $ReleasesDir -Force | Out-Null
    Remove-ExistingPath -Path $ReleaseDir
    Move-Item -LiteralPath $BundleRoot -Destination $ReleaseDir

    $InspectorExe = Join-Path $ReleaseDir "bin\inspector.exe"
    $AiLocalExe = Join-Path $ReleaseDir "runtime\ai_local\inspector-ai-local.exe"
    if (-not (Test-Path -LiteralPath $InspectorExe)) {
        throw "Installed bundle is missing $InspectorExe."
    }
    if (-not (Test-Path -LiteralPath $AiLocalExe)) {
        throw "Installed bundle is missing $AiLocalExe."
    }

    $ShimPath = Write-InspectorShim -BinDir $BinDir -InspectorExe $InspectorExe
    Add-UserPathEntry -Path $BinDir
    Write-ProductionConfig -ConfigHome $ConfigHome -BundleConfigPath (Join-Path $ReleaseDir "config\config.toml") -ForceConfig $ForceConfig

    Write-Host ""
    Write-Host "Inspector $Version installed successfully."
    Write-Host "Binary: $ShimPath"
    Write-Host "Bundle: $ReleaseDir"
    Write-Host "Open a new shell before running 'inspector' if this is your first install."
} finally {
    Remove-ExistingPath -Path $TempDir
}
