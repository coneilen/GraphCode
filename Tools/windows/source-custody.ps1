<#
.SYNOPSIS
  Creates, verifies, or restores a self-contained source custody artifact.

.DESCRIPTION
  A Git bundle contains Git objects but not Git LFS media. This tool packages
  the exact candidate tag with every LFS object needed by that candidate tree.
  Restore checks out pointers without smudging, seeds local LFS storage, and
  materializes from that storage without fetching.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet("Create", "Verify", "Restore")]
  [string] $Command,
  [string] $Repository,
  [string] $Candidate,
  [string] $Tag,
  [string] $Artifact,
  [string] $ArtifactRoot,
  [string] $Destination,
  [string] $GitCli = "git"
)

$ErrorActionPreference = "Stop"
$script:TemporaryPaths = [Collections.Generic.List[string]]::new()

function Get-FullPath([string] $path, [string] $base = (Get-Location).Path) {
  if ([IO.Path]::IsPathRooted($path)) {
    return [IO.Path]::GetFullPath($path)
  }
  return [IO.Path]::GetFullPath((Join-Path $base $path))
}

function Invoke-Git([string] $root, [string[]] $arguments) {
  $invocation = @()
  if ($root) { $invocation += @("-C", $root) }
  $invocation += $arguments
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $output = & $GitCli @invocation 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($exitCode -ne 0) {
    throw "git $($invocation -join ' ') failed: $(@($output) -join [Environment]::NewLine)"
  }
  return @($output | ForEach-Object { [string] $_ })
}

function Resolve-Commit([string] $root, [string] $revision, [string] $description) {
  $commit = [string] (
    Invoke-Git $root @("rev-parse", "--verify", "$revision^{commit}") |
      Select-Object -Last 1
  )
  $commit = $commit.Trim().ToLowerInvariant()
  if ($commit -notmatch "^[0-9a-f]{40}$") {
    throw "$description '$revision' resolved to invalid commit '$commit'"
  }
  return $commit
}

function Assert-TagName([string] $value) {
  if (-not $value -or $value -notmatch "^[0-9A-Za-z][0-9A-Za-z._-]*$") {
    throw "custody tag is missing or unsafe: '$value'"
  }
}

