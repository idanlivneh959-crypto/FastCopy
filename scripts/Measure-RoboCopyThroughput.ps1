<#
.SYNOPSIS
    Benchmarks robocopy across several /MT thread counts and reports the fastest,
    optionally as a two-pass small/large split.

.NOTES
    Each test copies into its own fresh destination so robocopy actually transfers
    data every run (it skips files that already exist at the destination, which
    would turn back-to-back runs into no-ops). Throughput is parsed from the
    /BYTES "Copied" column of the job summary.
#>
[CmdletBinding()]
param(
    [string]$Source       = "\\src\share",
    [string]$Destination  = "\\dst\share",
    [string]$LogDir       = "C:\Logs",
    [int[]] $ThreadTests  = @(8, 16, 32, 64),
    [switch]$SplitBySize,
    # Override for testing or to pin a specific robocopy.exe.
    [string]$RoboExe      = "robocopy",
    # Keep the per-test copies instead of deleting them after measuring.
    [switch]$KeepData
)

Set-StrictMode -Version Latest

# robocopy uses nonzero exit codes (1 = files copied, etc.) to signal SUCCESS.
# On PowerShell 7.4+ this preference defaults to $true, which would turn that
# normal nonzero exit into a terminating error. Disable it; we read $LASTEXITCODE
# ourselves and classify >=8 as failure.
$PSNativeCommandUseErrorActionPreference = $false

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Invoke-RoboTest {
    param(
        [int]      $Threads,
        [string[]] $ExtraArgs = @(),
        [string]   $Label     = "default"
    )

    $logFile   = Join-Path $LogDir ("robo_{0}_MT{1}.log" -f $Label, $Threads)
    $benchRoot = Join-Path $Destination "_bench"
    $testDest  = Join-Path $benchRoot ("{0}_MT{1}" -f $Label, $Threads)

    if (Test-Path -LiteralPath $testDest) {
        Remove-Item -LiteralPath $testDest -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $testDest | Out-Null

    Write-Host ("Testing MT:{0} ({1}) -> {2}" -f $Threads, $Label, $testDest)

    $roboArgs = @(
        $Source, $testDest,
        '/E',
        "/MT:$Threads",
        '/R:1', '/W:1',
        '/BYTES',                 # raw byte counts so the summary parses reliably
        '/NFL', '/NDL', '/NP',    # quiet console, but KEEP the job summary
        "/LOG:$logFile"
    ) + $ExtraArgs

    $start = Get-Date
    & $RoboExe @roboArgs | Out-Null
    $code     = $LASTEXITCODE
    $duration = (Get-Date) - $start

    $failed = $code -ge 8

    # Parse the COPIED column (2nd number) of the "Bytes :" summary line.
    $bytesCopied = [int64]0
    $m = Select-String -LiteralPath $logFile -Pattern 'Bytes :\s+([\d,]+)\s+([\d,]+)'
    if ($m) {
        $bytesCopied = ($m.Matches[0].Groups[2].Value -replace ',', '') -as [int64]
    }

    $mbps = if ($duration.TotalSeconds -gt 0) {
        [math]::Round((($bytesCopied / 1MB) / $duration.TotalSeconds), 2)
    } else { 0 }

    if (-not $KeepData) {
        Remove-Item -LiteralPath $testDest -Recurse -Force -ErrorAction SilentlyContinue
    }

    [PSCustomObject]@{
        Threads  = $Threads
        Label    = $Label
        Seconds  = [math]::Round($duration.TotalSeconds, 2)
        MBCopied = [math]::Round($bytesCopied / 1MB, 2)
        MBps     = $mbps
        ExitCode = $code
        Failed   = $failed
        Log      = $logFile
    }
}

$results = [System.Collections.Generic.List[object]]::new()

if ($SplitBySize) {
    Write-Host "=== SMALL FILE PASS (<=256MB) ==="
    foreach ($t in $ThreadTests) {
        $results.Add((Invoke-RoboTest -Threads $t -ExtraArgs @('/MAX:268435456') -Label 'small'))
    }

    Write-Host "=== LARGE FILE PASS (>256MB) ==="
    foreach ($t in $ThreadTests) {
        $results.Add((Invoke-RoboTest -Threads $t -ExtraArgs @('/MIN:268435457', '/J') -Label 'large'))
    }
}
else {
    foreach ($t in $ThreadTests) {
        $results.Add((Invoke-RoboTest -Threads $t))
    }
}

Write-Host "`n=== RESULTS ==="
# Out-String -Width forces a render width; Format-Table alone emits nothing when
# there's no console (non-interactive host, redirected output, scheduled task).
$results | Sort-Object MBps -Descending |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host

$ranked = @($results | Where-Object { -not $_.Failed } | Sort-Object MBps -Descending)
if ($ranked.Count -gt 0) {
    Write-Host "=== BEST CONFIG ==="
    $ranked[0] | Format-List | Out-String -Width 200 | Write-Host
}
else {
    Write-Host "No successful runs to rank (all failed)."
}

Write-Host "`nDone."
