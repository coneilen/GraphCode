<#
.SYNOPSIS
  Prepares and checks one installed production-daemon/real-backend preview flight.
.DESCRIPTION
  Prepare verifies a caller-selected ZIP and creates only an owned synthetic
  local project and an unexecuted flight packet. VerifyEvidence checks actual,
  reviewed evidence; it does not obtain witnesses or authorize publication.
  Neither command installs, launches, authenticates, drives UI, or manages
  processes/tasks. Backend/version and every live permission are chosen later.
  Keep credentials, environment/command-line dumps, foreign UI, and private
  code out of the packet and its evidence. Checksums are not publisher trust.
.EXAMPLE
  .\PreviewCore.Qualification.ps1 -Command Prepare -Package $zip `
    -ExpectedSource $source -ExpectedSha256 $hash -RunRoot $ownedNewFlightRoot
.EXAMPLE
  .\PreviewCore.Qualification.ps1 -Command VerifyEvidence `
    -EvidencePath $completedPacket -ExpectedSource $source -ExpectedSha256 $hash
#>
[CmdletBinding()]
param(
  [ValidateSet("Prepare", "VerifyEvidence")]
  [string] $Command,
  [string] $Package,
  [string] $ExpectedSource,
  [string] $ExpectedSha256,
  [string] $RunRoot,
  [string] $EvidencePath,
  [switch] $HelpersOnly
)

$ErrorActionPreference = "Stop"

function Assert-PreviewCore($condition, [string] $message) {
  if (-not $condition) { throw "PreviewCore: $message" }
}

function Test-PreviewCoreInteger($value) {
  return $value -is [int] -or $value -is [long]
}

function Assert-PreviewCoreHash([string] $value, [int] $length, [string] $label) {
  Assert-PreviewCore ($value -cmatch "^[0-9a-f]{$length}$") "invalid $label"
}

function Assert-PreviewCoreTrue($value, [string] $label) {
  Assert-PreviewCore ($value -is [bool] -and $value) "$label must be witnessed true"
}

function Assert-PreviewCoreFalse($value, [string] $label) {
  Assert-PreviewCore ($value -is [bool] -and -not $value) "$label must be explicit false"
}

function Assert-PreviewCoreText($value, [string] $label) {
  Assert-PreviewCore ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value) -and
    $value.Length -le 512 -and $value -notmatch '^(?i:unknown|notexecuted|todo|tbd|n/a)$') "missing or invalid $label"
}

function Assert-PreviewCorePath([string] $path) {
  Assert-PreviewCore ([IO.Path]::IsPathRooted($path) -and $path -notmatch '^\\\\') "owned path must be local and absolute"
  $current = [IO.Path]::GetFullPath($path)
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      $item = Get-Item -LiteralPath $current -Force
      Assert-PreviewCore (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "owned path contains a reparse point"
    }
    $parent = [IO.Directory]::GetParent($current)
    $current = if ($parent) { $parent.FullName } else { $null }
  }
}

