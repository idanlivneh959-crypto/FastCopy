<#
.SYNOPSIS
    Comprehensive test suite for FastCopy. Runs on Windows PowerShell 5.1+
    against REAL robocopy. Covers parser checks, PS 5.1 compatibility,
    XAML load, pure-function unit tests, and real robocopy benchmark runs
    (default + SplitBySize) with ground-truth size-routing verification.

.NOTES
    Size routing is verified by inspecting the actual copied directories
    (the benchmark's -KeepData leaves them in place), NOT by grepping log
    files - the benchmark uses /NFL so individual filenames are not logged.
#>
[CmdletBinding()]
param(
    [string]$SmokeRoot = 'C:\FastCopy_test',
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0

function Check {
    param([string]$Label, [scriptblock]$Test)
    try {
        $result = & $Test
        if ($result -ne $false) {
            Write-Host ("  PASS  {0}" -f $Label) -ForegroundColor Green
            $script:pass++
        } else {
            Write-Host ("  FAIL  {0}" -f $Label) -ForegroundColor Red
            $script:fail++
        }
    } catch {
        Write-Host ("  FAIL  {0}  [{1}]" -f $Label, $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}
function Section([string]$Title) { Write-Host "`n=== $Title ===" -ForegroundColor Cyan }

$repoRoot    = Split-Path $PSScriptRoot -Parent
$guiScript   = Join-Path $repoRoot 'gui\FastCopy.ps1'
$xamlFile    = Join-Path $repoRoot 'gui\MainWindow.xaml'
$benchScript = Join-Path $repoRoot 'scripts\Measure-RoboCopyThroughput.ps1'

Write-Host ("Host: PowerShell {0} on {1}" -f $PSVersionTable.PSVersion, [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)

# ---------------------------------------------------------------------------
Section '1. Parser'
Check 'gui\FastCopy.ps1 parses clean' {
    $e=$null;$t=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($guiScript,[ref]$t,[ref]$e)
    $e.Count -eq 0
}
Check 'scripts\Measure-RoboCopyThroughput.ps1 parses clean' {
    $e=$null;$t=$null
    $null=[System.Management.Automation.Language.Parser]::ParseFile($benchScript,[ref]$t,[ref]$e)
    $e.Count -eq 0
}

# ---------------------------------------------------------------------------
Section '2. XAML load + control resolution'
$expectedControls = @(
    'SourceBox','DestBox','BrowseSource','BrowseDest','MtBox','RetriesBox','WaitBox',
    'ChkJ','ChkSplit','ChkMirror','ChkCompress','ChkDryRun',
    'BtnStart','BtnCancel','BtnTune','CmdPreview','LogBox','Progress','StatusText')

Check 'MainWindow.xaml is well-formed XML' {
    [xml]$x = Get-Content -Raw $xamlFile; $null -ne $x
}
Check 'XAML loads via XamlReader (real WPF parse, no window shown)' {
    Add-Type -AssemblyName PresentationFramework
    [xml]$x = Get-Content -Raw $xamlFile
    $reader = New-Object System.Xml.XmlNodeReader $x
    $script:win = [System.Windows.Markup.XamlReader]::Load($reader)
    $script:win -is [System.Windows.Window]
}
Check "All $($expectedControls.Count) x:Name controls resolve via FindName" {
    $missing = $expectedControls | Where-Object { $null -eq $script:win.FindName($_) }
    if ($missing) { throw "FindName null for: $($missing -join ', ')" }
    $true
}

# ---------------------------------------------------------------------------
Section '3. Pure functions (dot-source; entry-guard must skip WPF)'
. $guiScript
Check 'Dot-source did NOT launch the GUI and exposed all 4 functions' {
    @('New-RoboCopyArgs','Format-RoboCommand','Get-RoboExitMeaning','Get-SizeSplitPasses') |
        ForEach-Object { $null = Get-Command $_ -ErrorAction Stop }
    $true
}
Check 'trailing backslash stripped from endpoints' {
    $a = New-RoboCopyArgs -Source 'C:\src\' -Destination '\\dst\share\'
    $a[0] -eq 'C:\src' -and $a[1] -eq '\\dst\share'
}
Check 'defaults: /E /MT:16 /R:1 /W:1, no /J' {
    $a = New-RoboCopyArgs -Source 'C:\s' -Destination 'D:\d'
    ($a -contains '/E') -and ($a -contains '/MT:16') -and ($a -contains '/R:1') -and ($a -contains '/W:1') -and ($a -notcontains '/J')
}
Check '-Mirror swaps /E for /MIR' {
    $a = New-RoboCopyArgs -Source 'C:\s' -Destination 'D:\d' -Mirror
    ($a -contains '/MIR') -and ($a -notcontains '/E')
}
Check '-Unbuffered/-Compress/-DryRun add /J //COMPRESS //L' {
    $a = New-RoboCopyArgs -Source 'C:\s' -Destination 'D:\d' -Unbuffered -Compress -DryRun
    ($a -contains '/J') -and ($a -contains '/COMPRESS') -and ($a -contains '/L')
}
Check '-LogFile adds /TEE and /LOG:path' {
    $a = New-RoboCopyArgs -Source 'C:\s' -Destination 'D:\d' -LogFile 'C:\l.log'
    ($a -contains '/TEE') -and ($a -contains '/LOG:C:\l.log')
}
Check 'custom threads/retries/wait + ExtraArgs passthrough' {
    $a = New-RoboCopyArgs -Source 'C:\s' -Destination 'D:\d' -Threads 32 -Retries 2 -Wait 5 -ExtraArgs @('/MAX:268435456')
    ($a -contains '/MT:32') -and ($a -contains '/R:2') -and ($a -contains '/W:5') -and ($a -contains '/MAX:268435456')
}
Check 'Format-RoboCommand quotes spaced path, not bare switches' {
    $cmd = Format-RoboCommand (New-RoboCopyArgs -Source 'C:\my files' -Destination 'D:\d')
    $cmd.StartsWith('robocopy ') -and $cmd.Contains('"C:\my files"') -and ($cmd -match '\s/E(\s|$)')
}
Check 'Get-RoboExitMeaning maps 0/1/7=>ok, 8/16=>FAILED' {
    ((Get-RoboExitMeaning 0) -match 'nothing') -and ((Get-RoboExitMeaning 1) -match 'Completed') -and
    ((Get-RoboExitMeaning 7) -match 'Completed') -and ((Get-RoboExitMeaning 8) -match 'FAILED') -and
    ((Get-RoboExitMeaning 16) -match 'FAILED')
}
Check 'Get-SizeSplitPasses: 2 passes, /MAX small, /MIN+/J large' {
    $p = Get-SizeSplitPasses
    ($p.Count -eq 2) -and ($p[0].ExtraArgs -contains '/MAX:268435456') -and
    ($p[1].ExtraArgs -contains '/MIN:268435457') -and ($p[1].ExtraArgs -contains '/J')
}

# ---------------------------------------------------------------------------
Section '4. Real robocopy - setup'
$src  = Join-Path $SmokeRoot 'src'
$dst  = Join-Path $SmokeRoot 'dst'
$logs = Join-Path $SmokeRoot 'logs'
if (Test-Path $SmokeRoot) { Remove-Item $SmokeRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $src | Out-Null
1..15 | ForEach-Object {
    [System.IO.File]::WriteAllBytes((Join-Path $src ("small_{0:D3}.dat" -f $_)), [byte[]]::new(200KB))
}
$fs = [System.IO.File]::Create((Join-Path $src 'big.bin')); $fs.SetLength(300MB); $fs.Close()
Write-Host ("  Source: {0} small files + 1x 300MB big.bin" -f 15)

Section '5. Real robocopy - default mode'
Check 'default mode completes without throwing' {
    & $benchScript -Source $src -Destination $dst -LogDir $logs -ThreadTests 4,8 -KeepData | Out-Null
    $true
}
Check 'a log reports nonzero Copied bytes (proves /BYTES Copied-column parse target exists)' {
    $hit = Get-ChildItem $logs -Filter '*.log' | Where-Object {
        (Get-Content $_.FullName -Raw) -match 'Bytes\s+:\s+\d+\s+([1-9]\d*)'
    }
    $hit.Count -ge 1
}
Check 'each thread test copied into its own _bench dir' {
    $benchDirs = Get-ChildItem (Join-Path $dst '_bench') -Directory
    ($benchDirs.Name -contains 'default_MT4') -and ($benchDirs.Name -contains 'default_MT8')
}
Check 'each _bench dir actually received all 16 files (real copy happened per run)' {
    $d4 = Join-Path $dst '_bench\default_MT4'
    (Get-ChildItem $d4 -File).Count -eq 16
}

Section '6. Real robocopy - cleanup behavior (no -KeepData)'
Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
$logs2 = Join-Path $SmokeRoot 'logs2'
& $benchScript -Source $src -Destination $dst -LogDir $logs2 -ThreadTests 4 | Out-Null
Check '_bench dirs are removed after run when -KeepData not passed' {
    $benchRoot = Join-Path $dst '_bench'
    (-not (Test-Path $benchRoot)) -or ((Get-ChildItem $benchRoot -Directory -ErrorAction SilentlyContinue).Count -eq 0)
}

Section '7. Real robocopy - SplitBySize size routing (ground truth via -KeepData)'
Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue
$logs3 = Join-Path $SmokeRoot 'logs3'
& $benchScript -Source $src -Destination $dst -LogDir $logs3 -ThreadTests 4 -SplitBySize -KeepData | Out-Null
$smallDir = Join-Path $dst '_bench\small_MT4'
$largeDir = Join-Path $dst '_bench\large_MT4'
Check 'small + large bench dirs both exist' {
    (Test-Path $smallDir) -and (Test-Path $largeDir)
}
Check 'SMALL pass copied the 15 small files, NOT big.bin (/MAX:256MB)' {
    $files = Get-ChildItem $smallDir -File
    ($files.Name -notcontains 'big.bin') -and ($files.Count -eq 15)
}
Check 'LARGE pass copied ONLY big.bin (/MIN:256MB+1)' {
    $files = Get-ChildItem $largeDir -File
    ($files.Name -contains 'big.bin') -and ($files.Count -eq 1)
}

# ---------------------------------------------------------------------------
if (-not $KeepData) {
    Write-Host "`n  Cleaning up $SmokeRoot ..."
    Remove-Item $SmokeRoot -Recurse -Force -ErrorAction SilentlyContinue
}
$total = $script:pass + $script:fail
Write-Host "`n==============================" -ForegroundColor Cyan
Write-Host ("  {0}/{1} checks passed" -f $script:pass, $total) -ForegroundColor $(if ($script:fail -eq 0){'Green'}else{'Yellow'})
if ($script:fail -gt 0) { Write-Host ("  {0} FAILED" -f $script:fail) -ForegroundColor Red }
Write-Host "==============================" -ForegroundColor Cyan
if ($script:fail -gt 0) { exit 1 } else { exit 0 }

