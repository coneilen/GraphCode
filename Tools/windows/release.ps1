<#
.SYNOPSIS
  Builds and optionally publishes the Windows release artifact.

.DESCRIPTION
  This is the single decision point between Tools/windows/package.ps1 and a
  GitHub release asset. It resolves a release tag to a package version, builds
  and verifies the standard unsigned Windows package, and optionally attaches it
  to an existing release.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $Tag,
  [string] $OutputDirectory,
  [string] $WinghosttyRoot = $env:GRAPHCODE_WINGHOSTTY_ROOT,
  [string] $ZmxRoot = $env:GRAPHCODE_ZMX_ROOT,
  [string] $Zig0152 = $env:GRAPHCODE_ZIG0152,
  [string] $Zig0160 = $env:GRAPHCODE_ZIG0160,
  [string] $PackageScript,
  [string] $GitHubCli = "gh",
  [string] $GitCli = "git",
  [switch] $AllowTagMismatch,
  [switch] $Publish
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
if (-not $PackageScript) { $PackageScript = Join-Path $repoRoot "Tools\windows\package.ps1" }
if (-not (Test-Path -LiteralPath $PackageScript -PathType Leaf)) {
  throw "packaging script was not found: $PackageScript"
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot ".build\windows\release-publish" }

function Resolve-ReleaseVersion([string] $tag) {
  $candidate = $tag.Trim()
  if ($candidate -notmatch "^v?([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.]*)?)$") {
    throw "release tag does not name a publishable version: '$tag'"
  }
  $version = $Matches[1]
  if ($version -in @("0.0.0-dev") -or $version -match "(?i)(^|[-.])dev([-.]|$)") {
    throw "release tag does not name a publishable version: '$tag'"
  }
  return $version
}

function Invoke-Packaging([string[]] $arguments, [string] $activity) {
  & pwsh -NoProfile -File $PackageScript @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Windows packaging ($activity) failed with exit code $LASTEXITCODE"
  }
}

function Resolve-GitCommit([string] $revision, [string] $description) {
  $output = & $GitCli -C $repoRoot rev-parse --verify $revision 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "could not resolve $description '$revision'"
  }
  $commit = [string] (@($output) | Select-Object -Last 1)
  $commit = $commit.Trim().ToLowerInvariant()
  if ($commit -notmatch "^[0-9a-f]{40}$") {
    throw "$description '$revision' resolved to invalid commit '$commit'"
  }
  return $commit
}

