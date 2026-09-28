$ErrorActionPreference = "Stop"

function Assert-ShellHostPrerequisite([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Validation driver does not parse" }
  $clauses = @($ast.FindAll({
      param($node)
      $node -is [Management.Automation.Language.SwitchStatementAst]
    }, $true).Clauses | Where-Object { $_.Item1.Value -eq "windows-shell" })
  if ($clauses.Count -ne 1) { throw "Expected one windows-shell validation branch" }
  $body = $clauses[0].Item2
  $commands = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.CommandAst]
    }, $true))
  $build = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned Winghostty host build for App contracts"'
    })
  $contracts = @($commands | Where-Object {
      $_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -and
        $_.CommandElements[0].Extent.Text -match 'Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1'
    })
  $smoke = @($commands | Where-Object {
      $_.GetCommandName() -eq "Invoke-Native" -and
        $_.CommandElements[1].Extent.Text -eq '"Pinned GraphCode Windows shell build and smoke"'
    })
  $guards = @($body.FindAll({
      param($node)
      $node -is [Management.Automation.Language.IfStatementAst]
    }, $true))
  $pin = @($guards | Where-Object { $_.Extent.Text -match '\$actualWinghosttyPin -ne \$pins\.winghostty\.sha' })
  $clean = @($guards | Where-Object { $_.Extent.Text -match '\$providerStatus\.Count -ne 0' })
  $library = @($guards | Where-Object { $_.Extent.Text -match 'Test-Path -LiteralPath \$winghosttyLib -PathType Leaf' })
  foreach ($stage in @(@{ Values = $build }, @{ Values = $contracts }, @{ Values = $smoke },
      @{ Values = $pin }, @{ Values = $clean }, @{ Values = $library })) {
    if ($stage.Values.Count -ne 1) { throw "Missing or repeated App host prerequisite stage" }
  }
  if ($clean[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $pin[0].Extent.EndOffset -ge $build[0].Extent.StartOffset -or
      $build[0].Extent.EndOffset -ge $library[0].Extent.StartOffset -or
      $library[0].Extent.EndOffset -ge $contracts[0].Extent.StartOffset -or
      $contracts[0].Extent.EndOffset -ge $smoke[0].Extent.StartOffset -or
      $build[0].Extent.Text -notmatch '(?s)Push-Location \$winghosttyRoot.*& \$zig0152 build -Demit-win32-host=true.*finally \{ Pop-Location \}') {
    throw "Pinned host validation/build must precede App contracts, which must precede live smoke"
  }
}