function Resolve-PreviewCoreChild([string] $root, [string] $relative) {
  Assert-PreviewCore ($relative -and $relative -notmatch '[<>:"/|?*\x00-\x1f]' -and
    -not [IO.Path]::IsPathRooted($relative) -and
    @($relative.Split('\') | Where-Object { $_ -in @("", ".", "..") -or $_ -match '[. ]$' -or
        $_ -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$' }).Count -eq 0) "invalid owned relative path"
  Assert-PreviewCorePath $root
  $fullRoot = [IO.Path]::GetFullPath($root).TrimEnd('\')
  $path = [IO.Path]::GetFullPath((Join-Path $fullRoot $relative))
  Assert-PreviewCore ($path.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) "evidence escapes owned root"
  Assert-PreviewCorePath $path
  return $path
}

function Get-PreviewCoreHash([string] $path) {
  Assert-PreviewCorePath $path
  Assert-PreviewCore (Test-Path -LiteralPath $path -PathType Leaf) "required owned file is missing"
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PreviewCoreSteps {
  @(
    "artifact-custody", "installed-production", "production-core",
    "actual-backend-terminal", "client-reachability", "stop-exit-reopen",
    "update-recovery-retention", "safe-mutations", "tester-handoff"
  )
}

function Get-PreviewCoreChecks([string] $id) {
  switch ($id) {
    "artifact-custody" { @("independentTagSourceWitness", "standalonePowerShell51", "standalonePowerShell7", "unsignedWarning") }
    "installed-production" { @("freshScheduledInstall", "noDeveloperDependencies", "productionEndpointReachable") }
    "production-core" { @("rendered", "selected", "editorCancelUnchanged") }
    "actual-backend-terminal" { @("actualAgent", "readableCurrentPixels", "requiredControls", "ptyResizeMatched", "wrap", "minimizeRestore", "offeredTabContinuity", "showInGraphSameLoop") }
    "client-reachability" { @("controlsReachable", "nonAsciiInput", "deadKeyInput", "clipboardUnusedOrSeparatelyWitnessed") }
    "stop-exit-reopen" { @("intendedLoopStopped", "closeToTray", "explicitExit", "daemonRecovery", "historyBoundaryWitnessed", "safeExit") }
    "update-recovery-retention" { @("manualUpgrade", "lockedUpgradeRefused", "rollback", "uninstalledWithoutRemoveUserData", "recoveryLocationsReported") }
    "safe-mutations" { @("cancelUnchanged", "confirmedCapturedTargetOnly", "partialFailureReported", "primaryFixtureRetained") }
    "tester-handoff" { @("exactArtifactInstructions", "unsignedPolicyWarning", "checksumNotAuthenticity", "limitations", "recoveryAndBugRoute") }
  }
}

function New-PreviewCoreFacts([string] $id) {
  $facts = [ordered]@{}
  foreach ($name in (Get-PreviewCoreChecks $id)) { $facts[$name] = $null }
  $textFields = switch ($id) {
    "production-core" { @("selectedLoopId", "persistedLoopId", "graphTitle", "sidebarTitle", "checkDescription", "cancelDraft", "cancelBeforeSha256", "cancelAfterSha256") }
    "actual-backend-terminal" { @("loopId", "backendKind", "backendVersion", "input", "output1", "output2", "terminalMode") }
    "stop-exit-reopen" { @("stoppedLoopId", "reopenedLoopId", "reopenedTitle", "reopenedCheckDescription") }
    "update-recovery-retention" { @("predecessorSha256", "predecessorVersion", "userDataBeforeSha256", "userDataAfterSha256") }
    "safe-mutations" { @("sacrificialTarget") }
  }
  foreach ($name in $textFields) { $facts[$name] = "" }
  if ($id -eq "production-core") { $facts.createdCount = 0 }
  if ($id -eq "actual-backend-terminal") { $facts.agentTurns = 0 }
  if ($id -in @("production-core", "stop-exit-reopen")) {
    $facts.readback = [ordered]@{ path = ""; sha256 = "" }
  }
  return $facts
}

function Get-PreviewCoreCiJobs {
  @(
    "windows-shell unit (shard 0 of 3)", "windows-shell unit (shard 1 of 3)",
    "windows-shell unit (shard 2 of 3)", "windows-shell integration",
    "windows-shell packaging contracts", "windows-shell packaging (real products)"
  )
}

function Assert-PreviewCoreCoverage($observations) {
  $rows = @($observations)
  Assert-PreviewCore ($rows.Count -eq 9 -and (($rows.id | Sort-Object) -join ',') -ceq
    ((Get-PreviewCoreSteps | Sort-Object) -join ',')) "fixed flight observations are missing or duplicated"
}

function Assert-PreviewCoreRunRoot([string] $root) {
  Assert-PreviewCorePath $root
  $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
  $anchor = Join-Path $repo ".build\preview-core"
  $full = [IO.Path]::GetFullPath($root)
  Assert-PreviewCore ([IO.Path]::GetDirectoryName($full) -ieq $anchor -and
    [IO.Path]::GetFileName($full) -cmatch '^flight-[0-9a-f]{32}$') "run root must be a new .build\preview-core\flight-GUID child of this checkout"
}

function Assert-PreviewCoreArtifact($artifact, [string] $source, [string] $hash) {
  Assert-PreviewCoreHash $source 40 "expected source SHA"
  Assert-PreviewCoreHash $hash 64 "expected ZIP SHA-256"
  Assert-PreviewCore ($artifact.sourceCommit -ceq $source -and $artifact.sha256 -ceq $hash) "candidate identity mismatch"
  Assert-PreviewCore ($artifact.version -cmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.]*)?$' -and
    $artifact.version -notmatch '(?i)(^|[-.])dev([-.]|$)') "non-dev package version is required"
  Assert-PreviewCore ($artifact.tag -ceq "v$($artifact.version)" -or $artifact.tag -ceq $artifact.version) "tag/version mismatch"
  Assert-PreviewCore ($artifact.tagCommit -ceq $source) "tag/source mismatch"
  Assert-PreviewCoreTrue $artifact.tagMatchesSource "tag/source equality"
  Assert-PreviewCoreFalse $artifact.tagMismatchAllowed "tag mismatch override"
  Assert-PreviewCore ($artifact.signing -ceq "UNSIGNED (not code signed)") "expected explicit unsigned preview warning"
  foreach ($name in @("metadata", "manifest", "providerProvenance", "shell", "daemon", "cli", "zmx")) {
    Assert-PreviewCoreHash $artifact.hashes.$name 64 "$name digest"
  }
  Assert-PreviewCore ($artifact.winghosttyCommit -ceq "6286560d0aa3103e068b2b7afa81eac373d870c9" -and
    $artifact.zmxCommit -ceq "785b3fd15dcafd1882b495c831a10f98c201b908") "accepted provider pins changed"
}

function Get-PreviewCoreArtifact([string] $packageRoot, [string] $source, [string] $hash) {
  $metadata = Get-Content -LiteralPath (Resolve-PreviewCoreChild $packageRoot "metadata.json") -Raw | ConvertFrom-Json
  $artifact = [ordered]@{
    sourceCommit = $metadata.sourceProvenance.sourceCommit
    sha256 = $hash
    version = $metadata.version
    tag = $metadata.sourceProvenance.tag
    tagCommit = $metadata.sourceProvenance.tagCommit
    tagMatchesSource = $metadata.sourceProvenance.tagMatchesSource
    tagMismatchAllowed = $metadata.sourceProvenance.tagMismatchAllowed
    signing = $metadata.signing
    winghosttyCommit = $metadata.providerPins.winghostty.sha
    zmxCommit = $metadata.providerPins.zmx.sha
    hashes = [ordered]@{}
  }
  $paths = [ordered]@{
    metadata = "metadata.json"; manifest = "manifest.json"
    providerProvenance = "provider-provenance.json"
    shell = "bin\graphcode-windows.exe"; daemon = "bin\graphcoded.exe"
    cli = "bin\graphcode.exe"; zmx = "bin\zmx.exe"
  }
  foreach ($name in $paths.Keys) {
    $artifact.hashes[$name] = Get-PreviewCoreHash (Resolve-PreviewCoreChild $packageRoot $paths[$name])
  }
  $artifact = [pscustomobject]$artifact
  Assert-PreviewCoreArtifact $artifact $source $hash
  return $artifact
}

function New-PreviewCorePacket($artifact, [string] $root, [string] $scriptHash) {
  [ordered]@{
    schemaVersion = 1
    kind = "PackagedProductionCore"
    flightId = [guid]::NewGuid().ToString("N")
    testOnly = $false
    preparedUtc = [DateTime]::UtcNow.ToString("o")
    runRoot = $root
    qualificationScriptSha256 = $scriptHash
    artifact = $artifact
    profile = [ordered]@{
      os = ""; build = ""; role = "Unknown"; architecture = ""; graphicsAdapter = ""; shellVersion = ""
      minimumViewportDip = [ordered]@{ width = 0; height = 0 }
      observations = @(); nativeLease = ""; ownedAccountIsolationWitnessed = $false
    }
    backend = [ordered]@{
      kind = ""; version = ""; executableSha256 = ""; permissions = ""; model = ""
      approval = ""; authenticationProvisionedInOwnedAccount = $false
    }
    runtime = [ordered]@{
      daemon = "Unknown"; seededModel = $null; testHooks = $null
      installation = "Unknown"; endpoint = ""; loopId = ""; sessionIdentity = ""
      supportDirectory = ""; installDirectory = ""
      installedHashes = [ordered]@{ shell = ""; daemon = ""; cli = ""; zmx = "" }
    }
    custody = [ordered]@{
      build = [ordered]@{ path = ""; sha256 = "" }
      sourceCI = @(Get-PreviewCoreCiJobs | ForEach-Object {
        [ordered]@{
          job = $_; headSha = ""; url = ""; conclusion = "NotExecuted"; executed = $false
          executedCases = 0; previewCoreExecutedCases = 0
          evidence = [ordered]@{ path = ""; sha256 = "" }
        }
      })
      toolchains = [ordered]@{ swift = ""; zigShell = ""; zigZmx = ""; sdk = ""; msvc = "" }
      allRequiredSourceChecksPassed = $false
      reviewer = ""; accepted = $false; reviewedEvidenceIsOwnedAndSanitized = $false
    }
    observations = @(Get-PreviewCoreSteps | ForEach-Object {
      [ordered]@{
        id = $_; status = "NotExecuted"; count = 0; method = ""
        note = "Requires actual separately authorized flight evidence."
        evidence = @(); facts = New-PreviewCoreFacts $_
      }
    })
  }
}

function Write-PreviewCoreFixture([string] $root) {
  foreach ($child in @("project", "support", "install", "evidence", "temp")) {
    New-Item -ItemType Directory -Path (Resolve-PreviewCoreChild $root $child) | Out-Null
  }
  [IO.File]::WriteAllText((Resolve-PreviewCoreChild $root "project\alpha.txt"), "A-start-Z-end`n", [Text.UTF8Encoding]::new($false))
  $instructions = @'
PREPARED ONLY. No production flight has run.
Do not create a loop until backend authentication, capability, synthetic-data
transmission, two fixture turns/credits, and native/installation permissions
are separately approved in an owned Windows 11 test account.

Use the ordinary installed package and production graphcoded, not a stub,
gate-seeded model, copied zmx workaround, or developer-toolchain fallback.
Open project, create exactly one Turn-based loop using ONE declared backend.
Render/select it; rename to AlphaRenamed; edit Check description to
A-start-Z-end. Change a draft to CancelMustNotPersist, then cancel unchanged.
Opening task: read only alpha.txt; reply with its full line and FlightOutput1.
Native follow-up: Reply with FlightOutput2. Observe real readable replies,
not local echo or queued input. No recurrence/autopilot/additional turns.
Witness actual emitted glyphs, declared non-ASCII/dead-key input, current
pixels, PTY resize/wrap, minimize/restore, offered tabs and Show in Graph.
Witness the declared viewport on Windows 11 at 100% and 150%.
Stop only this loop; distinguish close-to-tray/Exit; recover and reopen the
same project, title, Check description and node ID with real history semantics.
Reuse separately approved install/manual-upgrade/locked-upgrade/rollback/
uninstall paths. Omit RemoveUserData; retain and compare owned project/support
bytes. Record a verified predecessor or leave upgrade evidence NotExecuted.
Use only a sacrificial captured owned target for destructive confirmation.
Prepare an exact-artifact unsigned tester handoff with honest limitations.

Copy only owned, sanitized witnesses beneath evidence. Update qualification.json
with actual facts, positive counts, file hashes, profile/backend identity and
independent build/source-CI/reviewer references. No credentials, environment,
foreign UI, raw command lines, private code, or synthetic session markers.
VerifyEvidence checks evidence completeness, NOT publication permission or
the truth of a human assertion. Coordinator review and USER release approval
remain separate. No cleanup command deletes retained data or recovery backups.
'@
  [IO.File]::WriteAllText((Resolve-PreviewCoreChild $root "FLIGHT.txt"), $instructions, [Text.UTF8Encoding]::new($false))
}

function Assert-PreviewCoreEvidence($reference, [string] $root, [switch] $RequirePng) {
  Assert-PreviewCoreHash $reference.sha256 64 "evidence SHA-256"
  $path = Resolve-PreviewCoreChild $root $reference.path
  Assert-PreviewCore ([IO.Path]::GetExtension($path) -in @(".txt", ".json", ".png")) "unsupported evidence file type"
  Assert-PreviewCore ((Get-PreviewCoreHash $path) -ceq $reference.sha256) "evidence digest mismatch"
  if ([IO.Path]::GetExtension($path) -eq ".png") {
    $stream = [IO.File]::OpenRead($path)
    try {
      $header = New-Object byte[] 8
      $read = $stream.Read($header, 0, 8)
      Assert-PreviewCore ($read -eq 8 -and [BitConverter]::ToString($header) -ceq "89-50-4E-47-0D-0A-1A-0A") "invalid owned PNG witness"
    } finally { $stream.Dispose() }
  } elseif ($RequirePng) {
    throw "PreviewCore: native observation requires an owned PNG pixel witness"
  }
}

function Assert-PreviewCoreObservation($observation, [string] $evidenceRoot) {
  Assert-PreviewCore ($observation.status -cin @("NotExecuted", "Failed", "Passed")) "invalid observation status"
  Assert-PreviewCore ($observation.status -ceq "Passed") "$($observation.id) is $($observation.status)"
  Assert-PreviewCore ((Test-PreviewCoreInteger $observation.count) -and
    $observation.count -gt 0) "positive integer observation count is required"
  $native = $observation.id -in @(
    "production-core", "actual-backend-terminal", "client-reachability", "stop-exit-reopen", "safe-mutations"
  )
  $method = if ($native) { "NativeManual" } else { "OwnedRuntime" }
  Assert-PreviewCore ($observation.method -ceq $method) "$($observation.id) requires $method evidence"
  Assert-PreviewCore (@($observation.evidence).Count -gt 0) "observation evidence is missing"
  $png = $false
  foreach ($reference in $observation.evidence) {
    Assert-PreviewCoreEvidence $reference $evidenceRoot
    if ([IO.Path]::GetExtension($reference.path) -eq ".png") { $png = $true }
  }
  Assert-PreviewCore (-not $native -or $png) "native observation requires an owned PNG pixel witness"
}

function Assert-PreviewCoreSavedGraph($reference, $packet, [string] $evidenceRoot) {
  Assert-PreviewCore ([IO.Path]::GetExtension($reference.path) -eq ".json") "persisted graph JSON readback is required"
  Assert-PreviewCoreEvidence $reference $evidenceRoot
  $graph = Get-Content -LiteralPath (Resolve-PreviewCoreChild $evidenceRoot $reference.path) -Raw | ConvertFrom-Json
  $nodes = @($graph.nodes)
  $project = (Resolve-PreviewCoreChild $packet.runRoot "project").Replace('\', '/')
  Assert-PreviewCore ($graph.project.path -ieq $project -and $nodes.Count -eq 1) "readback is not the one-loop owned project"
  $node = $nodes[0]
  Assert-PreviewCore ($node.id -ceq $packet.runtime.loopId -and $node.title -ceq "AlphaRenamed" -and
    $node.loopType -ceq "turnBased" -and $node.checkDescription -ceq "A-start-Z-end" -and
    $node.backend -ceq $packet.backend.kind) "actual persisted graph identity/configuration mismatch"
}

function Assert-PreviewCoreFacts($packet, [string] $evidenceRoot) {
  $loop = $packet.runtime.loopId
  foreach ($observation in $packet.observations) {
    $f = $observation.facts
    $checks = Get-PreviewCoreChecks $observation.id
    foreach ($name in $checks) { Assert-PreviewCoreTrue $f.$name "$($observation.id).$name" }
    switch ($observation.id) {
      "production-core" {
        Assert-PreviewCore ((Test-PreviewCoreInteger $f.createdCount) -and $f.createdCount -eq 1) "exactly one intended loop must be created"
        Assert-PreviewCore ($f.selectedLoopId -ceq $loop -and $f.persistedLoopId -ceq $loop) "core loop identity changed"
        Assert-PreviewCore ($f.graphTitle -ceq "AlphaRenamed" -and $f.sidebarTitle -ceq "AlphaRenamed" -and
          $f.checkDescription -ceq "A-start-Z-end" -and $f.cancelDraft -ceq "CancelMustNotPersist") "exact core edit/cancel sentinels are missing"
        Assert-PreviewCoreHash $f.cancelBeforeSha256 64 "cancel baseline digest"
        Assert-PreviewCore ($f.cancelAfterSha256 -ceq $f.cancelBeforeSha256) "editor cancellation mutated persisted configuration"
        Assert-PreviewCoreSavedGraph $f.readback $packet $evidenceRoot
      }
      "actual-backend-terminal" {
        Assert-PreviewCore ($f.loopId -ceq $loop -and $f.backendKind -ceq $packet.backend.kind -and
          $f.backendVersion -ceq $packet.backend.version) "actual backend/loop witness mismatch"
        Assert-PreviewCore ($f.input -ceq "Reply with FlightOutput2." -and
          $f.output1 -cmatch 'A-start-Z-end' -and $f.output1 -cmatch 'FlightOutput1' -and
          $f.output2 -ceq "FlightOutput2" -and $f.terminalMode -ceq "default") "actual default-terminal input/output markers are missing"
        Assert-PreviewCore ((Test-PreviewCoreInteger $f.agentTurns) -and $f.agentTurns -eq 2) "exactly two approved fixture turns are required"
      }
      "stop-exit-reopen" {
        Assert-PreviewCore ($f.stoppedLoopId -ceq $loop -and $f.reopenedLoopId -ceq $loop -and
          $f.reopenedTitle -ceq "AlphaRenamed" -and $f.reopenedCheckDescription -ceq "A-start-Z-end") "persisted reopen identity/configuration mismatch"
        Assert-PreviewCoreSavedGraph $f.readback $packet $evidenceRoot
      }
      "update-recovery-retention" {
        Assert-PreviewCoreHash $f.predecessorSha256 64 "verified predecessor package"
        Assert-PreviewCore ($f.predecessorSha256 -cne $packet.artifact.sha256) "same-package upgrade is only a supporting fragment"
        Assert-PreviewCoreText $f.predecessorVersion "predecessor version"
        Assert-PreviewCore ($f.predecessorVersion -cne $packet.artifact.version) "version-progression upgrade is missing"
        Assert-PreviewCoreHash $f.userDataBeforeSha256 64 "owned user-data baseline"
        Assert-PreviewCore ($f.userDataAfterSha256 -ceq $f.userDataBeforeSha256) "owned user data was not retained"
      }
      "safe-mutations" {
        Assert-PreviewCore ($f.sacrificialTarget -ceq "sacrificial-workspace") "destructive target must be the separate owned sacrificial fixture"
      }
    }
  }
}

function Assert-PreviewCoreFlight($packet, [string] $source, [string] $hash, [string] $evidenceRoot) {
  Assert-PreviewCore ((Test-PreviewCoreInteger $packet.schemaVersion) -and $packet.schemaVersion -eq 1 -and
    $packet.kind -ceq "PackagedProductionCore") "unsupported fixed-flight packet"
  Assert-PreviewCoreFalse $packet.testOnly "test-only evidence"
  Assert-PreviewCoreArtifact $packet.artifact $source $hash
  Assert-PreviewCore ($packet.runtime.daemon -ceq "Production" -and
    $packet.runtime.installation -ceq "ScheduledTask") "ordinary installed production daemon is required"
  Assert-PreviewCoreFalse $packet.runtime.seededModel "seeded model"
  Assert-PreviewCoreFalse $packet.runtime.testHooks "test hooks"
  Assert-PreviewCore ($packet.runtime.supportDirectory -ieq (Resolve-PreviewCoreChild $packet.runRoot "support") -and
    $packet.runtime.installDirectory -ieq (Resolve-PreviewCoreChild $packet.runRoot "install")) "runtime support/install roots are not the captured owned fixture"
  foreach ($name in @("shell", "daemon", "cli", "zmx")) {
    Assert-PreviewCore ($packet.runtime.installedHashes.$name -ceq $packet.artifact.hashes.$name) "installed $name digest mismatch"
  }
  Assert-PreviewCoreText $packet.runtime.endpoint "owned production endpoint"
  Assert-PreviewCore ($packet.runtime.loopId -cmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') "actual generated loop ID is missing"
  Assert-PreviewCore ($packet.runtime.sessionIdentity -cmatch '^([0-9a-fA-F]{32}|[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$') "actual backend session ID is missing; synthetic markers cannot qualify"
  Assert-PreviewCore ($packet.backend.kind -cin @("copilotCLI", "claudeCode", "codex")) "one supported actual backend is required"
  foreach ($name in @("version", "permissions", "model", "approval")) {
    Assert-PreviewCoreText $packet.backend.$name "backend $name"
  }
  Assert-PreviewCoreHash $packet.backend.executableSha256 64 "actual backend executable identity"
  $attended = if ($packet.backend.kind -ceq "claudeCode") { "manual" } else { "ask" }
  Assert-PreviewCore ($packet.backend.permissions -ceq $attended) "first flight requires attended backend permissions, not bypass/autopilot"
  Assert-PreviewCoreTrue $packet.backend.authenticationProvisionedInOwnedAccount "owned backend authentication approval"
  Assert-PreviewCore ($packet.profile.role -ceq "Client" -and $packet.profile.os -ceq "Windows 11" -and
    $packet.profile.architecture -ceq "x64") "hosted/server evidence cannot qualify the Windows 11 x64 client"
  Assert-PreviewCoreTrue $packet.profile.ownedAccountIsolationWitnessed "owned account/home/credential isolation"
  foreach ($name in @("build", "graphicsAdapter", "shellVersion", "nativeLease")) {
    Assert-PreviewCoreText $packet.profile.$name "client $name"
  }
  $minimum = $packet.profile.minimumViewportDip
  Assert-PreviewCore ((Test-PreviewCoreInteger $minimum.width) -and $minimum.width -gt 0 -and
    (Test-PreviewCoreInteger $minimum.height) -and $minimum.height -gt 0) "declared minimum viewport is missing"
  $profiles = @($packet.profile.observations)
  Assert-PreviewCore ($profiles.Count -eq 2 -and (@($profiles.scale | Sort-Object) -join ',') -ceq "100,150") "actual 100% and 150% client profiles are required"
  foreach ($profile in $profiles) {
    Assert-PreviewCore ((Test-PreviewCoreInteger $profile.scale) -and (Test-PreviewCoreInteger $profile.viewportWidthDip) -and
      (Test-PreviewCoreInteger $profile.viewportHeightDip) -and $profile.viewportWidthDip -eq $minimum.width -and
      $profile.viewportHeightDip -eq $minimum.height) "minimum viewport was not witnessed"
    Assert-PreviewCoreText $profile.workArea "actual display work area"
    Assert-PreviewCoreEvidence $profile.pixels $evidenceRoot -RequirePng
  }
  $observations = @($packet.observations)
  Assert-PreviewCoreCoverage $observations
  foreach ($observation in $observations) { Assert-PreviewCoreObservation $observation $evidenceRoot }
  Assert-PreviewCoreFacts $packet $evidenceRoot
  Assert-PreviewCoreText $packet.custody.reviewer "coordinator reviewer"
  Assert-PreviewCoreTrue $packet.custody.accepted "coordinator evidence acceptance"
  Assert-PreviewCoreTrue $packet.custody.reviewedEvidenceIsOwnedAndSanitized "owned sanitized evidence review"
  Assert-PreviewCoreTrue $packet.custody.allRequiredSourceChecksPassed "all required checks at the exact source"
  Assert-PreviewCoreEvidence $packet.custody.build $evidenceRoot
  $tools = $packet.custody.toolchains
  Assert-PreviewCore ($tools.swift -ceq "6.3.3" -and $tools.zigShell -ceq "0.15.2" -and
    $tools.zigZmx -ceq "0.16.0") "actual pinned build toolchain witness is missing"
  Assert-PreviewCoreText $tools.sdk "actual pinned SDK"
  Assert-PreviewCoreText $tools.msvc "actual MSVC"
  $jobs = @($packet.custody.sourceCI)
  $requiredJobs = @(Get-PreviewCoreCiJobs)
  Assert-PreviewCore ($jobs.Count -eq $requiredJobs.Count -and
    (($jobs.job | Sort-Object) -join ',') -ceq (($requiredJobs | Sort-Object) -join ',')) "executed required Windows CI parts are missing or duplicated"
  foreach ($job in $jobs) {
    Assert-PreviewCore ($job.headSha -ceq $source -and $job.conclusion -ceq "success") "source CI failed or used a different head"
    Assert-PreviewCoreTrue $job.executed "source CI execution (not skipped)"
    Assert-PreviewCore ((Test-PreviewCoreInteger $job.executedCases) -and $job.executedCases -gt 0) "source CI requires positive executed counts"
    Assert-PreviewCore ($job.url -cmatch '^https://github\.com/scgopi/GraphCode/actions/runs/[0-9]+$') "source CI run identity is missing"
    Assert-PreviewCoreText $job.job "source CI job"
    Assert-PreviewCoreEvidence $job.evidence $evidenceRoot
    if ($job.job -ceq "windows-shell packaging contracts") {
      Assert-PreviewCore ((Test-PreviewCoreInteger $job.previewCoreExecutedCases) -and $job.previewCoreExecutedCases -gt 0) "new PreviewCore contracts were not actually executed in CI"
    }
  }
}

function Invoke-PreviewCorePackageVerification([string] $path, [string] $root) {
  $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\..\.."))
  $oldTemp = $env:TEMP
  $oldTmp = $env:TMP
  try {
    $env:TEMP = Resolve-PreviewCoreChild $root "temp"
    $env:TMP = $env:TEMP
    $verification = @(& (Join-Path $repo "Tools\windows\package.ps1") -Command Verify -Package $path)
    Assert-PreviewCore (@($verification | Where-Object { $_ -ceq "Package verification: PASS" }).Count -eq 1) "existing package verifier did not report one exact success"
  } finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
  }
}

function Invoke-PreviewCorePrepare([string] $archive, [string] $source, [string] $hash, [string] $root) {
  Assert-PreviewCoreHash $source 40 "expected source SHA"
  Assert-PreviewCoreHash $hash 64 "expected ZIP SHA-256"
  Assert-PreviewCore ([IO.Path]::GetExtension($archive) -eq ".zip") "a selected ZIP is required"
  Assert-PreviewCore ((Get-PreviewCoreHash $archive) -ceq $hash) "ZIP hash mismatch"
  Assert-PreviewCoreRunRoot $root
  $root = [IO.Path]::GetFullPath($root)
  Assert-PreviewCore (-not (Test-Path -LiteralPath $root)) "run root already exists; refusing to adopt state"
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  Write-PreviewCoreFixture $root
  $ownedZip = Resolve-PreviewCoreChild $root "candidate.zip"
  Copy-Item -LiteralPath $archive -Destination $ownedZip
  Assert-PreviewCore ((Get-PreviewCoreHash $ownedZip) -ceq $hash) "copied ZIP hash mismatch"
  Invoke-PreviewCorePackageVerification $ownedZip $root
  $extraction = Resolve-PreviewCoreChild $root "package"
  Expand-Archive -LiteralPath $ownedZip -DestinationPath $extraction
  $artifact = Get-PreviewCoreArtifact (Resolve-PreviewCoreChild $extraction "GraphCode") $source $hash
  $scriptHash = Get-PreviewCoreHash $PSCommandPath
  $packet = New-PreviewCorePacket $artifact $root $scriptHash
  $json = $packet | ConvertTo-Json -Depth 20
  foreach ($name in @("prepared.json", "qualification.json")) {
    [IO.File]::WriteAllText((Resolve-PreviewCoreChild $root $name), $json, [Text.UTF8Encoding]::new($false))
  }
  $owner = [ordered]@{
    flightId = $packet.flightId; sourceCommit = $source; zipSha256 = $hash
    scriptSha256 = $scriptHash
    preparedSha256 = Get-PreviewCoreHash (Resolve-PreviewCoreChild $root "prepared.json")
    projectSha256 = Get-PreviewCoreHash (Resolve-PreviewCoreChild $root "project\alpha.txt")
  }
  [IO.File]::WriteAllText((Resolve-PreviewCoreChild $root "owner.json"),
    ($owner | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Output "PREPARED_NOT_QUALIFIED: 9 flight observations NotExecuted; no application/backend/native/installer execution"
  Write-Output (Resolve-PreviewCoreChild $root "qualification.json")
}

function Invoke-PreviewCoreVerify([string] $path, [string] $source, [string] $hash) {
  Assert-PreviewCorePath $path
  $root = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($path))
  Assert-PreviewCoreRunRoot $root
  Assert-PreviewCore ([IO.Path]::GetFileName($path) -ceq "qualification.json") "use the owned qualification.json packet"
  $owner = Get-Content -LiteralPath (Resolve-PreviewCoreChild $root "owner.json") -Raw | ConvertFrom-Json
  $preparedPath = Resolve-PreviewCoreChild $root "prepared.json"
  Assert-PreviewCore ((Get-PreviewCoreHash $preparedPath) -ceq $owner.preparedSha256) "prepared packet was modified"
  Assert-PreviewCore ($owner.sourceCommit -ceq $source -and $owner.zipSha256 -ceq $hash -and
    $owner.scriptSha256 -ceq (Get-PreviewCoreHash $PSCommandPath)) "prepared source/package/checker custody mismatch"
  Assert-PreviewCore ((Get-PreviewCoreHash (Resolve-PreviewCoreChild $root "project\alpha.txt")) -ceq
    $owner.projectSha256) "owned project baseline changed"
  $packet = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
  $prepared = Get-Content -LiteralPath $preparedPath -Raw | ConvertFrom-Json
  Assert-PreviewCore ($packet.flightId -ceq $owner.flightId -and $packet.runRoot -ceq $root -and
    $packet.qualificationScriptSha256 -ceq $owner.scriptSha256) "packet belongs to a different flight/checker"
  Assert-PreviewCore (($packet.artifact | ConvertTo-Json -Depth 10 -Compress) -ceq
    ($prepared.artifact | ConvertTo-Json -Depth 10 -Compress)) "prepared artifact identity changed"
  Assert-PreviewCoreFlight $packet $source $hash (Resolve-PreviewCoreChild $root "evidence")
  $ownedZip = Resolve-PreviewCoreChild $root "candidate.zip"
  Assert-PreviewCore ((Get-PreviewCoreHash $ownedZip) -ceq $hash) "retained candidate ZIP hash mismatch"
  Invoke-PreviewCorePackageVerification $ownedZip $root
  $actualArtifact = Get-PreviewCoreArtifact (Resolve-PreviewCoreChild $root "package\GraphCode") $source $hash
  Assert-PreviewCore (($actualArtifact | ConvertTo-Json -Depth 10 -Compress) -ceq
    ($prepared.artifact | ConvertTo-Json -Depth 10 -Compress)) "retained packaged payload changed"
  Write-Output "EVIDENCE_COMPLETE: reviewed fixed-flight packet; not publication permission or independent proof of human assertions"
}

if ($HelpersOnly) { return }
switch ($Command) {
  "Prepare" { Invoke-PreviewCorePrepare $Package $ExpectedSource $ExpectedSha256 $RunRoot }
  "VerifyEvidence" { Invoke-PreviewCoreVerify $EvidencePath $ExpectedSource $ExpectedSha256 }
  default { throw "PreviewCore: specify Prepare or VerifyEvidence; live execution is not supported" }
}
