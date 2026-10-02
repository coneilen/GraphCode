# Requires PowerShell 7. All Git commands run in newly created fixture repositories.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Zig,
    [Parameter(Mandatory)][string] $EvidenceDirectory,
    [string] $FixtureDirectory,
    [ValidateSet(
        "scope-dir", "scope-mixed-case", "scope-config-count", "scope-config-parameters",
        "index", "objects", "preserve", "streams", "stdout-cap", "stderr-cap",
        "errors", "git-stderr", "allocations", "removals",
        "removal-output-direct", "removal-output-selected", "removal-output-forced",
        IgnoreCase = $false
    )]
    [ValidateNotNullOrEmpty()]
    [ValidateCount(1, 32)][string[]] $Cases = @(
        "scope-dir", "scope-mixed-case", "scope-config-count", "scope-config-parameters",
        "index", "objects", "preserve", "streams", "stdout-cap", "stderr-cap",
        "errors", "git-stderr", "allocations", "removals",
        "removal-output-direct", "removal-output-selected", "removal-output-forced"
    ),
    [ValidateRange(5, 300)][int] $TimeoutSeconds = 60
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if (-not $IsWindows) { throw "The process harness requires Windows." }
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$Zig = (Resolve-Path $Zig).Path
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
$fixture = if ($FixtureDirectory) {
    [IO.Path]::GetFullPath($FixtureDirectory)
} else {
    Join-Path ([IO.Path]::GetTempPath()) ("graphcode-worktree-process-" + [guid]::NewGuid().ToString("N"))
}
$evidencePrefix = $evidence.TrimEnd('\') + '\'
$fixturePrefix = $fixture.TrimEnd('\') + '\'
if ($evidence.Equals($fixture, [StringComparison]::OrdinalIgnoreCase) -or
    $evidence.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    $fixture.StartsWith($evidencePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Evidence and fixture directories must be isolated so fixture cleanup cannot remove immutable logs: evidence='$evidence'; fixture='$fixture'"
}
# The isolated Git config intentionally leaves core.longpaths unset, so budget for the legacy Win32 limit.
$pathLimit = 259
$longestFixturePath = Join-Path $fixture (
    "removal-output-selected-" + ("0" * 32) + "\target\.git\worktrees\selected\logs\HEAD.lock"
)
if ($longestFixturePath.Length -gt $pathLimit) {
    throw "Worktree Git fixture path budget exceeded: fixture root '$fixture' ($($fixture.Length) chars) projects a $($longestFixturePath.Length)-character Git metadata path; the supported limit is $pathLimit. Set TEMP/TMP to a shorter owned directory or pass -FixtureDirectory with a shorter unique path."
}
if (Test-Path -LiteralPath $evidence) { throw "Evidence directory already exists; RED logs must not be overwritten." }
if (Test-Path -LiteralPath $fixture) { throw "Fixture directory already exists; per-run state must be uniquely owned: $fixture" }
[void][IO.Directory]::CreateDirectory($evidence)
[void][IO.Directory]::CreateDirectory($fixture)
$fixtureTemp = Join-Path $fixture "temp"
[void][IO.Directory]::CreateDirectory($fixtureTemp)
$cache = Join-Path $fixture "cache"
$globalCache = Join-Path $fixture "global-cache"
$testExe = Join-Path $fixture "worktree-tests.exe"
$emitter = Join-Path $fixture "worktree-child.exe"
$fixtureSummary = @(
    "fixtureRoot=$fixture"
    "fixtureRootLength=$($fixture.Length)"
    "projectedLongestPath=$longestFixturePath"
    "projectedLongestPathLength=$($longestFixturePath.Length)"
    "supportedPathLimit=$pathLimit"
) -join "`n"
[IO.File]::WriteAllText((Join-Path $evidence "fixture-root.log"), $fixtureSummary + "`n")
$realGit = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$invalidCases = @("scope-config-countt", "removal-output-directt", "removal-output-selectedt", "removal-output-forcedt")
$invalidSelections = @($invalidCases | ForEach-Object { @{ Name = $_; Values = @($_) } }) + @(
    @{ Name = "empty-collection"; Values = @() },
    @{ Name = "null-collection"; Values = $null },
    @{ Name = "empty-entry"; Values = @("") },
    @{ Name = "null-entry"; Values = @($null) },
    @{ Name = "case-mismatch"; Values = @("Scope-config-count") },
    @{ Name = "mixed-valid-invalid"; Values = @("scope-dir", "scope-config-countt") }
)
$selectorChecks = foreach ($selection in $invalidSelections) {
    $rejectedEvidence = Join-Path $evidence ("must-not-create-" + $selection.Name)
    $rejected = $false
    try {
        # A missing compiler prevents recursive execution if parameter validation regresses.
        & $PSCommandPath -Zig (Join-Path $evidence "must-not-run-compiler.exe") `
            -EvidenceDirectory $rejectedEvidence -Cases $selection.Values
    } catch [System.Management.Automation.ParameterBindingException] {
        if ($_.FullyQualifiedErrorId -notlike "ParameterArgumentValidationError*") { throw }
        $rejected = $true
    }
    if (-not $rejected -or (Test-Path -LiteralPath $rejectedEvidence)) {
        throw "Invalid selection was not rejected before setup: $($selection.Name)"
    }
    "PowerShell rejected $($selection.Name) during parameter binding; no build or evidence directory."
}
$selectorChecks | Set-Content -LiteralPath (Join-Path $evidence "selector-validation.log")
$selectorChecks

Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class WorktreeProcessJob {
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimits { public long ProcessTime, JobTime; public uint Flags; public UIntPtr Min, Max; public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)]
    struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    struct Limits { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [StructLayout(LayoutKind.Sequential)]
    struct Accounting { public long User, Kernel, PeriodUser, PeriodKernel; public uint Faults, Total, Active, Terminated; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int info, ref Limits limits, uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int info, out Accounting accounting, uint size, IntPtr length);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr handle);
    public static IntPtr Create() {
        var job = CreateJobObjectW(IntPtr.Zero, IntPtr.Zero);
        if (job == IntPtr.Zero) throw new Win32Exception();
        var limits = new Limits(); limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<Limits>())) {
            var error = new Win32Exception(); CloseHandle(job); throw error;
        }
        return job;
    }
    public static void Assign(IntPtr job, IntPtr process) { if (!AssignProcessToJobObject(job, process)) throw new Win32Exception(); }
    public static uint Active(IntPtr job) {
        Accounting value;
        if (!QueryInformationJobObject(job, 1, out value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero)) throw new Win32Exception();
        return value.Active;
    }
    public static void Terminate(IntPtr job) { if (!TerminateJobObject(job, 124)) throw new Win32Exception(); }
    public static void Close(IntPtr job) { if (!CloseHandle(job)) throw new Win32Exception(); }
}
'@

$executedCases = 0
Push-Location $repo
try {
    & $Zig build-exe (Join-Path $PSScriptRoot "fixtures\worktree-git-child.zig") --cache-dir $cache --global-cache-dir $globalCache "-femit-bin=$emitter" 2>&1 |
        Tee-Object -FilePath (Join-Path $evidence "build-child.log")
    if ($LASTEXITCODE -ne 0) { throw "Child fixture build failed." }
    $fakeBin = Join-Path $fixture "synthetic-git"
    [void][IO.Directory]::CreateDirectory($fakeBin)
    Copy-Item -LiteralPath $emitter -Destination (Join-Path $fakeBin "git.exe")
    & $Zig test --test-no-exec --dep worktree "-Mroot=$(Join-Path $PSScriptRoot 'fixtures\worktree-git-tests.zig')" "-Mworktree=$(Join-Path $repo 'graphcode-windows\src\WorktreeStatus.zig')" --cache-dir $cache --global-cache-dir $globalCache "-femit-bin=$testExe" 2>&1 |
        Tee-Object -FilePath (Join-Path $evidence "build-tests.log")
    if ($LASTEXITCODE -ne 0) { throw "Production helper test build failed." }
    $failures = 0
    foreach ($case in (@($Cases) + $invalidCases)) {
        $expectRejected = $invalidCases -ccontains $case
        $root = Join-Path $fixture ($case + "-" + [guid]::NewGuid().ToString("N"))
        [void][IO.Directory]::CreateDirectory($root)
        $fixtureHome = Join-Path $root "home"
        [void][IO.Directory]::CreateDirectory($fixtureHome)
        $config = Join-Path $root "global.config"
        [IO.File]::WriteAllText($config, "[graphcode]`n sentinel = synthetic-config`n")
        $outside = Join-Path $root "outside"
        $info = [Diagnostics.ProcessStartInfo]::new($testExe)
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.WorkingDirectory = $root
        foreach ($key in @($info.Environment.Keys)) {
            if ($key.StartsWith("GIT_", [StringComparison]::OrdinalIgnoreCase)) { [void]$info.Environment.Remove($key) }
        }
        $info.Environment["HOME"] = $fixtureHome
        $info.Environment["USERPROFILE"] = $fixtureHome
        $info.Environment["XDG_CONFIG_HOME"] = $fixtureHome
        $info.Environment["TEMP"] = $fixtureTemp
        $info.Environment["TMP"] = $fixtureTemp
        $info.Environment["GIT_CONFIG_NOSYSTEM"] = "1"
        $info.Environment["GIT_CONFIG_GLOBAL"] = $config
        $info.Environment["GIT_TERMINAL_PROMPT"] = "0"
        $info.Environment["GRAPHCODE_WORKTREE_TEST_ROOT"] = $root
        $info.Environment["GRAPHCODE_WORKTREE_TEST_CASE"] = $case
        $info.Environment["GRAPHCODE_WORKTREE_TEST_CHILD"] = $emitter
        $info.Environment["GRAPHCODE_WORKTREE_TEST_REAL_GIT"] = $realGit
        if (@("removal-output-direct", "removal-output-selected", "removal-output-forced") -ccontains $case) {
            $info.Environment["PATH"] = $fakeBin + ";" + $info.Environment["PATH"]
        }
        switch ($case) {
            "scope-dir" { $info.Environment["GIT_DIR"] = Join-Path $outside ".git"; $info.Environment["GIT_WORK_TREE"] = $outside }
            "scope-mixed-case" { $info.Environment["gIt_DiR"] = Join-Path $outside ".git"; $info.Environment["gIt_WoRk_TrEe"] = $outside }
            "scope-config-count" { $info.Environment["GIT_CONFIG_COUNT"] = "2"; $info.Environment["GIT_CONFIG_KEY_0"] = "core.worktree"; $info.Environment["GIT_CONFIG_VALUE_0"] = $outside; $info.Environment["GIT_CONFIG_KEY_1"] = "graphcode.injected"; $info.Environment["GIT_CONFIG_VALUE_1"] = "synthetic-rejected" }
            "scope-config-parameters" { $info.Environment["GIT_CONFIG_PARAMETERS"] = "'core.worktree=$($outside.Replace('\', '/'))' 'graphcode.injected=synthetic-rejected'" }
            "index" { $info.Environment["gIt_InDeX_FiLe"] = Join-Path $outside ".git\index" }
            "objects" { $info.Environment["gIt_ObJeCt_DiReCtOrY"] = Join-Path $outside ".git\objects" }
            "preserve" {
                foreach ($key in @("GIT_ASKPASS", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_CONFIG_SYSTEM", "GIT_EXEC_PATH", "SSH_AUTH_SOCK", "GRAPHCODE_SYNTHETIC_TOKEN")) {
                    $info.Environment[$key] = "synthetic-preserved"
                }
                $info.Environment["GIT_OPTIONAL_LOCKS"] = "0"
                $info.Environment["GIT_SSH_VARIANT"] = "ssh"
            }
        }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $job = [WorktreeProcessJob]::Create()
        $started = $false
        $assigned = $false
        try {
            $started = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            [WorktreeProcessJob]::Assign($job, $process.Handle)
            $assigned = $true
            # No fixture child may spawn until it observes this gate after job assignment.
            [IO.File]::WriteAllText((Join-Path $root "start"), "assigned")
            $finished = $process.WaitForExit($TimeoutSeconds * 1000)
            $settle = [DateTime]::UtcNow.AddMilliseconds(250)
            while ($finished -and [WorktreeProcessJob]::Active($job) -ne 0 -and [DateTime]::UtcNow -lt $settle) { Start-Sleep -Milliseconds 10 }
            $activeBeforeCleanup = [WorktreeProcessJob]::Active($job)
            if (-not $finished -or $activeBeforeCleanup -ne 0) { [WorktreeProcessJob]::Terminate($job) }
            if (-not $process.WaitForExit(10000)) { throw "Owned test process did not exit after job termination." }
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([WorktreeProcessJob]::Active($job) -ne 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
            $activeAfterCleanup = [WorktreeProcessJob]::Active($job)
            if ($activeAfterCleanup -ne 0) { throw "Owned job still has active children." }
            $log = "case=$case expectedRejection=$expectRejected pid=$($process.Id) finished=$finished exit=$($process.ExitCode) activeBeforeCleanup=$activeBeforeCleanup activeAfterCleanup=$activeAfterCleanup`n" +
                $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            [IO.File]::WriteAllText((Join-Path $evidence "$case.log"), $log)
            Write-Output $log
            $executedCases++
            $correctExit = $process.ExitCode -eq 0
            if ($expectRejected) {
                $createdFixture = @("target", "outside", "selected", "child.pid") |
                    Where-Object { Test-Path -LiteralPath (Join-Path $root $_) }
                $correctExit = $process.ExitCode -ne 0 -and $log.Contains("FAIL (UnknownFixtureScenario)") -and
                    @($createdFixture).Count -eq 0
            }
            if (-not $finished -or -not $correctExit -or $activeBeforeCleanup -ne 0) { $failures++ }
        } finally {
            try {
                if ($assigned) { [WorktreeProcessJob]::Terminate($job) }
                elseif ($started -and -not $process.HasExited) { $process.Kill($true); [void]$process.WaitForExit(10000) }
            } finally {
                try { [WorktreeProcessJob]::Close($job) } finally { $process.Dispose() }
            }
        }
    }
    if ($failures -ne 0) { throw "$failures process regression case(s) failed; immutable logs: $evidence" }
} finally {
    try { Pop-Location } finally {
        if (Test-Path -LiteralPath $fixture) {
            Remove-Item -LiteralPath $fixture -Recurse -Force
        }
    }
}
if ($executedCases -le 0) { throw "Worktree Git process harness reported no executed cases." }
Write-Output "WorktreeGitProcess.Tests.ps1: PASS; requested=$(@($Cases).Count); rejection=$($invalidCases.Count); executed=$executedCases; evidence=$evidence"
