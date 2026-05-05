$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ReleaseRepo = if ($env:INSPECTOR_RELEASE_REPO) { $env:INSPECTOR_RELEASE_REPO } else { "inspectorai/inspector-releases" }
$QuietInstall = $env:INSPECTOR_INSTALL_QUIET -eq "1"

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

function Invoke-GitHubApi {
    param([string]$Uri)

    return Invoke-RestMethod `
        -UseBasicParsing `
        -Uri $Uri `
        -Headers @{
            "Accept" = "application/vnd.github+json"
            "User-Agent" = "inspector-installer"
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

function Find-ReleaseAsset {
    param(
        $Release,
        [string]$AssetName
    )

    foreach ($Asset in $Release.assets) {
        if ((Get-ObjectPropertyValue -Object $Asset -Name "name") -eq $AssetName) {
            return $Asset
        }
    }

    return $null
}

function Get-ChecksumFromAssetDigest {
    param($Asset)

    $Digest = Get-ObjectPropertyValue -Object $Asset -Name "digest"
    if ($Digest -and $Digest -match "^sha256:([0-9a-fA-F]{64})$") {
        return $Matches[1].ToLowerInvariant()
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

function Install-Msi {
    param(
        [string]$InstallerPath,
        [bool]$Quiet
    )

    $LogPath = Join-Path ([IO.Path]::GetTempPath()) ("inspector-msi-install-" + [guid]::NewGuid().ToString("N") + ".log")
    $DisplayArg = if ($Quiet) { "/quiet" } else { "/passive" }
    $ArgumentList = @(
        "/i",
        "`"$InstallerPath`"",
        $DisplayArg,
        "/norestart",
        "/L*v",
        "`"$LogPath`""
    )

    Write-Host "Starting Windows Installer..."
    $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $ArgumentList -Wait -PassThru

    if ($Process.ExitCode -eq 0) {
        Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
        return
    }

    if ($Process.ExitCode -eq 3010) {
        Remove-Item -LiteralPath $LogPath -Force -ErrorAction SilentlyContinue
        Write-Host "Inspector installed successfully. Windows reports a restart is required."
        return
    }

    throw "MSI installation failed with exit code $($Process.ExitCode). Log: $LogPath"
}

$Repo = Normalize-Repo $ReleaseRepo
$Target = Get-TargetTriple
$ReleaseApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
$AssetName = "inspector-cli-$Target.msi"
$TempDir = Join-Path ([IO.Path]::GetTempPath()) ("inspector-install-" + [guid]::NewGuid().ToString("N"))
$InstallerPath = Join-Path $TempDir $AssetName

try {
    Write-Host "Fetching latest Inspector release metadata..."
    $Release = Invoke-GitHubApi -Uri $ReleaseApiUrl
    $Tag = Get-ObjectPropertyValue -Object $Release -Name "tag_name"
    if (-not $Tag) {
        throw "Latest release metadata is missing tag_name."
    }

    $Asset = Find-ReleaseAsset -Release $Release -AssetName $AssetName
    if (-not $Asset) {
        throw "Latest release does not publish $AssetName yet."
    }

    $DownloadUrl = Get-ObjectPropertyValue -Object $Asset -Name "browser_download_url"
    if (-not $DownloadUrl) {
        $DownloadUrl = "https://github.com/$Repo/releases/download/$Tag/$AssetName"
    }

    Write-Host "Resolving checksum for $AssetName..."
    $ExpectedSha = Get-ChecksumFromAssetDigest -Asset $Asset
    if (-not $ExpectedSha) {
        $ChecksumsUrl = "https://github.com/$Repo/releases/download/$Tag/SHA256SUMS.txt"
        $ExpectedSha = Get-ChecksumFromSumsFile -ChecksumsUrl $ChecksumsUrl -AssetName $AssetName
    }
    if (-not $ExpectedSha) {
        throw "Latest release does not publish a SHA256 checksum for $AssetName."
    }

    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    Write-Host "Downloading $AssetName..."
    Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl -OutFile $InstallerPath

    $ActualSha = (Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha.ToLowerInvariant()) {
        throw "Checksum mismatch for $AssetName. Expected $ExpectedSha, got $ActualSha."
    }

    Install-Msi -InstallerPath $InstallerPath -Quiet $QuietInstall

    Write-Host ""
    Write-Host "Inspector installed successfully."
    Write-Host "Open a new shell before running 'inspector' if the installer updated PATH."
} finally {
    Remove-ExistingPath -Path $TempDir
}
