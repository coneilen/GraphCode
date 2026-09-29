[CmdletBinding()]
param(
  # The workflow's `toJSON(needs)` for the aggregate job.
  [Parameter(Mandatory)] [string] $NeedsJson,
  # "true" when the path classifier (or a non-pull-request event) requires the
  # Windows suites for this run.
  [Parameter(Mandatory)] [string] $Required
)

# Aggregate gate for a required check that is split into parallel parts. When
# the suite is required, every part must have succeeded; a skipped, failed, or
# cancelled part fails the gate. When the classifier legitimately skipped the
# whole suite, the parts must all be skipped and the gate passes.
$ErrorActionPreference = "Stop"
$needs = $NeedsJson | ConvertFrom-Json
$parts = @($needs.PSObject.Properties | Where-Object Name -ne "changes")
if ($parts.Count -eq 0) { throw "The aggregate gate has no parts to check" }
foreach ($part in $parts) { Write-Output "$($part.Name): $($part.Value.result)" }
if ($Required -eq "true") {
  $unsuccessful = @($parts | Where-Object { $_.Value.result -ne "success" })
  if ($unsuccessful.Count -ne 0) {
    throw "Required parts did not succeed: $(($unsuccessful | ForEach-Object { "$($_.Name)=$($_.Value.result)" }) -join ', ')"
  }
  Write-Output "All $($parts.Count) required parts succeeded."
  exit 0
}
if ($Required -ne "false") { throw "Unexpected requirement value '$Required'" }
if ($needs.changes.result -ne "success") {
  throw "The path classifier did not succeed, so the suite cannot be treated as skipped"
}
$ran = @($parts | Where-Object { $_.Value.result -ne "skipped" })
if ($ran.Count -ne 0) {
  throw "Parts ran although the classifier skipped the suite: $(($ran | ForEach-Object { "$($_.Name)=$($_.Value.result)" }) -join ', ')"
}
Write-Output "No Windows-relevant paths changed; every part was skipped by the path classifier."