function Get-Sha256([string] $path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-Utf8File([string] $path, [string] $content) {
  [IO.File]::WriteAllText($path, $content, [Text.UTF8Encoding]::new($false))
}

function New-TemporaryDirectory([string] $label) {
  $path = Join-Path ([IO.Path]::GetTempPath()) "$label-$([guid]::NewGuid())"
  New-Item -ItemType Directory -Path $path | Out-Null
  $script:TemporaryPaths.Add($path)
  return $path
}

function New-DeterministicZip([string] $sourceRoot, [string] $destination) {
  Add-Type -AssemblyName System.IO.Compression
  $stream = [IO.File]::Open(
    $destination,
    [IO.FileMode]::CreateNew,
    [IO.FileAccess]::ReadWrite,
    [IO.FileShare]::None
  )
  try {
    $archive = [IO.Compression.ZipArchive]::new(
      $stream,
      [IO.Compression.ZipArchiveMode]::Create,
      $false,
      [Text.Encoding]::UTF8
    )
    try {
      $files = @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File |
          Sort-Object { $_.FullName.Substring($sourceRoot.Length).Replace("\", "/") }
      )
      foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart("\", "/")
        $entryName = $relative.Replace("\", "/")
        $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [DateTimeOffset]::new(
          1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero
        )
        $entry.ExternalAttributes = 0
        $input = [IO.File]::OpenRead($file.FullName)
        try {
          $output = $entry.Open()
          try { $input.CopyTo($output) } finally { $output.Dispose() }
        } finally {
          $input.Dispose()
        }
      }
    } finally {
      $archive.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Get-LfsFiles([string] $root, [string] $commit) {
  $json = (Invoke-Git $root @("lfs", "ls-files", "--json", "--long", "--size", $commit) |
      Out-String)
  $document = $json | ConvertFrom-Json
  $files = @($document.files)
  foreach ($file in $files) {
    $oid = ([string] $file.oid).ToLowerInvariant()
    if ([string] $file.oid_type -ne "sha256" -or $oid -notmatch "^[0-9a-f]{64}$") {
      throw "candidate LFS entry '$($file.name)' has invalid object identity"
    }
    if ([long] $file.size -lt 0) {
      throw "candidate LFS entry '$($file.name)' has invalid size"
    }
  }
  return $files
}

function Get-LfsObjectPath([string] $objectsRoot, [string] $oid) {
  return Join-Path $objectsRoot (Join-Path $oid.Substring(0, 2) (
      Join-Path $oid.Substring(2, 2) $oid
    ))
}

function New-CustodyArtifact {
  if (-not $Repository -or -not $Candidate -or -not $Tag -or -not $Artifact) {
    throw "Create requires -Repository, -Candidate, -Tag, and -Artifact"
  }
  Assert-TagName $Tag
  $repositoryRoot = (Resolve-Path -LiteralPath $Repository).Path
  $artifactPath = Get-FullPath $Artifact
  if ([IO.Path]::GetExtension($artifactPath) -ine ".zip") {
    throw "source custody artifact must be a .zip file"
  }
  if (Test-Path -LiteralPath $artifactPath) {
    throw "source custody artifact already exists: $artifactPath"
  }
  $artifactParent = Split-Path -Parent $artifactPath
  New-Item -ItemType Directory -Path $artifactParent -Force | Out-Null

  $candidateCommit = Resolve-Commit $repositoryRoot $Candidate "candidate"
  $tagReference = "refs/tags/$Tag"
  $tagType = [string] (
    Invoke-Git $repositoryRoot @("cat-file", "-t", $tagReference) |
      Select-Object -Last 1
  )
  if ($tagType.Trim() -ne "tag") {
    throw "custody tag '$Tag' must be an annotated tag"
  }
  $tagCommit = Resolve-Commit $repositoryRoot $tagReference "custody tag"
  if ($tagCommit -ne $candidateCommit) {
    throw "custody tag '$Tag' peels to $tagCommit, expected candidate $candidateCommit"
  }

  $stage = New-TemporaryDirectory "graphcode-source-custody-create"
  $bundle = Join-Path $stage "GraphCode-source.bundle"
  Invoke-Git $repositoryRoot @("bundle", "create", $bundle, $tagReference) | Out-Null
  Invoke-Git $repositoryRoot @("bundle", "verify", $bundle) | Out-Null

  $commonDirectory = [string] (
    Invoke-Git $repositoryRoot @("rev-parse", "--git-common-dir") |
      Select-Object -Last 1
  )
  if (-not [IO.Path]::IsPathRooted($commonDirectory)) {
    $commonDirectory = Get-FullPath $commonDirectory $repositoryRoot
  }
  $sourceObjects = Join-Path $commonDirectory "lfs\objects"
  $lfsFiles = @(Get-LfsFiles $repositoryRoot $candidateCommit)
  $objects = [Collections.Generic.List[object]]::new()
  foreach ($group in @($lfsFiles | Group-Object { ([string] $_.oid).ToLowerInvariant() } |
      Sort-Object Name)) {
    $oid = [string] $group.Name
    $declaredSizes = @($group.Group | ForEach-Object { [long] $_.size } | Select-Object -Unique)
    if ($declaredSizes.Count -ne 1) {
      throw "candidate LFS object $oid has inconsistent declared sizes"
    }
    $sourceObject = Get-LfsObjectPath $sourceObjects $oid
    if (-not (Test-Path -LiteralPath $sourceObject -PathType Leaf)) {
      throw "candidate LFS object is unavailable locally: $oid"
    }
    $actualSize = (Get-Item -LiteralPath $sourceObject).Length
    if ($actualSize -ne $declaredSizes[0]) {
      throw "candidate LFS object $oid has size $actualSize, expected $($declaredSizes[0])"
    }
    $actualHash = Get-Sha256 $sourceObject
    if ($actualHash -ne $oid) {
      throw "candidate LFS object $oid has SHA-256 $actualHash"
    }
    $relative = "lfs/objects/$($oid.Substring(0, 2))/$($oid.Substring(2, 2))/$oid"
    $destinationObject = Join-Path $stage $relative.Replace("/", "\")
    New-Item -ItemType Directory -Path (Split-Path -Parent $destinationObject) -Force |
      Out-Null
    Copy-Item -LiteralPath $sourceObject -Destination $destinationObject
    $objects.Add([ordered]@{
        oid = $oid
        size = $actualSize
        path = $relative
        sha256 = $actualHash
      })
  }

  $restoreName = "Restore-GraphCodeSource.ps1"
  $restoreScript = Join-Path $stage $restoreName
  Copy-Item -LiteralPath $PSCommandPath -Destination $restoreScript
  $manifest = [ordered]@{
    schemaVersion = 1
    candidateCommit = $candidateCommit
    tag = $Tag
    tagCommit = $tagCommit
    bundle = [ordered]@{
      path = "GraphCode-source.bundle"
      sha256 = Get-Sha256 $bundle
    }
    restoreScript = [ordered]@{
      path = $restoreName
      sha256 = Get-Sha256 $restoreScript
    }
    lfs = [ordered]@{
      trackedFileCount = $lfsFiles.Count
      objectCount = $objects.Count
      objects = @($objects)
    }
  }
  $manifestJson = $manifest | ConvertTo-Json -Depth 8
  Write-Utf8File (Join-Path $stage "custody-manifest.json") ($manifestJson + "`n")
  New-DeterministicZip $stage $artifactPath
  Write-Output "Source custody creation: PASS"
  Write-Output "Candidate: $candidateCommit"
  Write-Output "Tag: $Tag"
  Write-Output "LFS objects: $($objects.Count) for $($lfsFiles.Count) tracked files"
  Write-Output "Artifact: $artifactPath"
  Write-Output "SHA-256: $(Get-Sha256 $artifactPath)"
}

function Open-CustodyArtifact {
  if ($Artifact -and $ArtifactRoot) {
    throw "use either -Artifact or -ArtifactRoot, not both"
  }
  if ($ArtifactRoot) {
    return (Resolve-Path -LiteralPath $ArtifactRoot).Path
  }
  if (-not $Artifact) {
    throw "$Command requires -Artifact or -ArtifactRoot"
  }
  $artifactPath = (Resolve-Path -LiteralPath $Artifact).Path
  $root = New-TemporaryDirectory "graphcode-source-custody-open"
  Expand-Archive -LiteralPath $artifactPath -DestinationPath $root
  return $root
}

function Test-CustodyRoot([string] $root) {
  $manifestPath = Join-Path $root "custody-manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "source custody manifest is missing"
  }
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  if ([int] $manifest.schemaVersion -ne 1) {
    throw "unsupported source custody schema version '$($manifest.schemaVersion)'"
  }
  $candidateCommit = ([string] $manifest.candidateCommit).ToLowerInvariant()
  if ($candidateCommit -notmatch "^[0-9a-f]{40}$") {
    throw "source custody candidate commit is invalid"
  }
  Assert-TagName ([string] $manifest.tag)
  if (([string] $manifest.tagCommit).ToLowerInvariant() -ne $candidateCommit) {
    throw "source custody tag commit does not equal its candidate"
  }

  $expectedFiles = [Collections.Generic.HashSet[string]]::new(
    [StringComparer]::OrdinalIgnoreCase
  )
  [void] $expectedFiles.Add("custody-manifest.json")
  foreach ($record in @($manifest.bundle, $manifest.restoreScript)) {
    $relative = [string] $record.path
    if ($relative -notin @("GraphCode-source.bundle", "Restore-GraphCodeSource.ps1")) {
      throw "source custody contains an unexpected control path '$relative'"
    }
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-Sha256 $path) -ne ([string] $record.sha256).ToLowerInvariant()) {
      throw "source custody control file failed integrity: $relative"
    }
    [void] $expectedFiles.Add($relative)
  }

  $objects = @($manifest.lfs.objects)
  if ([int] $manifest.lfs.objectCount -ne $objects.Count) {
    throw "source custody LFS object count is inconsistent"
  }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($object in $objects) {
    $oid = ([string] $object.oid).ToLowerInvariant()
    $expectedRelative = if ($oid -match "^[0-9a-f]{64}$") {
      "lfs/objects/$($oid.Substring(0, 2))/$($oid.Substring(2, 2))/$oid"
    } else {
      throw "source custody LFS object identity is invalid"
    }
    if (-not $seen.Add($oid) -or [string] $object.path -cne $expectedRelative -or
        ([string] $object.sha256).ToLowerInvariant() -ne $oid) {
      throw "source custody LFS object manifest is invalid for $oid"
    }
    $path = Join-Path $root $expectedRelative.Replace("/", "\")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "source custody LFS object is missing: $oid"
    }
    $file = Get-Item -LiteralPath $path
    if ($file.Length -ne [long] $object.size -or (Get-Sha256 $path) -ne $oid) {
      throw "source custody LFS object failed integrity: $oid"
    }
    [void] $expectedFiles.Add($expectedRelative)
  }
  $actualFiles = @(
    Get-ChildItem -LiteralPath $root -Recurse -File |
      ForEach-Object {
        $_.FullName.Substring($root.Length).TrimStart("\", "/").Replace("\", "/")
      }
  )
  foreach ($relative in $actualFiles) {
    if (-not $expectedFiles.Contains($relative)) {
      throw "source custody contains unmanifested file '$relative'"
    }
  }
  if ($actualFiles.Count -ne $expectedFiles.Count) {
    throw "source custody is missing one or more manifested files"
  }

  $bundle = Join-Path $root ([string] $manifest.bundle.path)
  $verifyRepository = New-TemporaryDirectory "graphcode-source-custody-verify"
  Invoke-Git $null @("init", "--initial-branch", "custody-verify", $verifyRepository) |
    Out-Null
  Invoke-Git $verifyRepository @("bundle", "verify", $bundle) | Out-Null
  $tagReference = "refs/tags/$($manifest.tag)"
  Invoke-Git $verifyRepository @(
    "fetch", "--no-tags", $bundle, "$tagReference`:$tagReference"
  ) | Out-Null
  $tagType = [string] (
    Invoke-Git $verifyRepository @("cat-file", "-t", $tagReference) |
      Select-Object -Last 1
  )
  $tagCommit = Resolve-Commit $verifyRepository $tagReference "custody tag"
  if ($tagType.Trim() -ne "tag" -or $tagCommit -ne $candidateCommit) {
    throw "source custody bundle does not contain the exact annotated candidate tag"
  }

  return [pscustomobject]@{
    Root = $root
    Manifest = $manifest
    Bundle = $bundle
  }
}

function Test-CustodyArtifact {
  $root = Open-CustodyArtifact
  $custody = Test-CustodyRoot $root
  Write-Output "Source custody verification: PASS"
  Write-Output "Candidate: $($custody.Manifest.candidateCommit)"
  Write-Output "Tag: $($custody.Manifest.tag)"
  Write-Output "LFS objects: $($custody.Manifest.lfs.objectCount)"
}

function Restore-CustodyArtifact {
  if (-not $ArtifactRoot -or $Artifact) {
    throw "Restore requires extracted -ArtifactRoot and does not accept -Artifact"
  }
  if (-not $Destination) {
    throw "Restore requires -Destination"
  }
  $root = Open-CustodyArtifact
  $custody = Test-CustodyRoot $root
  $destinationPath = Get-FullPath $Destination
  if (Test-Path -LiteralPath $destinationPath) {
    throw "restore destination already exists: $destinationPath"
  }
  New-Item -ItemType Directory -Path (Split-Path -Parent $destinationPath) -Force |
    Out-Null

  $oldSkipSmudge = $env:GIT_LFS_SKIP_SMUDGE
  try {
    $env:GIT_LFS_SKIP_SMUDGE = "1"
    Invoke-Git $null @("init", "--initial-branch", "custody", $destinationPath) | Out-Null
    Invoke-Git $destinationPath @("lfs", "install", "--local") | Out-Null
    $tagReference = "refs/tags/$($custody.Manifest.tag)"
    Invoke-Git $destinationPath @(
      "fetch", "--no-tags", $custody.Bundle, "$tagReference`:$tagReference"
    ) | Out-Null
    $destinationObjects = Join-Path $destinationPath ".git\lfs\objects"
    foreach ($object in @($custody.Manifest.lfs.objects)) {
      $oid = [string] $object.oid
      $relative = ([string] $object.path).Substring("lfs/objects/".Length)
      $sourceObject = Join-Path $root ([string] $object.path).Replace("/", "\")
      $destinationObject = Join-Path $destinationObjects $relative.Replace("/", "\")
      New-Item -ItemType Directory -Path (Split-Path -Parent $destinationObject) -Force |
        Out-Null
      Copy-Item -LiteralPath $sourceObject -Destination $destinationObject
    }
    Invoke-Git $destinationPath @(
      "checkout", "--detach", [string] $custody.Manifest.candidateCommit
    ) | Out-Null
  } catch {
    if (Test-Path -LiteralPath $destinationPath) {
      Remove-Item -LiteralPath $destinationPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    $env:GIT_LFS_SKIP_SMUDGE = $oldSkipSmudge
  }

  try {
    Invoke-Git $destinationPath @("lfs", "checkout") | Out-Null
    $candidateCommit = ([string] $custody.Manifest.candidateCommit).ToLowerInvariant()
    $head = Resolve-Commit $destinationPath "HEAD" "restored HEAD"
    $tagCommit = Resolve-Commit $destinationPath "refs/tags/$($custody.Manifest.tag)" "restored tag"
    if ($head -ne $candidateCommit -or $tagCommit -ne $candidateCommit) {
      throw "restored source identity mismatch: HEAD=$head tag=$tagCommit expected=$candidateCommit"
    }
    $lfsFiles = @(Get-LfsFiles $destinationPath $candidateCommit)
    if ($lfsFiles.Count -ne [int] $custody.Manifest.lfs.trackedFileCount) {
      throw "restored LFS file count does not match custody manifest"
    }
    foreach ($file in $lfsFiles) {
      if (-not [bool] $file.checkout -or -not [bool] $file.downloaded) {
        throw "restored LFS file was not materialized from custody: $($file.name)"
      }
    }
    $status = @(Invoke-Git $destinationPath @("status", "--short"))
    if ($status.Count -ne 0) {
      throw "restored source checkout is dirty: $($status -join [Environment]::NewLine)"
    }
  } catch {
    Remove-Item -LiteralPath $destinationPath -Recurse -Force -ErrorAction SilentlyContinue
    throw
  }

  Write-Output "Source custody restore: PASS"
  Write-Output "Candidate: $candidateCommit"
  Write-Output "Tag: $($custody.Manifest.tag)"
  Write-Output "Clean status: PASS"
  Write-Output "Destination: $destinationPath"
}

try {
  switch ($Command) {
    "Create" { New-CustodyArtifact }
    "Verify" { Test-CustodyArtifact }
    "Restore" { Restore-CustodyArtifact }
  }
} finally {
  foreach ($path in $script:TemporaryPaths) {
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  }
}