function Test-ZigResolverDiagnostics([string] $source) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
  if ($errors.Count -ne 0) { throw "Resolver source does not parse" }
  foreach ($name in @("Invoke-ZigResolverProbe", "Write-ZigResolverDiagnostic", "Resolve-ZigVersion")) {
    $definition = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
      }, $true)
    if ($null -eq $definition) { throw "Missing actual resolver helper: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
  }
  function Assert-Resolver([bool] $condition, [string] $message) {
    if (-not $condition) { throw "Zig diagnostic contract: $message" }
  }
  $environmentName = "GRAPHCODE_ZIG_RESOLVER_TEST"
  $priorEnvironment = [Environment]::GetEnvironmentVariable($environmentName)
  $priorExit = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
  $priorExitValue = if ($null -ne $priorExit) { $priorExit.Value } else { $null }
  try {
    function InMemoryZigProbe([string] $operation) {
      if ($operation -eq "throw") { throw [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY") }
      $global:LASTEXITCODE = -1073741502
      Write-Output "0.15.2"
      Write-Error "ghp_PRIVATE_CANARY" -ErrorAction Continue
    }
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "version"
    Assert-Resolver ($probe.Output -ceq "0.15.2" -and $probe.ExitCode -eq -1073741502) "actual probe lost stdout or native exit"
    Assert-Resolver ($probe.ErrorText -match "ghp_PRIVATE_CANARY" -and $null -eq $probe.Failure) "actual probe did not separate stderr"
    $probe = Invoke-ZigResolverProbe "InMemoryZigProbe" "throw"
    Assert-Resolver ($null -eq $probe.ExitCode -and $null -ne $probe.Failure) "launch failure reused stale LASTEXITCODE"

    $a = "C:\fixture\configured\zig.exe"
    $b = "C:\fixture\path\zig.exe"
    $c = "C:\fixture\discovered\zig.exe"
    $repoRoot = "C:\fixture\repo"
    $state = @{
      PathCandidate = $b; Discovered = @($c); Exists = @{}; Probes = @{}
      Calls = [Collections.Generic.List[string]]::new()
      Diagnostics = [Collections.Generic.List[string]]::new()
      Warnings = [Collections.Generic.List[string]]::new()
      WriterFails = $false
      WarningFails = $false
    }
    function Get-Command($Name, $ErrorAction) { [pscustomobject]@{ Source = $state.PathCandidate } }
    function Get-ChildItem($Path, [switch] $Recurse, $Filter, [switch] $File, $ErrorAction) {
      foreach ($entry in $state.Discovered) { [pscustomobject]@{ FullName = $entry } }
    }
    function Test-Path($LiteralPath, $PathType, $ErrorAction) { $state.Exists[$LiteralPath] -eq $true }
    function Resolve-Path($LiteralPath) { [pscustomobject]@{ Path = $LiteralPath } }
    function Invoke-ZigResolverProbe([string] $candidate, [string] $operation) {
      $key = "$candidate|$operation"
      $state.Calls.Add($key)
      if (-not $state.Probes.ContainsKey($key)) { throw "Unplanned in-memory probe" }
      $state.Probes[$key]
    }
    function Write-Host($Object) {
      if ($state.WriterFails) { throw "ghp_PRIVATE_CANARY" }
      $state.Diagnostics.Add([string]$Object)
    }
    function Write-Warning($Message, $WarningAction) {
      $state.Warnings.Add([string]$Message)
      if ($state.WarningFails) { throw "ghp_PRIVATE_CANARY" }
    }
    function New-Probe($output, $exitCode = 0, $stderr = "") {
      [pscustomobject]@{ Output = $output; ExitCode = $exitCode; ErrorText = $stderr; Failure = $null }
    }
    function Reset-ResolverCase {
      $state.Calls.Clear(); $state.Diagnostics.Clear(); $state.Warnings.Clear()
      $state.WriterFails = $false
      $state.WarningFails = $false
      $state.PathCandidate = $b
      $state.Discovered = @($a, $c)
      $state.Exists = @{ $a = $true; $b = $true; $c = $true }
      $state.Probes = @{}
      foreach ($candidate in @($a, $b, $c)) {
        $state.Probes["$candidate|version"] = New-Probe "0.15.2"
        $state.Probes["$candidate|env"] = New-Probe '{"version":"0.15.2","lib_dir":"C:\\fixture\\lib"}'
      }
      [Environment]::SetEnvironmentVariable($environmentName, $a)
    }
    function Invoke-ResolverCase {
      $result = @()
      $failure = $null
      try { $result = @(Resolve-ZigVersion "0.15.2" $environmentName) } catch { $failure = $_ }
      [pscustomobject]@{ Result = $result; Failure = $failure }
    }
    function Read-Diagnostic([int] $index = 0) {
      $line = $state.Diagnostics[$index]
      Assert-Resolver ($line.StartsWith("ZIG_RESOLVER_DIAGNOSTIC ") -and $line.Length -lt 2500) "diagnostic tag or bound"
      Assert-Resolver ($line -notmatch "ghp_PRIVATE_CANARY|userinfo|GITHUB_TOKEN") "secret canary escaped diagnostic"
      $line.Substring("ZIG_RESOLVER_DIAGNOSTIC ".Length) | ConvertFrom-Json
    }

    Reset-ResolverCase
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $a -and $null -eq $case.Failure) "success return changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$a|env" -and $state.Diagnostics.Count -eq 0) "success probes repeated or diagnosed"
    Reset-ResolverCase
    $state.Exists[$a] = $false
    $state.Probes["$b|version"] = New-Probe "0.16.0"
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $c) "fallback selection changed"
    Assert-Resolver (($state.Calls -join ",") -ceq "$b|version,$c|version,$c|env") "fallback order/deduplication/env skipping changed"
    $missing = Read-Diagnostic
    $mismatch = Read-Diagnostic 1
    Assert-Resolver (-not $missing.exists -and $null -eq $missing.version -and $missing.source -eq "configured") "missing candidate fabricated probe"
    Assert-Resolver ($mismatch.source -eq "PATH" -and $mismatch.version.observedVersion -eq "0.16.0" -and $null -eq $mismatch.env) "mismatch evidence wrong"

    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "ghp_PRIVATE_CANARY" -1073741502 "ghp_PRIVATE_CANARY"
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.version.exitCodeHex -eq "0xC0000142") "nonzero exit/fallback changed"
    Assert-Resolver ($null -eq $diagnostic.version.observedVersion -and $diagnostic.version.stderr.reason -eq "unclassified") "unsafe version or stderr surfaced"
    foreach ($envText in @("invalid ghp_PRIVATE_CANARY", '{"version":"0.15.2","lib_dir":"C:\\fixture\\absent","env":{"GITHUB_TOKEN":"ghp_PRIVATE_CANARY"}}')) {
      Reset-ResolverCase
      $state.Probes["$a|env"] = New-Probe $envText 9 "error: unable to find zig installation directory ghp_PRIVATE_CANARY"
      $case = Invoke-ResolverCase
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($case.Result[0] -ceq $b -and $diagnostic.reason -eq "env-exit" -and $diagnostic.env.exitCode -eq 9) "env failure selection changed"
      Assert-Resolver ($diagnostic.env.stderr.reason -eq "unable to find zig installation directory") "safe known reason missing"
      if ($envText.StartsWith("{")) {
        Assert-Resolver ($diagnostic.env.parse -eq "parsed" -and $diagnostic.env.libDirectoryPresent -eq $false) "library metadata missing"
      } else {
        Assert-Resolver ($diagnostic.env.parse -eq "metadata-unavailable") "parse metadata missing"
      }
      $state.Probes["$a|env"] = New-Probe $envText
      $state.Diagnostics.Clear()
      $case = Invoke-ResolverCase
      Assert-Resolver ($case.Result[0] -ceq $a -and $state.Diagnostics.Count -eq 0) "new JSON/lib gate was introduced"
    }

    Reset-ResolverCase
    $failure = [Management.Automation.ErrorRecord]::new(
      [Management.Automation.RuntimeException]::new("ghp_PRIVATE_CANARY",
        [ComponentModel.Win32Exception]::new(5, "ghp_PRIVATE_CANARY")),
      "Launch", [Management.Automation.ErrorCategory]::OpenError, $null)
    $state.Probes["$a|version"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 1 -and $case.Failure.ToString() -notmatch "ghp_PRIVATE_CANARY") "exception changed stop behavior or exposed secret"
    Assert-Resolver ($null -eq $diagnostic.version.exitCode -and $diagnostic.version.nativeErrorCode -eq 5) "exception fabricated exit"
    Reset-ResolverCase
    $state.Probes["$a|env"] = [pscustomobject]@{ Output = $null; ExitCode = $null; ErrorText = ""; Failure = $failure }
    $case = Invoke-ResolverCase
    $diagnostic = Read-Diagnostic
    Assert-Resolver ($null -ne $case.Failure -and $state.Calls.Count -eq 2 -and $diagnostic.reason -eq "env-exception") "env exception did not stop after one probe"
    Assert-Resolver ($null -eq $diagnostic.env.exitCode -and $diagnostic.env.nativeErrorCode -eq 5) "env exception lost nullable exit/native code"
    Reset-ResolverCase
    $state.Probes["$a|version"] = New-Probe "0.16.0"
    $state.WriterFails = $true
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result[0] -ceq $b -and $state.Warnings.Count -eq 1) "writer failure changed fallback"
    $state.WarningFails = $true
    $state.Calls.Clear()
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 1 -and $case.Result[0] -ceq $b -and $null -eq $case.Failure) "both writer failures changed fallback"
    Assert-Resolver (($state.Calls -join ",") -ceq "$a|version,$b|version,$b|env") "both writer failures changed probe order"
    foreach ($candidate in @($a, $b, $c)) { $state.Exists[$candidate] = $false }
    $case = Invoke-ResolverCase
    Assert-Resolver ($case.Result.Count -eq 0 -and $case.Failure.ToString() -eq "Zig 0.15.2 is required for the pinned Windows provider; set $environmentName.") "both writer failures masked original guard"

    Reset-ResolverCase
    $nonAsciiVersion = ([string][char]0x0661) + ".2.3"
    $overLimitVersion = "1.2.3+" + ("a" * 65)
    foreach ($unsafeVersion in @($nonAsciiVersion, $overLimitVersion)) {
      foreach ($probeName in @("version", "env")) {
        $state.Diagnostics.Clear()
        $text = if ($probeName -eq "version") { $unsafeVersion } else { @{ version = $unsafeVersion } | ConvertTo-Json -Compress }
        $probe = New-Probe $text 1
        if ($probeName -eq "version") {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "version-exit" $probe $null
        } else {
          Write-ZigResolverDiagnostic $a "configured" "0.15.2" $true "env-exit" (New-Probe "0.15.2") $probe
        }
        $diagnostic = Read-Diagnostic
        $summary = $diagnostic.$probeName
        Assert-Resolver ($null -eq $summary.observedVersion -and
          $summary.stdout.bytes -eq [Text.Encoding]::UTF8.GetByteCount($text) -and
          $summary.stdout.sha256.Length -eq 64) "non-ASCII or over-limit version was not reduced to hash/length"
        Assert-Resolver (-not $state.Diagnostics[0].Contains($unsafeVersion)) "unsafe version appeared literally"
      }
    }
    Assert-Resolver ([Text.Encoding]::UTF8.GetByteCount($overLimitVersion) -gt 64) "version size control is not over limit"
    $state.WriterFails = $false
    foreach ($candidate in @("https://userinfo@github.com/zig", "C:\ghp_PRIVATE_CANARY\zig.exe", ("C:\" + ("x" * 520)))) {
      $state.Diagnostics.Clear()
      Write-ZigResolverDiagnostic $candidate "configured" "0.15.2" $true "version-exit" (New-Probe ("ghp_PRIVATE_CANARY" * 2000) 1) $null
      $diagnostic = Read-Diagnostic
      Assert-Resolver ($diagnostic.candidate -eq "[omitted]" -and $diagnostic.version.stdout.bytes -gt 16384) "candidate/output cap or redaction failed"
    }
  } finally {
    [Environment]::SetEnvironmentVariable($environmentName, $priorEnvironment)
    if ($null -eq $priorExit) { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    else { $global:LASTEXITCODE = $priorExitValue }
  }
}

$runner = Join-Path $PSScriptRoot "..\validate.ps1"
if (-not (Test-Path $runner)) {
  throw "RED: validation runner does not exist at $runner"
}

$tasks = & $runner -List
$expected = @(
  "swift-portable",
  "swift-contracts",
  "swift-production",
  "swift-paths",
  "swift-process",
  "swift-named-pipe",
  "remote-bridge",
  "remote-e2e",
  "swift-format",
  "visual-baseline",
  "tdd-evidence",
  "privacy",
  "terminal-gate",
  "windows-shell",
  "packaging",
  "hardening"
)
foreach ($task in $expected) {
  if ($tasks -notcontains $task) {
    throw "Validation task '$task' is missing"
  }
}

$dryRun = & $runner -Task swift-paths -DryRun
if ($LASTEXITCODE -ne 0) {
  throw "Dry run failed with exit code $LASTEXITCODE"
}
if (($dryRun -join "`n") -notmatch "swift-paths") {
  throw "Dry run did not name the selected task"
}

$pwsh = (Get-Process -Id $PID).Path
& $pwsh -NoProfile -File $runner -Task not-a-task *> $null
if ($LASTEXITCODE -eq 0) {
  throw "An unknown validation task succeeded"
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$untrackedDirectory = Join-Path $repoRoot "investigation\spikes\validation-runner-untracked"
New-Item -ItemType Directory -Force $untrackedDirectory | Out-Null
try {
  "let value=1" | Set-Content (Join-Path $untrackedDirectory "Unformatted.swift")
  & $pwsh -NoProfile -File $runner -Task swift-format *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "An unformatted untracked Swift source was ignored"
  }
} finally {
  Remove-Item -LiteralPath $untrackedDirectory -Recurse -Force
}

$foreignJunction = Join-Path $repoRoot `
  "investigation\spikes\swift-contracts\Sources\GraphcodeWindowsContracts\OwnershipSentinel"
New-Item -ItemType Directory -Force $foreignJunction | Out-Null
try {
  & $runner -Task swift-format -DryRun *> $null
  if (-not (Test-Path $foreignJunction)) {
    throw "A validation task removed resources owned by another task"
  }

  $windowsWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-hardening.yml") -Raw
  if ($windowsWorkflow -notmatch "(?s)full-pinned:.*bootstrap\.ps1.*validate\.ps1 -Task all.*Hardening\.Tests\.ps1 -Environment") {
    throw "RED: full-pinned Windows CI does not run real hardening after provider setup"
  }
  if ($windowsWorkflow -notmatch "GRAPHCODE_HARDENING_TARGET") {
    throw "RED: full-pinned Windows CI does not provide an owned environment harness"
  }
  $hardeningSource = Get-Content (Join-Path $PSScriptRoot "Hardening.Tests.ps1") -Raw
  foreach ($stage in @("real zmx/ConPTY terminal matrix", "real GraphCode shell matrix")) {
    if ($hardeningSource -notmatch ([regex]::Escape($stage) + ' failed \(exit=\$LASTEXITCODE; hex=')) {
      throw "Hardening stage failure omits the native exit code: $stage"
    }
  }
  & {
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput(
      $hardeningSource, [ref]$tokens, [ref]$errors)
    foreach ($name in @("Find-Bytes", "Get-HighOutputDiagnostics", "Get-HighOutputPayloadText")) {
      $function = $ast.Find({
          param($node)
          $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true)
      if (-not $function) { throw "RED: high-output diagnostics helper is missing: $name" }
      . ([scriptblock]::Create($function.Extent.Text))
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("START" + ("A" * 1024) + "END")
    $diagnostics = Get-HighOutputDiagnostics $bytes "START" "END"
    if ($diagnostics.capturedBytes -ne $bytes.Length -or
        $diagnostics.startOffset -ne 0 -or $diagnostics.endOffset -ne 1029 -or
        $diagnostics.prefix.Length -ne 512 -or $diagnostics.suffix.Length -ne 512) {
      throw "High-output diagnostics lost marker positions or exceeded transcript bounds"
    }
    $partial = Get-HighOutputDiagnostics ([Text.Encoding]::ASCII.GetBytes("END")) "START" "END"
    if ($partial.startOffset -ne -1 -or $partial.endOffset -ne 0) {
      throw "High-output diagnostics hide an end marker when the start marker is missing"
    }
    $empty = Get-HighOutputDiagnostics ([byte[]]::new(0)) "START" "END"
    if ($empty.capturedBytes -ne 0 -or $empty.startOffset -ne -1 -or
        $empty.endOffset -ne -1 -or $empty.prefix -ne "" -or $empty.suffix -ne "") {
      throw "High-output diagnostics cannot report an empty capture"
    }
    $escape = [string][char]27
    $captures = @(
      "STARTAAAAEND",
      "ST${escape}[0mARTAA${escape}[31mAAEN${escape}[0mD",
      "STA`r`nRTAAAAE`r`nND",
      "START${escape}]0;END$([char]7)AAAAEND",
      "ST${escape}]0;title${escape}\ARTAAAAEND",
      "${escape}]0;before${escape}\STARTAAAAEND${escape}]0;after${escape}\"
    )
    foreach ($capture in $captures) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($payload -cne "AAAA") {
        throw "RED: high-output completion must survive terminal framing inside markers"
      }
    }
    foreach ($capture in @("", "STARTAAAA", "AAAAEND", "ENDSTARTAAAA",
        "${escape}]0;STARTAAAAEND")) {
      $payload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes($capture)) "START" "END"
      if ($null -ne $payload) { throw "Incomplete or reversed output markers were accepted" }
    }
    $emptyPayload = Get-HighOutputPayloadText ([Text.Encoding]::ASCII.GetBytes("STARTEND")) "START" "END"
    if ($null -eq $emptyPayload -or $emptyPayload -cne "") {
      throw "Empty completed output must reach the length/hash checks, not look pending"
    }
  }
  if ($hardeningSource -notmatch
      '(?s)if \(-not \$completed\).*?Get-HighOutputDiagnostics.*?HARDENING_OUTPUT_DIAGNOSTICS_JSON=.*?Assert-True \$completed') {
    throw "RED: real high-output failure omits bounded transcript diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)if \(\$LASTEXITCODE -ne 0\) \{\s*\$output \| Write-Output\s*throw "hardening repeated run') {
    throw "RED: failed repeated hardening discards its child diagnostics"
  }
  if ($hardeningSource -notmatch
      '(?s)\$shellVersion\s*=\s*\(& \$shell --version.*?-Version \$shellVersion') {
    throw "RED: post-release hardening does not preserve the built shell version"
  }
  $windowsShellWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\windows-shell.yml") -Raw
  $windowsPortWorkflow = Get-Content `
    (Join-Path $repoRoot ".github\workflows\windows-port-validation.yml") -Raw
  foreach ($workflow in @($windowsWorkflow, $windowsShellWorkflow, $windowsPortWorkflow)) {
    if ($workflow -notmatch
        "compnerd/gha-setup-swift@397094e75494a93fa8d81db0268dbc8f5d6cf7c6" -or
        $workflow -notmatch "swift-version: swift-6\.3\.3-release" -or
        $workflow -notmatch "swift-build: 6\.3\.3-RELEASE") {
      throw "RED: pinned Windows CI does not install Swift 6.3.3 without WinGet"
    }
  }
  if ($windowsShellWorkflow -notmatch "bootstrap\.ps1") {
    throw "RED: Windows shell CI does not bootstrap exact dependencies"
  }
  if ($windowsShellWorkflow -notmatch "validate\.ps1 -Task windows-shell -SkipTrayLive" -or
      $windowsPortWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "validate\.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E" -or
      $windowsWorkflow -notmatch "Hardening\.Tests\.ps1 -Environment -SkipTrayLive") {
    throw "RED: hosted Windows CI does not explicitly declare unsupported interactive or WSL fixtures"
  }
  if ($windowsShellWorkflow -notmatch '(?m)^\s*run:\s*\./Tools/windows/validate\.ps1 -Task windows-shell\b') {
    throw "RED: Windows shell CI does not invoke the shell task containing live UI Automation"
  }
  $runnerSource = Get-Content $runner -Raw
  Test-ZigResolverDiagnostics $runnerSource
  Assert-ShellHostPrerequisite $runnerSource
  $contractCall = [regex]::Match($runnerSource,
    '(?s)& \(Join-Path \$repoRoot "Tools\\windows\\Tests\\WindowsShell\.Tests\.ps1"\)\s*`\s*-ZigExecutable \$zig0152').Value
  if (-not $contractCall) { throw "Cannot construct the host prerequisite ordering control" }
  $earlyContracts = $runnerSource.Replace($contractCall, "").Replace(
    'Invoke-Native "Pinned Winghostty host build for App contracts"',
    $contractCall + "`n      " + 'Invoke-Native "Pinned Winghostty host build for App contracts"')
  foreach ($mutation in @(
      $runnerSource.Replace('& $zig0152 build -Demit-win32-host=true', 'Write-Output "deliberately skipped build"'),
      $runnerSource.Replace('"Pinned Winghostty host build for App contracts"', '"deliberately removed prerequisite"'),
      $earlyContracts
    )) {
    $rejected = $false
    try { Assert-ShellHostPrerequisite $mutation } catch { $rejected = $true }
    if (-not $rejected) { throw "Host prerequisite contract accepted a deliberate missing-build control" }
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Signing\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run signed catalog integrity contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Rollback\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run rollback preservation contracts"
  }
  if ($runnerSource -notmatch '(?s)"packaging" \{\s*& .*?Packaging\.Standalone\.Tests\.ps1.*?Packaging\.Tests\.ps1') {
    throw "RED: packaging validation does not run standalone setup contracts"
  }
  foreach ($contract in @("Packaging.ScriptSigning.Tests.ps1", "Packaging.Scheduler.Tests.ps1")) {
    if ($runnerSource -notmatch ('(?s)"packaging" \{\s*& .*?' + [regex]::Escape($contract) + '.*?Packaging\.Tests\.ps1')) {
      throw "RED: packaging validation does not run $contract"
    }
  }
  if ($runnerSource -notmatch '(?s)"terminal-gate" \{\s*& .*?ProviderPins\.Tests\.ps1.*?TerminalGate\.Tests\.ps1') {
    throw "RED: terminal validation does not run provider pin no-divergence contracts"
  }
  foreach ($source in @($runnerSource, $hardeningSource)) {
    if ($source -notmatch '-StubResponseDelayMilliseconds 150') {
      throw "RED: shell validation does not exercise delayed correlated responses"
    }
  }
  if ($runnerSource -notmatch '(?s)Pinned GraphCode Windows shell build and smoke.*?Native UI Automation live gate.*?uia-live-gate\.ps1') {
    throw "RED: Windows shell validation does not execute the UI Automation live gate"
  }
  $uiaLiveGateSource = Get-Content (Join-Path $repoRoot "Tools\windows\uia-live-gate.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'UIA_ROOT_ACCESS' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'maxSandboxRootUtf16' -or
      $uiaLiveGateSource -notmatch 'Require \(\[GraphCodeUiaGateState\]::WindowIsVisible\(\$shellWindow\)\)') {
    throw "RED: UIA gate does not identify visible shell HWND, background root access, missing modal and short TEMP remedy"
  }
  if ($uiaLiveGateSource -notmatch 'FindTopLevel\("GraphCodeUpdateOffer", \[uint32\]\$process\.Id\)' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_DIRECT' -or
      $uiaLiveGateSource -notmatch 'FromHandle\(\$nativeUpdateWindow\)' -or
      $uiaLiveGateSource -notmatch '\$updateDialog = \$directUpdate') {
    throw "RED: UIA gate does not use the owned modal HWND when desktop-tree lookup omits it"
  }
  if ($uiaLiveGateSource -notmatch '(?s)\$updateDialog = \$desktop\.FindFirst\(\s*\[System\.Windows\.Automation\.TreeScope\]::Children' -or
      $uiaLiveGateSource -notmatch 'UIA_UPDATE_DIALOG_CHILDREN found=' -or
      $uiaLiveGateSource -notmatch 'Current\.ProcessId -ne \$process\.Id') {
    throw "RED: UIA gate does not search top-level dialogs as desktop children scoped to the shell PID"
  }
  if ($uiaLiveGateSource -notmatch 'LastActivationDiagnostic' -or
      $uiaLiveGateSource -notmatch 'SetForegroundWindow\(window\).*?Marshal.GetLastWin32Error\(\)' -or
      $uiaLiveGateSource -notmatch 'AttachThreadInput\(currentThread, targetThread, true\).*?Marshal.GetLastWin32Error\(\)') {
    throw "RED: UIA foreground failure hides native return values and last-error diagnostics"
  }
  if ($uiaLiveGateSource -notmatch 'AttachThreadInput' -or
  $uiaLiveGateSource -notmatch 'keybd_event\(0x12, 0, 0, UIntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch 'SetActiveWindow\(window\)' -or
  $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x0101, \(UIntPtr\)key, IntPtr\.Zero\)' -or
  $uiaLiveGateSource -notmatch '\[DllImport\("kernel32\.dll"\)\]\s*private static extern uint GetCurrentThreadId' -or
      $uiaLiveGateSource -notmatch 'IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOCUS_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch '(?s)function Hide-TestProviderZmxWindows.*?\[string\]\$_\.ExecutablePath\)\s+-eq\s+\$providerZmx.*?HideProcessWindows.*?HideWindow\(\$foreground\)' -or
      $uiaLiveGateSource -notmatch 'function Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Test-FocusedElementIdentity \$candidate \$element \$expectedAutomationId' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch '\$element\.SetFocus\(\)' -or
      $uiaLiveGateSource -notmatch 'Retain-FocusWithRetry \$shellWindow \$safeFocusRow \$safeRowId "before-retention"' -or
      $uiaLiveGateSource -notmatch '\$backendFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings backend control could not retain foreground focus' -or
      $uiaLiveGateSource -notmatch '\$cancelFocus = Retain-FocusWithRetry' -or
      $uiaLiveGateSource -notmatch 'Product Settings model control could not retain foreground focus') {
    throw "RED: UIA live gate does not prove foreground ownership before accepting row focus"
  }
  if ($uiaLiveGateSource -notmatch 'function Wait-ForDesktopElement' -or
      $uiaLiveGateSource -notmatch 'function Wait-ForDesktopElementGone' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS' -or
      $uiaLiveGateSource -notmatch 'empty global New Loop node form' -or
      $uiaLiveGateSource -notmatch 'empty project New Loop node form' -or
      $uiaLiveGateSource -notmatch 'project-row New Loop node form' -or
      $uiaLiveGateSource -notmatch 'Open Folder picker close') {
    throw "RED: UIA live gate does not wait deterministically for asynchronous modal windows"
  }
  if ($uiaLiveGateSource -match '(?s)New Loop command was rejected.*?for \(\$index = 0; \$index -lt 40 -and \$null -eq \$.*NodeForm' -or
      $uiaLiveGateSource -match '(?s)Open Folder command was rejected.*?Start-Sleep -Milliseconds 200\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)') {
    throw "RED: UIA live gate reintroduced short fixed polling around New Loop modal commands"
  }
  if ($uiaLiveGateSource -notmatch 'function Ensure-ShellForeground' -or
      $uiaLiveGateSource -notmatch '\[GraphCodeUiaGateState\]::ActivateWindow\(\$window\)\s*[\r\n]+\s*\$acquired = \$activated -and \[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)' -or
      $uiaLiveGateSource -notmatch 'UIA_FOREGROUND_DIAGNOSTICS phase=\$label \$\(Get-FocusDiagnostics \$window\)' -or
      $uiaLiveGateSource -notmatch '(?s)function Ensure-ShellForeground\(.*?if \(\[GraphCodeUiaGateState\]::IsForegroundWindow\(\$window\)\) \{\s*[\r\n]+\s*return \$true\s*[\r\n]+\s*\}') {
    throw "RED: UIA live gate does not reacquire GraphCode shell foreground within a bounded deadline before command paths, or performs the invasive Alt-tap activation even when already foreground"
  }
  if ($uiaLiveGateSource -notmatch '(?s)function Wait-ForDesktopElement\(.*?\[switch\] \$RecoverForeground.*?\$remainingMilliseconds = \[Math\]::Max\(.*?\$recoveryTimeout = \[Math\]::Min\(1000, \$remainingMilliseconds\).*?UIA_WAIT_FOREGROUND_RECOVERY label=\$label.*?Ensure-ShellForeground.*?-TimeoutMilliseconds \$recoveryTimeout' -or
      $uiaLiveGateSource -notmatch 'UIA_WAIT_DIAGNOSTICS label=\$label foregroundRecoveries=\$foregroundRecoveries' -or
      $uiaLiveGateSource -notmatch '(?s)-label "project-row New Loop node form".*?-RecoverForeground' -or
      $uiaLiveGateSource -notmatch '(?s)-label "empty global New Loop node form".*?-RecoverForeground' -or
      $uiaLiveGateSource -notmatch '(?s)-label "empty project New Loop node form".*?-RecoverForeground') {
    throw "RED: UIA modal waits do not boundedly reacquire foreground after a post-command foreground loss"
  }
  if ($uiaLiveGateSource -notmatch '(?s)Require \(\$null -ne \$projectNewLoop\) "project row omitted New Loop"\s*[\r\n]+\s*Require \(Ensure-ShellForeground \$shellWindow "project-row New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before invoking project-row New Loop"\s*[\r\n]+\s*\$projectNewLoop\.GetCurrentPattern' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty global New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty global New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty global New Loop command was rejected"' -or
      $uiaLiveGateSource -notmatch '(?s)Require \(Ensure-ShellForeground \$shellWindow "empty project New Loop"\)\s*`\s*[\r\n]+\s*"GraphCode shell did not reacquire foreground before empty project New Loop command"\s*[\r\n]+\s*Require \(\[GraphCodeUiaGateState\]::PostCommand\(\$shellWindow, 4602\)\)\s*`\s*[\r\n]+\s*"empty project New Loop command was rejected"') {
    throw "RED: UIA live gate New Loop invocation is not preceded by verified foreground recovery at every site"
  }
  $shellTests = Get-Content (Join-Path $PSScriptRoot "WindowsShell.Tests.ps1") -Raw
  if ($uiaLiveGateSource -notmatch 'function Wait-ForPopupMenu' -or
      $uiaLiveGateSource -notmatch 'function Get-PopupMenuItems' -or
      $uiaLiveGateSource -notmatch 'function Close-PopupMenu' -or
      $uiaLiveGateSource -notmatch 'FindPopupMenuWindow' -or
      $uiaLiveGateSource -notmatch 'SendMessage\(popup, 0x01E1, UIntPtr\.Zero, IntPtr\.Zero\)' -or
      $uiaLiveGateSource -notmatch 'PostMessage\(window, 0x802C, \(UIntPtr\)target, IntPtr\.Zero\)') {
    throw "RED: UIA live gate cannot open, read, or dismiss a native TrackPopupMenu popup"
  }
  if ($uiaLiveGateSource -notmatch '\$moveProjectMenuText = "Move Project\.\.\. \(unavailable: daemon support required\)"' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 1\).*?Wait-ForPopupMenu \$process \$shellWindow "project"' -or
      $uiaLiveGateSource -notmatch 'Require \(-not \$moveProjectItem\.Enabled\)' -or
      $uiaLiveGateSource -notmatch '\$moveProjectItem\.Text -eq \$moveProjectMenuText' -or
      $uiaLiveGateSource -notmatch '(?s)PostContextMenu\(\$shellWindow, 2\).*?\$_\.Id -in @\(5149, 5151, 5144\)' -or
      $uiaLiveGateSource -notmatch 'project context menu did not dismiss, leaving the shell blocked in its modal loop') {
    throw "RED: UIA live gate does not assert the live project context menu's disabled Move item and deterministic dismissal"
  }
  if ($shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\GraphContextMenu\.zig' -or
      $shellTests -notmatch '(?s)Context menu and gate fixture message executable tests.*?zig test src\\MainWindow\.zig') {
    throw "RED: Windows shell validation does not run the context menu and gate fixture message tests"
  }
  $appSource = Get-Content (Join-Path $repoRoot "graphcode-windows\src\App.zig") -Raw
  if ($appSource -notmatch 'fn showUiaContextMenu' -or
      $appSource -notmatch 'MainWindow\.wm_uia_context_menu => \{' -or
      $appSource -notmatch '(?s)wparam == MainWindow\.menu_watchdog_timer_id.*?c\.EndMenu\(\)') {
    throw "RED: the shell cannot open a gate-requested context menu, or an abandoned popup can block its message loop forever"
  }
  if ($shellTests -notmatch '(?s)Windows update feed executable tests.*?zig test src\\WindowsUpdates\.zig.*?-lwinhttp') {
    throw "RED: Windows shell validation does not run the native updater tests"
  }
  if ($runnerSource -notmatch '\$SkipWslRemoteE2E' -or
      $runnerSource -notmatch '"--skip-local-wsl"') {
    throw "RED: hosted validation cannot explicitly isolate unavailable local WSL fixtures"
  }
  $privacyRaceSource = Get-Content `
    (Join-Path $repoRoot "Tools\windows\Tests\RemoteBridgePrivacyRace.Tests.ps1") -Raw
  if ($privacyRaceSource -notmatch '\$AvailableProcessorCount = \[Environment\]::ProcessorCount' -or
      $privacyRaceSource -notmatch '\$remoteProcessCount = 1' -or
      $privacyRaceSource -notmatch '\[Math\]::Min\(24, \[Math\]::Max\(4, \$processorCount \* 2\)\)' -or
      $privacyRaceSource -notmatch 'GRAPHCODE_REMOTE_BRIDGE_TEST_TIMEOUT_MULTIPLIER = "3"') {
    throw "RED: remote bridge privacy race does not scale bounded concurrency to runner capacity"
  }
  if ($windowsWorkflow -notmatch "(?s)environment:.*Hardening\.Tests\.ps1 -Environment -SchemaOnly") {
    throw "RED: environment CI does not invoke the exact schema-only hardening contract"
  }
  $macWorkflow = Get-Content (Join-Path $repoRoot ".github\workflows\macos-shared-regression.yml") -Raw
  if ($macWorkflow -notmatch "brew install mise" -or
      $macWorkflow -notmatch "mise install" -or
      $macWorkflow -notmatch "mise exec -- make test") {
    throw "RED: macOS CI does not install and execute pinned mise.toml tools"
  }
  $requiredWorkflows = [ordered]@{
    "macos-shared-regression.yml" = $macWorkflow
    "windows-shell.yml" = $windowsShellWorkflow
    "windows-port-validation.yml" = $windowsPortWorkflow
    "windows-hardening.yml" = $windowsWorkflow
  }
  foreach ($entry in $requiredWorkflows.GetEnumerator()) {
    $trigger = [regex]::Match(
      $entry.Value,
      '(?ms)^  pull_request:(?<settings>.*?)(?=^[^\s#]|^  [A-Za-z_][A-Za-z0-9_-]*:|\z)')
    $settings = [regex]::Replace($trigger.Groups["settings"].Value, '(?m)#.*$', '').Trim()
    if (-not $trigger.Success -or $settings -notin @("", "{}")) {
      throw "RED: $($entry.Key) must report required checks for every PR, including documentation-only changes"
    }
  }
} finally {
  Remove-Item -LiteralPath $foreignJunction -Recurse -Force -ErrorAction SilentlyContinue
}

$oldWinghosttyRoot = [Environment]::GetEnvironmentVariable(
  "GRAPHCODE_WINGHOSTTY_ROOT"
)
$oldZmxRoot = [Environment]::GetEnvironmentVariable("GRAPHCODE_ZMX_ROOT")
try {
  $env:GRAPHCODE_WINGHOSTTY_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-winghostty-provider"
  $env:GRAPHCODE_ZMX_ROOT = Join-Path $repoRoot `
    "investigation\spikes\missing-zmx-provider"
  & $pwsh -NoProfile -File $runner -Task terminal-gate *> $null
  if ($LASTEXITCODE -eq 0) {
    throw "terminal-gate passed without its pinned providers"
  }
} finally {
  if ($null -eq $oldWinghosttyRoot) {
    Remove-Item Env:GRAPHCODE_WINGHOSTTY_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_WINGHOSTTY_ROOT = $oldWinghosttyRoot
  }
  if ($null -eq $oldZmxRoot) {
    Remove-Item Env:GRAPHCODE_ZMX_ROOT -ErrorAction SilentlyContinue
  } else {
    $env:GRAPHCODE_ZMX_ROOT = $oldZmxRoot
  }
}

Write-Host "ValidationRunner.Tests.ps1: PASS"
exit 0