$version = Resolve-ReleaseVersion $Tag
if ($AllowTagMismatch -and $Publish) {
  throw "-AllowTagMismatch cannot be combined with -Publish"
}
$tagCommit = Resolve-GitCommit "$Tag^{commit}" "release tag"
$sourceCommit = Resolve-GitCommit "HEAD" "source revision"
$tagMatchesSource = $tagCommit -eq $sourceCommit
if (-not $tagMatchesSource -and -not $AllowTagMismatch) {
  throw "release tag '$Tag' peels to $tagCommit but HEAD is $sourceCommit; use -AllowTagMismatch only for unpublished local packaging"
}
if ($AllowTagMismatch) {
  Write-Warning "Packaging unverified source provenance: tag '$Tag' peels to $tagCommit but HEAD is $sourceCommit"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$packages = Join-Path $OutputDirectory "packages"
$publishDirectory = Join-Path $OutputDirectory "publish"
if (Test-Path -LiteralPath $publishDirectory) {
  Remove-Item -LiteralPath $publishDirectory -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $packages, $publishDirectory | Out-Null

$buildArguments = @(
  "-Command", "Build",
  "-OutputDirectory", $packages,
  "-Version", $version,
  "-ReleaseTag", $Tag,
  "-ReleaseTagCommit", $tagCommit,
  "-SourceCommit", $sourceCommit,
  "-ReleaseTagMatchesSource", $tagMatchesSource.ToString().ToLowerInvariant(),
  "-TagMismatchAllowed", $AllowTagMismatch.ToString().ToLowerInvariant()
)
foreach ($pair in @(
    @{ name = "WinghosttyRoot"; value = $WinghosttyRoot },
    @{ name = "ZmxRoot"; value = $ZmxRoot },
    @{ name = "Zig0152"; value = $Zig0152 },
    @{ name = "Zig0160"; value = $Zig0160 })) {
  if ($pair.value) { $buildArguments += @("-$($pair.name)", $pair.value) }
}
Invoke-Packaging $buildArguments "build"

$packageName = "GraphCode-$version-windows-x86_64"
$archive = Join-Path $packages "$packageName.zip"
$packageRoot = Join-Path $packages $packageName
foreach ($produced in @($archive, $packageRoot)) {
  if (-not (Test-Path -LiteralPath $produced)) {
    throw "Windows packaging did not produce $produced"
  }
}

# Release publishing intentionally produces the ordinary unsigned package.
# Keep the package's own declaration visible and reject an unexpected state.
$metadata = Get-Content -LiteralPath (Join-Path $packageRoot "metadata.json") -Raw | ConvertFrom-Json
$reported = [string] $metadata.signing
if (-not $reported.StartsWith("UNSIGNED")) {
  throw "package signing state '$reported' contradicts the unsigned Windows release policy"
}
if ([string] $metadata.version -ne $version) {
  throw "package reports version '$($metadata.version)', expected '$version'"
}
$packageProvenance = $metadata.sourceProvenance
if (-not $packageProvenance -or
    [string] $packageProvenance.tag -ne $Tag -or
    [string] $packageProvenance.tagCommit -ne $tagCommit -or
    [string] $packageProvenance.sourceCommit -ne $sourceCommit -or
    [bool] $packageProvenance.tagMatchesSource -ne $tagMatchesSource -or
    [bool] $packageProvenance.tagMismatchAllowed -ne [bool] $AllowTagMismatch) {
  throw "package source provenance contradicts the release inputs"
}

$verifyArguments = @("-Command", "Verify", "-Package", $archive)
Invoke-Packaging $verifyArguments "verification"

# The versionless name mirrors the macOS DMG and keeps
# releases/latest/download stable.
$assetName = "graphcode-windows-x86_64.zip"
$asset = Join-Path $publishDirectory $assetName
Copy-Item -LiteralPath $archive -Destination $asset -Force
$assetHash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
$checksum = "$asset.sha256"
Set-Content -LiteralPath $checksum -Value "$assetHash  $assetName" -Encoding ascii
Copy-Item -LiteralPath (Join-Path $packageRoot "metadata.json") `
  -Destination (Join-Path $publishDirectory "metadata.json") -Force

$published = $false
if ($Publish) {
  & $GitHubCli release upload $Tag $asset $checksum --clobber
  if ($LASTEXITCODE -ne 0) {
    throw "release asset upload failed with exit code $LASTEXITCODE"
  }
  $published = $true
}

$summary = [ordered]@{
  schemaVersion = 1
  tag = $Tag
  version = $version
  signed = $false
  signing = $reported
  asset = $assetName
  sha256 = $assetHash
  published = $published
  sourceProvenance = [ordered]@{
    tag = $Tag
    tagCommit = $tagCommit
    sourceCommit = $sourceCommit
    tagMatchesSource = $tagMatchesSource
    tagMismatchAllowed = [bool] $AllowTagMismatch
  }
}
$summary | ConvertTo-Json -Depth 5 |
  Set-Content -LiteralPath (Join-Path $publishDirectory "release-summary.json") -Encoding utf8

Write-Host "GraphCode $version for Windows: $reported"
Write-Host "Asset: $asset"
Write-Host "SHA-256: $assetHash"
Write-Host "Source commit: $sourceCommit"
Write-Host "Tag commit: $tagCommit"
Write-Host "Tag matches source: $tagMatchesSource"
Write-Host "Tag mismatch allowed: $([bool] $AllowTagMismatch)"
Write-Host "Published to $Tag`: $published"
if ($env:GITHUB_STEP_SUMMARY) {
  @(
    "### GraphCode Windows $version",
    "",
    "| Field | Value |",
    "| --- | --- |",
    "| Tag | ``$Tag`` |",
    "| Signing | ``$reported`` |",
    "| Asset | ``$assetName`` |",
    "| SHA-256 | ``$assetHash`` |",
    "| Source commit | ``$sourceCommit`` |",
    "| Tag commit | ``$tagCommit`` |",
    "| Tag matches source | ``$tagMatchesSource`` |",
    "| Tag mismatch allowed | ``$([bool] $AllowTagMismatch)`` |",
    "| Published | ``$published`` |"
  ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}
Write-Output $asset
