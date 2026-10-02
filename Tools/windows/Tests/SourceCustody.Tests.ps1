[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$script = Join-Path $repoRoot "Tools\windows\source-custody.ps1"
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
  throw "RED: source custody tool is missing: $script"
}

$tokens = $null
$errors = $null
[void] [Management.Automation.Language.Parser]::ParseFile($script, [ref] $tokens, [ref] $errors)
if ($errors.Count) { throw "source custody tool has parse errors: $errors" }

$fixture = Join-Path ([IO.Path]::GetTempPath()) "graphcode-source-custody-$([guid]::NewGuid())"
$source = Join-Path $fixture "source"
$artifact = Join-Path $fixture "GraphCode-source-custody.zip"
$artifactCopy = Join-Path $fixture "GraphCode-source-custody-copy.zip"
$expanded = Join-Path $fixture "expanded"
$restored = Join-Path $fixture "restored"
$tag = "0.0.0-custody-test"
$oldTerminalPrompt = $env:GIT_TERMINAL_PROMPT
$oldHttpProxy = $env:HTTP_PROXY
$oldHttpsProxy = $env:HTTPS_PROXY

function Invoke-Git([string] $root, [string[]] $arguments) {
  $output = & git -C $root @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git -C '$root' $($arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
  }
  return @($output)
}

function Invoke-Custody(
  [string] $entryPoint,
  [string[]] $arguments,
  [string] $powerShell = "pwsh"
) {
  $output = & $powerShell -NoProfile -File $entryPoint @arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "source custody command failed: $($output -join [Environment]::NewLine)"
  }
  return @($output)
}

try {
  New-Item -ItemType Directory -Path (Join-Path $source "assets") -Force | Out-Null
  Invoke-Git $fixture @("init", "--initial-branch", "main", $source) | Out-Null
  Invoke-Git $source @("config", "user.name", "Source Custody Test") | Out-Null
  Invoke-Git $source @("config", "user.email", "source-custody@example.invalid") | Out-Null
  Invoke-Git $source @("lfs", "install", "--local") | Out-Null
  [IO.File]::WriteAllText(
    (Join-Path $source ".gitattributes"),
    "assets/*.bin filter=lfs diff=lfs merge=lfs -text`n",
    [Text.UTF8Encoding]::new($false)
  )
  [IO.File]::WriteAllText(
    (Join-Path $source ".lfsconfig"),
    "[lfs]`nurl = http://127.0.0.1:1/network-must-not-be-used`n",
    [Text.UTF8Encoding]::new($false)
  )
  $payload = [byte[]]::new(8192)
  for ($index = 0; $index -lt $payload.Length; $index++) {
    $payload[$index] = ($index * 31 + 17) % 256
  }
  [IO.File]::WriteAllBytes((Join-Path $source "assets\fixture.bin"), $payload)
  Invoke-Git $source @("add", ".gitattributes", ".lfsconfig", "assets/fixture.bin") | Out-Null
  Invoke-Git $source @("commit", "-m", "Add representative LFS fixture") | Out-Null
  Invoke-Git $source @("tag", "-a", $tag, "-m", "Source custody fixture") | Out-Null
  $commit = [string] (Invoke-Git $source @("rev-parse", "HEAD") | Select-Object -Last 1)

  Invoke-Custody $script @(
    "-Command", "Create",
    "-Repository", $source,
    "-Candidate", $commit,
    "-Tag", $tag,
    "-Artifact", $artifact
  ) | Out-Null
  if (-not (Test-Path -LiteralPath $artifact -PathType Leaf)) {
    throw "source custody creation produced no artifact"
  }
  Write-Output "Source custody creation: PASS"

  Invoke-Custody $script @("-Command", "Verify", "-Artifact", $artifact) | Out-Null
  Expand-Archive -LiteralPath $artifact -DestinationPath $expanded
  $manifest = Get-Content -LiteralPath (Join-Path $expanded "custody-manifest.json") -Raw |
    ConvertFrom-Json
  if ([string] $manifest.candidateCommit -ne $commit -or
      [string] $manifest.tag -ne $tag -or
      [int] $manifest.lfs.objectCount -ne 1) {
    throw "source custody manifest lost exact candidate/tag/LFS identity"
  }
  Write-Output "Source custody verification: PASS"

  Invoke-Custody $script @(
    "-Command", "Create",
    "-Repository", $source,
    "-Candidate", $commit,
    "-Tag", $tag,
    "-Artifact", $artifactCopy
  ) | Out-Null
  $hash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash
  $copyHash = (Get-FileHash -LiteralPath $artifactCopy -Algorithm SHA256).Hash
  if ($hash -cne $copyHash) {
    throw "identical source custody inputs produced different artifacts: $hash != $copyHash"
  }
  Write-Output "Source custody determinism: PASS"

  Remove-Item -LiteralPath $source -Recurse -Force
  $env:GIT_TERMINAL_PROMPT = "0"
  $env:HTTP_PROXY = "http://127.0.0.1:1"
  $env:HTTPS_PROXY = "http://127.0.0.1:1"
  $restoreScript = Join-Path $expanded "Restore-GraphCodeSource.ps1"
  Invoke-Custody $restoreScript @(
    "-Command", "Restore",
    "-ArtifactRoot", $expanded,
    "-Destination", $restored
  ) "powershell.exe" | Out-Null

  $restoredHead = [string] (Invoke-Git $restored @("rev-parse", "HEAD") | Select-Object -Last 1)
  $restoredTag = [string] (
    Invoke-Git $restored @("rev-parse", "$tag^{commit}") | Select-Object -Last 1
  )
  $status = @(Invoke-Git $restored @("status", "--short"))
  if ($restoredHead -ne $commit -or $restoredTag -ne $commit) {
    throw "offline restore lost exact revision/tag: HEAD=$restoredHead tag=$restoredTag expected=$commit"
  }
  if ($status.Count -ne 0) {
    throw "offline restore is dirty: $($status -join [Environment]::NewLine)"
  }
  $restoredPayload = [IO.File]::ReadAllBytes((Join-Path $restored "assets\fixture.bin"))
  if (-not [Linq.Enumerable]::SequenceEqual[byte]($payload, $restoredPayload)) {
    throw "offline restore did not materialize the exact LFS payload"
  }
  $lfsFiles = (Invoke-Git $restored @("lfs", "ls-files", "--json", $commit) | Out-String) |
    ConvertFrom-Json
  if (@($lfsFiles.files).Count -ne 1 -or
      -not [bool] $lfsFiles.files[0].checkout -or
      -not [bool] $lfsFiles.files[0].downloaded) {
    throw "offline restore did not materialize its LFS object from local custody"
  }
  Write-Output "Offline exact clean restore: PASS"
  Write-Output "Source custody regression cases: PASS (4/4)"
} finally {
  $env:GIT_TERMINAL_PROMPT = $oldTerminalPrompt
  $env:HTTP_PROXY = $oldHttpProxy
  $env:HTTPS_PROXY = $oldHttpsProxy
  Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
