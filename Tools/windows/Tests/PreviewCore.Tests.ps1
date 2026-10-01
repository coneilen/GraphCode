[CmdletBinding()]
param(
  [ValidateSet("IncompleteFlight", "All")]
  [string] $Case = "All"
)

$ErrorActionPreference = "Stop"
$qualification = Join-Path $PSScriptRoot "PreviewCore.Qualification.ps1"
if (-not (Test-Path -LiteralPath $qualification -PathType Leaf)) {
  throw "PreviewCore qualification entrypoint is missing (structural contract RED; no product runtime ran)"
}
. $qualification -HelpersOnly

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
$root = Join-Path $repo (".build\preview-core-contract-" + [guid]::NewGuid().ToString("N"))
$executed = 0
$oldTemp = $env:TEMP
$oldTmp = $env:TMP

function New-ContractArtifact {
  $hashes = [ordered]@{}
  foreach ($name in @("metadata", "manifest", "providerProvenance", "shell", "daemon", "cli", "zmx")) {
    $hashes[$name] = "a" * 64
  }
  [pscustomobject]@{
    sourceCommit = "b" * 40; sha256 = "c" * 64; version = "1.2.3-alpha"
    tag = "v1.2.3-alpha"; tagCommit = "b" * 40
    tagMatchesSource = $true; tagMismatchAllowed = $false
    signing = "UNSIGNED (not code signed)"
    winghosttyCommit = "6286560d0aa3103e068b2b7afa81eac373d870c9"
    zmxCommit = "785b3fd15dcafd1882b495c831a10f98c201b908"
    hashes = [pscustomobject]$hashes
  }
}

function New-ContractReference([string] $relative) {
  [pscustomobject]@{ path = $relative; sha256 = Get-PreviewCoreHash (Join-Path $root $relative) }
}

function Test-Contract([string] $name, [scriptblock] $body) {
  & $body
  $script:executed++
  Write-Output "CONTRACT CASE: $name"
}

function Assert-Rejected([scriptblock] $body, [string] $message) {
  $failure = $null
  try { & $body | Out-Null } catch { $failure = $_ }
  if (-not $failure -or $failure.Exception.Message -notlike "*$message*") {
    throw "Expected rejection '$message'; actual: $failure"
  }
}

function Assert-Equal($actual, $expected) {
  if ($actual -cne $expected) { throw "Expected '$expected', got '$actual'" }
}

