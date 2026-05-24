<#
.SYNOPSIS
    FastCopy - a WPF front end (hosted in PowerShell) for copying files with robocopy.

.DESCRIPTION
    Source/destination pickers, common robocopy options, a live log, and an
    "Auto-tune /MT" button that launches scripts/Measure-RoboCopyThroughput.ps1.

    The argument-building helpers (New-RoboCopyArgs, Format-RoboCommand) are pure
    and unit-testable. The GUI itself (Start-FastCopyGui) requires Windows
    (PresentationFramework) and is not exercised on non-Windows hosts.

.NOTES
    Run on Windows:  powershell -ExecutionPolicy Bypass -File .\gui\FastCopy.ps1
#>
[CmdletBinding()]
param()

# ---------------------------------------------------------------------------
# Pure logic (testable without WPF)
# ---------------------------------------------------------------------------

function New-RoboCopyArgs {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Threads  = 16,
        [int]$Retries  = 1,
        [int]$Wait     = 1,
        [switch]$Unbuffered,
        [switch]$Mirror,
        [switch]$Compress,
        [switch]$DryRun,
        [string[]]$ExtraArgs = @(),
        [string]$LogFile
    )

    # robocopy treats a trailing backslash inside a quoted path as an escape of
    # the closing quote, so strip trailing separators from the endpoints.
    $src = $Source.TrimEnd('\', '/')
    $dst = $Destination.TrimEnd('\', '/')

    $roboArgs = [System.Collections.Generic.List[string]]::new()
    $roboArgs.Add($src)
    $roboArgs.Add($dst)
    $roboArgs.Add($(if ($Mirror) { '/MIR' } else { '/E' }))
    $roboArgs.Add("/MT:$Threads")
    $roboArgs.Add("/R:$Retries")
    $roboArgs.Add("/W:$Wait")
    if ($Unbuffered) { $roboArgs.Add('/J') }
    if ($Compress)   { $roboArgs.Add('/COMPRESS') }
    if ($DryRun)     { $roboArgs.Add('/L') }      # list only, copies nothing
    foreach ($a in $ExtraArgs) { $roboArgs.Add($a) }
    if ($LogFile) {
        $roboArgs.Add('/TEE')                     # console AND log file
        $roboArgs.Add("/LOG:$LogFile")
    }
    return $roboArgs.ToArray()
}

function Format-RoboCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$RoboArgs)

    $quoted = foreach ($a in $RoboArgs) {
        if ($a -match '\s') { '"{0}"' -f $a } else { $a }
    }
    return 'robocopy ' + ($quoted -join ' ')
}

function Get-RoboExitMeaning {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$Code)

    # robocopy: 0 = nothing to do, 1-7 = success (copied/extra/mismatch),
    # >=8 = at least one failure.
    if ($Code -ge 8)    { return "FAILED (exit $Code)" }
    if ($Code -eq 0)    { return "Completed - nothing to copy (exit 0)" }
    return "Completed (exit $Code)"
}

function Get-SizeSplitPasses {
    <# Returns the ordered ExtraArgs/label pairs for a two-pass size split. #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([long]$ThresholdBytes = 268435456)   # 256 MB

    return @(
        @{ Label = 'small'; ExtraArgs = @("/MAX:$ThresholdBytes") }
        @{ Label = 'large'; ExtraArgs = @("/MIN:$($ThresholdBytes + 1)", '/J') }
    )
}

# ---------------------------------------------------------------------------
# WPF GUI (Windows only)
# ---------------------------------------------------------------------------

