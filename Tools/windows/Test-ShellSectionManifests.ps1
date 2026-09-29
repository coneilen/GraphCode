[CmdletBinding()]
param(
  # Directory holding one WindowsShell.Tests.ps1 section manifest per shard.
  [Parameter(Mandatory)] [string] $Directory,
  [Parameter(Mandatory)] [int] $ShardCount
)

# Aggregate gate for the sharded Windows shell unit sections. Every shard must
# report the same derived catalog, the shards together must execute every
# catalog section exactly once, and each executed section must have reported a
# positive passed count for every `zig test` it contains.
$ErrorActionPreference = "Stop"

function Fail([string] $message) { throw "Windows shell section coverage: $message" }

$files = @(Get-ChildItem -LiteralPath $Directory -Filter "*.json" -File -Recurse)
if ($files.Count -ne $ShardCount) {
  Fail "expected $ShardCount shard manifests, found $($files.Count)"
}
$manifests = @($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
$catalog = @($manifests[0].catalog)
if ($catalog.Count -eq 0) { Fail "the catalog is empty" }
$seenShards = @{}
$executedBy = @{}
foreach ($manifest in $manifests) {
  if ($manifest.schemaVersion -ne 1) { Fail "unsupported manifest schema $($manifest.schemaVersion)" }
  if ($manifest.shardCount -ne $ShardCount) {
    Fail "shard $($manifest.shard) was planned for $($manifest.shardCount) shards, not $ShardCount"
  }
  if ($seenShards.ContainsKey([int]$manifest.shard)) { Fail "shard $($manifest.shard) reported twice" }
  $seenShards[[int]$manifest.shard] = $true
  if ((@($manifest.catalog) -join "`n") -cne ($catalog -join "`n")) {
    Fail "shard $($manifest.shard) derived a different section catalog"
  }
  $executed = @($manifest.executed)
  if ((@($executed | ForEach-Object { $_.name }) -join "`n") -cne (@($manifest.assigned) -join "`n")) {
    Fail "shard $($manifest.shard) did not execute exactly its assigned sections"
  }
  foreach ($section in $executed) {
    if ($catalog -cnotcontains $section.name) { Fail "shard $($manifest.shard) ran unknown section '$($section.name)'" }
    if ($executedBy.ContainsKey($section.name)) {
      Fail "section '$($section.name)' ran in shards $($executedBy[$section.name]) and $($manifest.shard)"
    }
    if ([int]$section.positiveSummaries -lt [int]$section.zigTestInvocations) {
      Fail "section '$($section.name)' reported $($section.positiveSummaries) positive summaries for $($section.zigTestInvocations) zig test invocations"
    }
    $executedBy[$section.name] = [int]$manifest.shard
  }
}
for ($index = 0; $index -lt $ShardCount; $index++) {
  if (-not $seenShards.ContainsKey($index)) { Fail "shard $index did not report" }
}
$missing = @($catalog | Where-Object { -not $executedBy.ContainsKey($_) })
if ($missing.Count -ne 0) { Fail "no shard executed: $($missing -join ', ')" }
$seconds = foreach ($manifest in $manifests | Sort-Object shard) {
  $total = (@($manifest.executed) | Measure-Object -Property seconds -Sum).Sum
  "shard $($manifest.shard): $(@($manifest.executed).Count) sections, $([Math]::Round($total))s"
}
Write-Output "Windows shell section coverage: PASS ($($catalog.Count) sections across $ShardCount shards; $($seconds -join '; '))"
