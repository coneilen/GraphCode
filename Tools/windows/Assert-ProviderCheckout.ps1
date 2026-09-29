[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $ProviderRoot
)

# Restored CI caches must never substitute a stale provider: every provider
# checkout has to be exactly its pinned commit and clean (build outputs are
# ignored by the providers, so a restored cache cannot hide tracked edits).
$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$pins = Get-Content -LiteralPath (Join-Path $repoRoot "graphcode-windows\provider-pins.json") -Raw |
  ConvertFrom-Json
foreach ($name in @("winghostty", "zmx")) {
  $root = Join-Path $ProviderRoot $name
  if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
    throw "$name provider is not a Git checkout: $root"
  }
  $actual = git -C $root rev-parse HEAD
  if ($LASTEXITCODE -ne 0 -or $actual -ne $pins.$name.sha) {
    throw "$name provider is at $actual, but provider-pins.json pins $($pins.$name.sha)"
  }
  $status = @(git -C $root status --porcelain --untracked-files=all)
  if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw "$name provider checkout is dirty after cache restore"
  }
  Write-Output "$name provider verified at pinned $actual"
}