function Start-FastCopyGui {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName System.Windows.Forms   # FolderBrowserDialog

    $xamlPath = Join-Path $PSScriptRoot 'MainWindow.xaml'
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $script:Window = [System.Windows.Markup.XamlReader]::Load($reader)

    # Resolve named controls into a hashtable for easy access from handlers.
    $script:UI = @{}
    foreach ($name in @(
            'SourceBox', 'DestBox', 'BrowseSource', 'BrowseDest',
            'MtBox', 'RetriesBox', 'WaitBox',
            'ChkJ', 'ChkSplit', 'ChkMirror', 'ChkCompress', 'ChkDryRun',
            'BtnStart', 'BtnCancel', 'BtnTune',
            'CmdPreview', 'LogBox', 'Progress', 'StatusText')) {
        $script:UI[$name] = $script:Window.FindName($name)
    }

    # Shared run state.
    $script:Proc      = $null
    $script:OutQueue  = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $script:Passes    = @()
    $script:PassIndex = 0

    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $script:Timer.Add_Tick({ Update-RunState })

    # --- handlers ---
    $script:UI.BrowseSource.Add_Click({ Select-Folder -Target 'SourceBox' })
    $script:UI.BrowseDest.Add_Click({ Select-Folder -Target 'DestBox' })

    $previewHandler = { Update-Preview }
    foreach ($n in 'SourceBox', 'DestBox', 'MtBox', 'RetriesBox', 'WaitBox') {
        $script:UI[$n].Add_TextChanged($previewHandler)
    }
    foreach ($n in 'ChkJ', 'ChkSplit', 'ChkMirror', 'ChkCompress', 'ChkDryRun') {
        $script:UI[$n].Add_Click($previewHandler)
    }

    $script:UI.BtnStart.Add_Click({ Start-Copy })
    $script:UI.BtnCancel.Add_Click({ Stop-Copy })
    $script:UI.BtnTune.Add_Click({ Start-AutoTune })

    Update-Preview
    $script:Window.ShowDialog() | Out-Null
}

function Select-Folder {
    param([string]$Target)
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:UI[$Target].Text = $dlg.SelectedPath
    }
}

function Add-Log {
    param([string]$Text)
    if ($null -eq $Text) { return }
    $script:UI.LogBox.AppendText($Text + [Environment]::NewLine)
    $script:UI.LogBox.ScrollToEnd()
}

function Get-UiInt {
    param([string]$Text, [int]$Default)
    $value = $Default
    if ([int]::TryParse($Text, [ref]$value)) { return $value }
    return $Default
}

function Get-UiRoboArgs {
    param([string[]]$ExtraArgs = @(), [string]$LogFile)
    New-RoboCopyArgs `
        -Source      $script:UI.SourceBox.Text `
        -Destination $script:UI.DestBox.Text `
        -Threads     (Get-UiInt $script:UI.MtBox.Text 16) `
        -Retries     (Get-UiInt $script:UI.RetriesBox.Text 1) `
        -Wait        (Get-UiInt $script:UI.WaitBox.Text 1) `
        -Unbuffered:([bool]$script:UI.ChkJ.IsChecked) `
        -Mirror:([bool]$script:UI.ChkMirror.IsChecked) `
        -Compress:([bool]$script:UI.ChkCompress.IsChecked) `
        -DryRun:([bool]$script:UI.ChkDryRun.IsChecked) `
        -ExtraArgs   $ExtraArgs `
        -LogFile     $LogFile
}

function Update-Preview {
    if ([string]::IsNullOrWhiteSpace($script:UI.SourceBox.Text) -or
        [string]::IsNullOrWhiteSpace($script:UI.DestBox.Text)) {
        $script:UI.CmdPreview.Text = 'robocopy <source> <destination> ...'
        return
    }

    if ([bool]$script:UI.ChkSplit.IsChecked) {
        $lines = foreach ($pass in Get-SizeSplitPasses) {
            Format-RoboCommand (Get-UiRoboArgs -ExtraArgs $pass.ExtraArgs)
        }
        $script:UI.CmdPreview.Text = $lines -join [Environment]::NewLine
    }
    else {
        $script:UI.CmdPreview.Text = Format-RoboCommand (Get-UiRoboArgs)
    }
}

function Start-Copy {
    if ([string]::IsNullOrWhiteSpace($script:UI.SourceBox.Text) -or
        [string]::IsNullOrWhiteSpace($script:UI.DestBox.Text)) {
        [System.Windows.MessageBox]::Show('Please set both a source and a destination.',
            'FastCopy', 'OK', 'Warning') | Out-Null
        return
    }

    $logDir = Join-Path $env:TEMP 'FastCopy'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    if ([bool]$script:UI.ChkSplit.IsChecked) {
        $script:Passes = foreach ($pass in Get-SizeSplitPasses) {
            @{
                Label = $pass.Label
                Args  = Get-UiRoboArgs -ExtraArgs $pass.ExtraArgs `
                            -LogFile (Join-Path $logDir "robo_$($pass.Label)_$stamp.log")
            }
        }
    }
    else {
        $script:Passes = @(@{
            Label = 'copy'
            Args  = Get-UiRoboArgs -LogFile (Join-Path $logDir "robo_$stamp.log")
        })
    }

    $script:PassIndex = 0
    Set-RunningState -Running $true
    $script:UI.LogBox.Clear()
    Start-Pass
}