try {
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $env:TEMP = $root
  $env:TMP = $root
  Test-Contract "NotExecuted cannot qualify" {
    $observation = [pscustomobject]@{
      id = "production-core"; status = "NotExecuted"; count = 0
      method = ""; evidence = @(); facts = [pscustomobject]@{}
    }
    Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "production-core is NotExecuted"
  }
  if ($Case -eq "All") {
    Test-Contract "Failed cannot qualify" {
      $observation = [pscustomobject]@{ id = "production-core"; status = "Failed"; count = 1 }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "production-core is Failed"
    }
    Test-Contract "unknown status cannot qualify" {
      $observation = [pscustomobject]@{ id = "production-core"; status = "Unknown"; count = 1 }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "invalid observation status"
    }
    Test-Contract "zero and string counts cannot qualify" {
      foreach ($count in @(0, "1", 1.5)) {
        $observation = [pscustomobject]@{ id = "production-core"; status = "Passed"; count = $count }
        Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "positive integer observation count"
      }
      Assert-Equal (Test-PreviewCoreInteger ([long]1)) $true
      Assert-Equal (Test-PreviewCoreInteger "1") $false
      Assert-Equal (Test-PreviewCoreInteger 1.5) $false
    }
    Test-Contract "hashes and paths are exact" {
      Assert-Rejected { Assert-PreviewCoreHash "not-a-hash" 64 "ZIP" } "invalid ZIP"
      foreach ($relative in @("..\foreign.txt", "C:\foreign.txt", "\\server\share\file", "a:stream", "a/../b", "", "NUL.txt", "a\COM1", "wild*.txt")) {
        Assert-Rejected { Resolve-PreviewCoreChild $root $relative } "invalid owned relative path"
      }
      Assert-Equal (Resolve-PreviewCoreChild $root "owned.txt") (Join-Path $root "owned.txt")
    }
    Test-Contract "prepared packet leaves all live observations unexecuted" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      Assert-Equal @($packet.observations).Count 9
      Assert-Equal @($packet.observations | Where-Object { $_.status -ne "NotExecuted" -or $_.count -ne 0 }).Count 0
      Assert-Equal $packet.backend.version ""
      Assert-Equal $packet.runtime.daemon "Unknown"
      Assert-Equal $packet.custody.accepted $false
      Assert-Equal @($packet.profile.observations).Count 0
      Assert-Equal @($packet.custody.sourceCI).Count 6
      Assert-Equal @($packet.custody.sourceCI | Where-Object { $_.executed -or $_.executedCases -ne 0 }).Count 0
      foreach ($row in $packet.observations) {
        foreach ($check in (Get-PreviewCoreChecks $row.id)) {
          Assert-Equal $row.facts[$check] $null
        }
      }
    }
    Test-Contract "fixture contains public sentinels but no graph or sessions" {
      $fixture = Join-Path $root "fixture"
      New-Item -ItemType Directory -Path $fixture | Out-Null
      Write-PreviewCoreFixture $fixture
      Assert-Equal ([IO.File]::ReadAllText((Join-Path $fixture "project\alpha.txt"))) "A-start-Z-end`n"
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "support") -Force).Count 0
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "install") -Force).Count 0
      Assert-Equal @(Get-ChildItem -LiteralPath (Join-Path $fixture "evidence") -Force).Count 0
      if ([IO.File]::ReadAllText((Join-Path $fixture "FLIGHT.txt")) -notmatch "PREPARED ONLY") {
        throw "Flight instructions did not distinguish preparation from qualification"
      }
      Assert-Rejected { Write-PreviewCoreFixture $fixture } "already exists"
    }
    Test-Contract "contract-valid artifact is not a production flight" {
      $artifact = New-ContractArtifact
      Assert-PreviewCoreArtifact $artifact ("b" * 40) ("c" * 64)
      $packet = New-PreviewCorePacket $artifact $root ("d" * 64)
      $packet.testOnly = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "test-only evidence"
    }
    foreach ($mutation in @(
        @{ Name = "source identity"; Field = "sourceCommit"; Value = ("e" * 40); Error = "candidate identity mismatch" },
        @{ Name = "package identity"; Field = "sha256"; Value = ("e" * 64); Error = "candidate identity mismatch" },
        @{ Name = "tag source"; Field = "tagCommit"; Value = ("e" * 40); Error = "tag/source mismatch" },
        @{ Name = "tag version"; Field = "tag"; Value = "v9.9.9"; Error = "tag/version mismatch" },
        @{ Name = "development version"; Field = "version"; Value = "1.2.3-dev"; Error = "non-dev" },
        @{ Name = "unknown version"; Field = "version"; Value = "unknown"; Error = "non-dev" },
        @{ Name = "mismatch override"; Field = "tagMismatchAllowed"; Value = $true; Error = "tag mismatch override" },
        @{ Name = "string boolean"; Field = "tagMatchesSource"; Value = "true"; Error = "tag/source equality" },
        @{ Name = "missing unsigned declaration"; Field = "signing"; Value = ""; Error = "unsigned preview warning" },
        @{ Name = "provider repin"; Field = "zmxCommit"; Value = ("e" * 40); Error = "provider pins changed" }
      )) {
      Test-Contract ("reject " + $mutation.Name) {
        $artifact = New-ContractArtifact
        $artifact.($mutation.Field) = $mutation.Value
        Assert-Rejected { Assert-PreviewCoreArtifact $artifact ("b" * 40) ("c" * 64) } $mutation.Error
      }
    }
    Test-Contract "a parseable boolean string is not an approval" {
      Assert-Rejected { Assert-PreviewCoreTrue "true" "approval" } "approval must be witnessed true"
      Assert-Rejected { Assert-PreviewCoreFalse "false" "seeded model" } "seeded model must be explicit false"
    }
    Test-Contract "reparse paths are rejected without following their targets" {
      $target = Join-Path $root "owned-target"
      $junction = Join-Path $root "owned-junction"
      New-Item -ItemType Directory -Path $target | Out-Null
      New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
      try {
        Assert-Rejected { Resolve-PreviewCoreChild $root "owned-junction\readback.json" } "reparse point"
      } finally { [IO.Directory]::Delete($junction) }
    }
    Test-Contract "evidence is digest bound, not merely present" {
      [IO.File]::WriteAllText((Join-Path $root "witness.txt"), "public pure-contract witness")
      $reference = New-ContractReference "witness.txt"
      Assert-PreviewCoreEvidence $reference $root
      $reference.sha256 = "0" * 64
      Assert-Rejected { Assert-PreviewCoreEvidence $reference $root } "evidence digest mismatch"
    }
    Test-Contract "native input counts alone cannot qualify" {
      $observation = [pscustomobject]@{
        id = "production-core"; status = "Passed"; count = 10
        method = "QueuedInput"; evidence = @((New-ContractReference "witness.txt"))
      }
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "requires NativeManual"
      $observation.method = "NativeManual"
      Assert-Rejected { Assert-PreviewCoreObservation $observation $root } "PNG pixel witness"
    }
    Test-Contract "unknown PNG bytes cannot become pixel evidence" {
      [IO.File]::WriteAllText((Join-Path $root "invalid.png"), "not a screenshot")
      Assert-Rejected { Assert-PreviewCoreEvidence (New-ContractReference "invalid.png") $root -RequirePng } "invalid owned PNG"
      Assert-Rejected { Assert-PreviewCoreEvidence (New-ContractReference "witness.txt") $root -RequirePng } "PNG pixel witness"
    }
    Test-Contract "missing and duplicate flight rows cannot qualify" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      Assert-Equal @(Get-PreviewCoreSteps | Sort-Object -Unique).Count 9
      Assert-PreviewCoreCoverage $packet.observations
      $packet.observations = @()
      Assert-Rejected { Assert-PreviewCoreCoverage $packet.observations } "missing or duplicated"
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      $packet.observations[0].id = $packet.observations[1].id
      Assert-Rejected { Assert-PreviewCoreCoverage $packet.observations } "missing or duplicated"
    }
    Test-Contract "stub and seeded production claims cannot qualify" {
      $packet = New-PreviewCorePacket (New-ContractArtifact) $root ("d" * 64)
      $packet.runtime.daemon = "Stub"
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "ordinary installed production daemon"
      $packet.runtime.daemon = "Production"
      $packet.runtime.installation = "ScheduledTask"
      $packet.runtime.seededModel = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "seeded model"
      $packet.runtime.seededModel = $false
      $packet.runtime.testHooks = $true
      Assert-Rejected { Assert-PreviewCoreFlight $packet ("b" * 40) ("c" * 64) $root } "test hooks"
    }
    Test-Contract "pure artifact mismatch does not create a flight root" {
      $archive = Join-Path $root "not-a-package.zip"
      [IO.File]::WriteAllText($archive, "test-only; not a production package")
      $run = Join-Path $repo (".build\preview-core\flight-" + [guid]::NewGuid().ToString("N"))
      Assert-Rejected { Invoke-PreviewCorePrepare $archive ("b" * 40) ("0" * 64) $run } "ZIP hash mismatch"
      Assert-Equal (Test-Path -LiteralPath $run) $false
    }
    Test-Contract "run roots cannot adopt external or shared state" {
      Assert-Rejected { Assert-PreviewCoreRunRoot $root } "child of this checkout"
      Assert-Rejected { Assert-PreviewCoreRunRoot $repo } "child of this checkout"
    }
    Test-Contract "package snapshot reader binds actual file bytes without claiming verification" {
      $snapshot = Join-Path $root "snapshot"
      New-Item -ItemType Directory -Path (Join-Path $snapshot "bin") -Force | Out-Null
      $artifact = New-ContractArtifact
      $metadata = [ordered]@{
        version = $artifact.version; signing = $artifact.signing
        providerPins = [ordered]@{
          winghostty = @{ sha = $artifact.winghosttyCommit }
          zmx = @{ sha = $artifact.zmxCommit }
        }
        sourceProvenance = @{
          sourceCommit = $artifact.sourceCommit; tag = $artifact.tag; tagCommit = $artifact.tagCommit
          tagMatchesSource = $true; tagMismatchAllowed = $false
        }
      }
      [IO.File]::WriteAllText((Join-Path $snapshot "metadata.json"), ($metadata | ConvertTo-Json -Depth 5))
      foreach ($file in @("manifest.json", "provider-provenance.json", "bin\graphcode-windows.exe",
          "bin\graphcoded.exe", "bin\graphcode.exe", "bin\zmx.exe")) {
        [IO.File]::WriteAllText((Join-Path $snapshot $file), "test-only snapshot bytes; NOT a verified package")
      }
      $read = Get-PreviewCoreArtifact $snapshot ("b" * 40) ("c" * 64)
      Assert-Equal $read.hashes.daemon (Get-PreviewCoreHash (Join-Path $snapshot "bin\graphcoded.exe"))
      [IO.File]::WriteAllText((Join-Path $snapshot "bin\graphcoded.exe"), "different test-only snapshot bytes")
      $changed = Get-PreviewCoreArtifact $snapshot ("b" * 40) ("c" * 64)
      if ($changed.hashes.daemon -ceq $read.hashes.daemon) { throw "Changed payload bytes were not detected" }
    }
    Test-Contract "public checker rejects test-only packet before package or runtime access" {
      $run = Join-Path $repo (".build\preview-core\flight-" + [guid]::NewGuid().ToString("N"))
      Assert-PreviewCoreRunRoot $run
      Assert-Equal (Test-Path -LiteralPath $run) $false
      New-Item -ItemType Directory -Path $run -Force | Out-Null
      try {
        Write-PreviewCoreFixture $run
        $scriptHash = Get-PreviewCoreHash $qualification
        $packet = New-PreviewCorePacket (New-ContractArtifact) $run $scriptHash
        $packet.testOnly = $true
        foreach ($file in @("prepared.json", "qualification.json")) {
          [IO.File]::WriteAllText((Join-Path $run $file), ($packet | ConvertTo-Json -Depth 20))
        }
        $owner = @{
          flightId = $packet.flightId; sourceCommit = "b" * 40; zipSha256 = "c" * 64
          scriptSha256 = $scriptHash
          preparedSha256 = Get-PreviewCoreHash (Join-Path $run "prepared.json")
          projectSha256 = Get-PreviewCoreHash (Join-Path $run "project\alpha.txt")
        }
        [IO.File]::WriteAllText((Join-Path $run "owner.json"), ($owner | ConvertTo-Json))
        Assert-Rejected {
          & $qualification -Command VerifyEvidence -EvidencePath (Join-Path $run "qualification.json") `
            -ExpectedSource ("b" * 40) -ExpectedSha256 ("c" * 64)
        } "test-only evidence"
        Assert-Equal (Test-Path -LiteralPath (Join-Path $run "candidate.zip")) $false
        $owner.preparedSha256 = "0" * 64
        [IO.File]::WriteAllText((Join-Path $run "owner.json"), ($owner | ConvertTo-Json))
        Assert-Rejected {
          & $qualification -Command VerifyEvidence -EvidencePath (Join-Path $run "qualification.json") `
            -ExpectedSource ("b" * 40) -ExpectedSha256 ("c" * 64)
        } "prepared packet was modified"
      } finally {
        Remove-Item -LiteralPath $run -Recurse -Force
      }
    }
    Test-Contract "entrypoint has no live or publication mode" {
      $tokens = $null
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($qualification, [ref]$tokens, [ref]$errors)
      Assert-Equal $errors.Count 0
      $commands = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() })
      foreach ($forbidden in @("Start-Process", "Stop-Process", "Add-Type", "Get-CimInstance", "Get-Process",
          "Get-WinEvent", "Set-Clipboard", "Get-Clipboard", "Register-ScheduledTask", "schtasks.exe", "gh")) {
        Assert-Equal ($commands -contains $forbidden) $false
      }
      $liveModes = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
          $node.Value -cin @("Install", "Upgrade", "Uninstall", "Publish", "Execute", "Run")
        }, $true))
      Assert-Equal $liveModes.Count 0
    }
    Test-Contract "one existing packaging-contracts hook consumes this pure unit" {
      $validation = Join-Path $repo "Tools\windows\validate.ps1"
      $tokens = $null
      $errors = $null
      $ast = [Management.Automation.Language.Parser]::ParseFile($validation, [ref]$tokens, [ref]$errors)
      Assert-Equal $errors.Count 0
      $hooks = @($ast.FindAll({
          param($node)
          $node -is [Management.Automation.Language.CommandAst] -and
          $node.Extent.Text -match '^& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\PreviewCore\.Tests\.ps1"\)$'
        }, $true))
      Assert-Equal $hooks.Count 1
      $ancestor = $hooks[0].Parent
      while ($ancestor -and $ancestor -isnot [Management.Automation.Language.IfStatementAst]) {
        $ancestor = $ancestor.Parent
      }
      if (-not $ancestor -or $ancestor.Clauses[0].Item1.Extent.Text -cne '$PackagingPart -ne "real"') {
        throw "Pure PreviewCore hook must remain inside packaging-contracts selection"
      }
    }
  }
  if ($executed -lt 1) { throw "No PreviewCore contract cases executed" }
  Write-Output "PREVIEW_CORE_CONTRACTS: executed=$executed; failed=0; testOnly=true; no production flight ran"
} finally {
  $env:TEMP = $oldTemp
  $env:TMP = $oldTmp
  if (Test-Path -LiteralPath $root -PathType Container) {
    Remove-Item -LiteralPath $root -Recurse -Force
  }
}
