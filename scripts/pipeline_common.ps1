# Shared plumbing every entry-point script in this folder needs, so none of them
# has to carry its own copy: the PowerShell 7 relaunch, the atomic manifest
# write, and the analysis-lock reader. Dot-sourced (never run directly -- it has
# no entry point of its own) by run_analysis_pipeline.ps1,
# run_analysis_pipeline_parallel.ps1, queue_eta.ps1, backfill_new_stage.ps1,
# generate_analysis_queue.ps1, verify_synthesis_quality.ps1,
# verify_manifest_repair.ps1, stop_analysis_pipeline.ps1 and
# reset_analysis_state.ps1.
#
# When to use: never run directly. Edit it when something that applies to every
# script's startup, to manifest writing, or to reading the run locks needs to
# change. Before this file existed, the relaunch block was hand-copied into six
# scripts, Write-Utf8NoBom into three (one of which had silently missed the
# read-back verification the other two gained) and the lock reader into two.
#
# Nothing here reads or writes pipeline state by itself.

# ---------------------------------------------------------------------------
# Restart-UnderPowerShell7
# ---------------------------------------------------------------------------
# Relaunches the calling script under PowerShell 7 when it is currently running
# under Windows PowerShell 5.1, forwarding every bound parameter through a
# temporary JSON bootstrap file + hashtable splat -- not raw -File command-line
# args, whose own argument parsing silently mangles array-typed parameters
# (space-separated values drop everything after the first element; a single
# comma-joined token doesn't get re-split into an array either).
#
# Called at the top of any script whose manifest handling needs PS7: manifest.json
# grows into the tens of MB, and 5.1's JavaScriptSerializer-backed ConvertFrom-Json
# is both far slower on it and, past a certain size, fails outright with a garbled
# dump instead of a clean error. A no-op when already running under PS7, including
# when launched as a worker job by an already-relaunched orchestrator.
#
#   Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
#       # relaunch if pwsh exists; otherwise warn and carry on under 5.1
#   Restart-UnderPowerShell7 -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters `
#       -Required -MissingPwshMessage "pwsh.exe (PowerShell 7) not found -- <why
#       this script cannot run under 5.1 at all>"
#
# $ScriptPath must be passed explicitly ($PSCommandPath, evaluated at the call
# site) rather than read inside this function: $PSCommandPath belongs to the
# script currently executing, and relying on that from a dot-sourced helper is
# exactly the kind of implicit assumption this file exists to remove.
#
# After a successful relaunch it exits with the child's exit code, so nothing
# after the call runs in the parent process.
function Restart-UnderPowerShell7 {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{},
        [switch]$Required,
        [string]$MissingPwshMessage = "pwsh.exe (PowerShell 7) not found -- continuing under Windows PowerShell 5.1, which cannot reliably parse a large manifest.json."
    )
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return }

    $pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $pwshExe) {
        $pwshExe = @(
            "$env:ProgramFiles\PowerShell\7\pwsh.exe"
            "$env:LOCALAPPDATA\Programs\PowerShell-7.6.6\pwsh.exe"
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }
    if (-not $pwshExe) {
        if ($Required) { throw $MissingPwshMessage }
        Write-Host ("WARNING: {0}" -f $MissingPwshMessage) -ForegroundColor Yellow
        return
    }

    $paramsForward = @{}
    foreach ($key in $BoundParameters.Keys) {
        $val = $BoundParameters[$key]
        if ($val -is [switch]) { $paramsForward[$key] = [bool]$val.IsPresent }
        else { $paramsForward[$key] = $val }
    }
    $bootstrapPath = [System.IO.Path]::GetTempFileName()
    $exitCode = 1
    try {
        ($paramsForward | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $bootstrapPath -Encoding UTF8
        # The trailing "exit [int]$LASTEXITCODE" is not decoration: under
        # -Command, an invoked script's own "exit N" does NOT become the child
        # process's exit code on its own (measured: it reports 1 -- so a
        # successful run launched from 5.1 looked like a failure). $LASTEXITCODE
        # does hold that N inside the child, so re-exiting with it propagates the
        # script's real code: N when it called exit N, 0 when it just completed,
        # 1 when it threw.
        $cmd = "`$h = Get-Content -LiteralPath '$bootstrapPath' -Raw | ConvertFrom-Json -AsHashtable; & '$ScriptPath' @h; exit [int]`$LASTEXITCODE"
        & $pwshExe -NoProfile -Command $cmd
        $exitCode = $LASTEXITCODE
    }
    finally {
        Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction SilentlyContinue
    }
    exit $exitCode
}

# ---------------------------------------------------------------------------
# Write-Utf8NoBom
# ---------------------------------------------------------------------------
# Write-then-atomic-rename, then read back what actually landed on disk and
# compare it against what was intended. Two separate hazards, both confirmed in
# practice on manifest.json:
#   - WriteAllText truncates the destination before writing, so a concurrent
#     reader (another worker, queue_eta.ps1) can catch a torn/empty fragment
#     ("ConvertFrom-Json: Invalid JSON primitive: ."). File.Replace/Move is
#     atomic on the same volume, so readers only ever see the old or the new
#     complete content, never a partial one.
#   - Something external can inject a single stray character into an otherwise
#     correct write (the same corruption class manifest_repair.ps1 repairs on
#     the read side; AV real-time scan/indexer interference is the standing
#     suspicion). Reading back catches that whatever the cause, and a transient
#     collision of this kind essentially never repeats on an immediate retry.
#
# Called by every script that writes manifest.json: run_analysis_pipeline.ps1
# (Save-Manifest), backfill_new_stage.ps1 and generate_analysis_queue.ps1.
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content, [int]$MaxWriteAttempts = 3)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    for ($writeAttempt = 1; $writeAttempt -le $MaxWriteAttempts; $writeAttempt++) {
        $tempPath = "$Path.tmp-$PID"
        [System.IO.File]::WriteAllText($tempPath, $Content, $encoding)
        if (Test-Path -LiteralPath $Path) {
            # File.Replace's 3-arg overload throws ArgumentException ("The path
            # is not of a legal form") when $null is passed for the backup-file
            # argument via PowerShell's method binding -- confirmed by testing
            # the exact same call with a real path, which succeeds. A real
            # (throwaway) backup path avoids the bug; it's deleted right after,
            # since the replace has already landed by then.
            $backupPath = "$Path.bak-$PID"
            # Retry on sharing violations: something (AV real-time scan, search
            # indexer) briefly opens a just-written file often enough, at this
            # write volume, to intermittently fail Replace with "The process
            # cannot access the file because it is being used by another
            # process." The lock clears on its own within milliseconds.
            $maxReplaceAttempts = 5
            for ($attempt = 1; $attempt -le $maxReplaceAttempts; $attempt++) {
                try {
                    [System.IO.File]::Replace($tempPath, $Path, $backupPath)
                    break
                }
                catch [System.IO.IOException] {
                    if ($attempt -eq $maxReplaceAttempts) { throw }
                    Start-Sleep -Milliseconds (100 * $attempt)
                }
            }
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
        else {
            [System.IO.File]::Move($tempPath, $Path)
        }

        $actualContent = [System.IO.File]::ReadAllText($Path, $encoding)
        if ($actualContent -ceq $Content) { return }
        if ($writeAttempt -eq $MaxWriteAttempts) {
            throw "Write-Utf8NoBom: content read back from '$Path' didn't match what was written, even after $MaxWriteAttempts attempts -- something external is altering this file during/after write."
        }
        Start-Sleep -Milliseconds (150 * $writeAttempt)
    }
}

