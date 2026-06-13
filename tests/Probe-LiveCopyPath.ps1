<#
.SYNOPSIS
    Exercises the GUI's live-copy mechanism (ProcessStartInfo.Arguments built by
    ConvertTo-RoboArgLine) against REAL robocopy, including a path WITH SPACES —
    the case that would break under naive quoting. This is the path the full
    test suite does not cover because it needs a live process launch.
#>
[CmdletBinding()]
param([string]$Root = 'C:\FastCopy_test_live')

$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check($Label, $Cond) {
    if ($Cond) { Write-Host "  PASS  $Label" -ForegroundColor Green; $script:pass++ }
    else { Write-Host "  FAIL  $Label" -ForegroundColor Red; $script:fail++ }
}

$gui = Join-Path (Split-Path $PSScriptRoot -Parent) 'gui\FastCopy.ps1'
. $gui   # entry-guard must skip WPF

# Sanity: ProcessStartInfo really has NO ArgumentList here (the bug we fixed)
$psiProbe = New-Object System.Diagnostics.ProcessStartInfo
Check 'confirmed: ProcessStartInfo.ArgumentList absent on this runtime (why .Arguments is required)' `
    (-not ($psiProbe.PSObject.Properties.Name -contains 'ArgumentList'))

# Quoting unit checks on ConvertTo-RoboArgLine
$line = ConvertTo-RoboArgLine -RoboArgs @('C:\my files', 'D:\out dir', '/E', '/MT:8')
Write-Host "  arg line -> $line"
Check 'spaced tokens quoted, switches bare' `
    ($line -eq '"C:\my files" "D:\out dir" /E /MT:8')
Check 'trailing-backslash token gets doubled backslash before quote' `
    ((ConvertTo-RoboArgLine -RoboArgs @('C:\dir with space\')) -eq '"C:\dir with space\\"')

# --- Real robocopy through the live-copy mechanism, with a SPACED path ---
$src = Join-Path $Root 'my source'      # space in path on purpose
$dst = Join-Path $Root 'my dest'
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
New-Item -ItemType Directory -Force -Path $src | Out-Null
1..5 | ForEach-Object { Set-Content -Path (Join-Path $src "f$_.txt") -Value "data$_" }

# Build args exactly as the GUI does (New-RoboCopyArgs), then launch via the
# same ProcessStartInfo.Arguments path Start-Pass now uses.
$roboArgs = New-RoboCopyArgs -Source $src -Destination $dst -Threads 4
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'robocopy'
$psi.Arguments = ConvertTo-RoboArgLine -RoboArgs $roboArgs
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
Write-Host "  launching: robocopy $($psi.Arguments)"

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$stdout = $proc.StandardOutput.ReadToEnd()
$proc.WaitForExit()
$code = $proc.ExitCode

Check "robocopy exit code is success range 0-7 (got $code)" ($code -ge 0 -and $code -le 7)
Check 'all 5 files copied to spaced destination (proves quoting works end-to-end)' `
    ((Get-ChildItem $dst -File -ErrorAction SilentlyContinue).Count -eq 5)
Check 'Get-RoboExitMeaning classifies the real exit code as success' `
    ((Get-RoboExitMeaning $code) -match 'Completed')

Remove-Item $Root -Recurse -Force -ErrorAction SilentlyContinue

$total = $pass + $fail
Write-Host "`n  $pass/$total live-copy checks passed" -ForegroundColor $(if($fail -eq 0){'Green'}else{'Red'})
if ($fail -gt 0) { exit 1 }