function Start-Pass {
    $pass = $script:Passes[$script:PassIndex]
    Add-Log "=== Pass '$($pass.Label)': $(Format-RoboCommand $pass.Args) ==="

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'robocopy'
    foreach ($a in $pass.Args) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true

    $script:Proc = [System.Diagnostics.Process]::new()
    $script:Proc.StartInfo = $psi
    $script:Proc.EnableRaisingEvents = $true

    # Output arrives on threadpool threads; only enqueue here (no UI access).
    # The DispatcherTimer drains the queue on the UI thread.
    $enqueue = { if ($null -ne $EventArgs.Data) { $script:OutQueue.Enqueue($EventArgs.Data) } }
    Register-ObjectEvent -InputObject $script:Proc -EventName OutputDataReceived -Action $enqueue | Out-Null
    Register-ObjectEvent -InputObject $script:Proc -EventName ErrorDataReceived  -Action $enqueue | Out-Null

    $script:UI.StatusText.Text = "Running pass '$($pass.Label)'..."
    [void]$script:Proc.Start()
    $script:Proc.BeginOutputReadLine()
    $script:Proc.BeginErrorReadLine()
    $script:Timer.Start()
}

function Update-RunState {
    $line = $null
    while ($script:OutQueue.TryDequeue([ref]$line)) { Add-Log $line }

    if ($script:Proc -and $script:Proc.HasExited) {
        while ($script:OutQueue.TryDequeue([ref]$line)) { Add-Log $line }
        $code = $script:Proc.ExitCode

        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $script:Proc } | Unregister-Event
        $script:Proc.Dispose()
        $script:Proc = $null

        $pass = $script:Passes[$script:PassIndex]
        Add-Log "--- Pass '$($pass.Label)': $(Get-RoboExitMeaning $code) ---"

        $script:PassIndex++
        if ($script:PassIndex -lt $script:Passes.Count) {
            Start-Pass
        }
        else {
            $script:Timer.Stop()
            Set-RunningState -Running $false
            $script:UI.StatusText.Text = 'Done.'
        }
    }
}

function Stop-Copy {
    if ($script:Proc -and -not $script:Proc.HasExited) {
        try { $script:Proc.Kill() } catch { }
        Add-Log '*** Cancelled by user ***'
    }
    # Skip any remaining passes.
    $script:PassIndex = [int]::MaxValue
}

function Set-RunningState {
    param([bool]$Running)
    $script:UI.BtnStart.IsEnabled  = -not $Running
    $script:UI.BtnTune.IsEnabled   = -not $Running
    $script:UI.BtnCancel.IsEnabled = $Running
    $script:UI.Progress.IsIndeterminate = $Running
}

function Start-AutoTune {
    if ([string]::IsNullOrWhiteSpace($script:UI.SourceBox.Text) -or
        [string]::IsNullOrWhiteSpace($script:UI.DestBox.Text)) {
        [System.Windows.MessageBox]::Show('Set a source and destination before auto-tuning.',
            'FastCopy', 'OK', 'Warning') | Out-Null
        return
    }

    $benchmark = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Measure-RoboCopyThroughput.ps1'
    $logDir = Join-Path $env:TEMP 'FastCopy\tune'

    # Launch in its own console so the GUI stays responsive while it benchmarks.
    $psArgs = @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $benchmark,
        '-Source', $script:UI.SourceBox.Text,
        '-Destination', $script:UI.DestBox.Text,
        '-LogDir', $logDir
    )
    if ([bool]$script:UI.ChkSplit.IsChecked) { $psArgs += '-SplitBySize' }

    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs
    $script:UI.StatusText.Text = 'Auto-tune launched in a separate window.'
}

# ---------------------------------------------------------------------------
# Entry point (skipped when the file is dot-sourced, e.g. for testing)
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    Start-FastCopyGui
}