# ---------------------------------------------------------------------------
# Get-AnalysisLocks
# ---------------------------------------------------------------------------
# Reads the per-process lock files run_analysis_pipeline.ps1 registers while it
# runs (one per worker PID -- see its "Register this run" block) and splits them
# into still-live entries and stale ones, whose files the caller removes. A lock
# whose PID is no longer running is stale: a worker that was killed, or a crash.
#
# Called by stop_analysis_pipeline.ps1 (to terminate the live ones) and
# reset_analysis_state.ps1 (same, before wiping state out from under a running
# worker). Kept here so the lock file's shape is parsed in exactly one place
# instead of once per caller.
#
# Returns an object with .Live (Pid / WorkerIndex / LockFile) and .StaleFiles
# (full paths) as plain arrays; an empty pair when the locks directory doesn't
# exist yet. Deliberately arrays rather than List[object]: callers used to wrap
# the result in @(), and in Windows PowerShell 5.1 @() over an *empty* typed List
# throws "Argument types do not match" (reproduced), which would have broken
# stop_analysis_pipeline.ps1/reset_analysis_state.ps1 on a machine with no
# running worker -- the common case.
function Get-AnalysisLocks {
    param([string]$LocksDir)
    $live = New-Object System.Collections.Generic.List[object]
    $staleFiles = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $LocksDir) {
        foreach ($lockFile in Get-ChildItem -Path $LocksDir -Filter "*.lock" -File) {
            $info = Get-Content -LiteralPath $lockFile.FullName -Raw | ConvertFrom-Json
            $process = Get-Process -Id $info.pid -ErrorAction SilentlyContinue
            if ($process) {
                $live.Add([pscustomobject]@{ Pid = $info.pid; WorkerIndex = $info.worker_index; LockFile = $lockFile.FullName })
            }
            else {
                $staleFiles.Add($lockFile.FullName)
            }
        }
    }
    return [pscustomobject]@{ Live = $live.ToArray(); StaleFiles = $staleFiles.ToArray() }
}
