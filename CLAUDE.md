# FastCopy

A GUI for copying large amounts of files over a network, built on top of `robocopy`.

## Robocopy facts & recommendations

These are the vetted robocopy facts the GUI should be built around. All switch
behavior below is per official Microsoft Learn documentation for `robocopy`.

### Guiding principles for mixed small + large files over a network
1. Use multi-threading (`/MT`) for lots of small files.
2. Use unbuffered I/O (`/J`) for very large files.
3. Keep retries low — defaults are extremely high (1,000,000 retries, 30s wait).
4. Run robocopy on one of the servers (source or destination), not a third machine in the middle.
5. For truly mixed datasets, split into two passes by file size.

### Switch reference
- `/E` — copy subdirectories, including empty ones.
- `/MT:n` — multi-threaded copy. Valid range 1–128, default 8. Helps most with many small files. Start at `/MT:16` or `/MT:32`, benchmark before going higher (too many threads increases I/O contention).
- `/J` — unbuffered I/O. Microsoft-recommended for large files. Large files usually need fewer threads (e.g. `/MT:8`) since each file already saturates network/disk.
- `/R:n` — retry count on failed copies. Use `/R:1` to avoid the 1,000,000 default.
- `/W:n` — wait time between retries (seconds). Use `/W:1` to avoid the 30s default.
- `/MAX:n` — exclude files larger than n bytes.
- `/MIN:n` — exclude files smaller than n bytes. (`/MAX` + `/MIN` enable size-based two-pass copies.)
- `/NFL /NDL /NP /NJH /NJS` — reduce console/log noise (no file list, no dir list, no progress %, no job header, no job summary).
- `/LOG:file` — redirect output to a log file. Microsoft notes this *improves performance* on long jobs.
- `/COMPRESS` — request SMB network compression if applicable. Helps when the network is the bottleneck and CPU is available.
- `/COPY:DAT` — default file copy (Data, Attributes, Timestamps).
- `/COPYALL` — also copies ACLs, owner, and auditing info. Only use when security/audit metadata is actually needed; otherwise it adds work.
- `/Z` — restartable mode. Useful on flaky links, but can dramatically reduce throughput on stable LANs. On stable LAN, start *without* `/Z` and benchmark. On unstable WAN/VPN, `/Z` or `/ZB` if resume matters more than raw speed.
- `/MIR` — mirror. Equivalent to `/E` + `/PURGE`; can DELETE destination data not present in source. Only use for intentional mirrors/migrations.

### Recommended command presets

Good default (stable LAN / SMB share):
```bat
robocopy "\\src\share" "\\dst\share" *.* /E /MT:32 /R:1 /W:1 /NFL /NDL /NP /NJH /NJS /LOG:C:\Logs\robo.log
```

Small-file biased:
```bat
robocopy "\\src\share" "\\dst\share" *.* /E /MT:32 /R:1 /W:1 /NFL /NDL /NP /LOG:C:\Logs\robo-small.log
```

Large-file biased:
```bat
robocopy "\\src\share" "\\dst\share" *.* /E /J /MT:8 /R:1 /W:1 /NP /LOG:C:\Logs\robo-large.log
```

Two-pass copy by size (best for truly mixed data):
```bat
:: Pass 1 — small/medium files (<= 256 MB)
robocopy "\\src\share" "\\dst\share" *.* /E /MAX:268435456 /MT:32 /R:1 /W:1 /NFL /NDL /NP /LOG:C:\Logs\robo-small.log
:: Pass 2 — large files (> 256 MB)
robocopy "\\src\share" "\\dst\share" *.* /E /MIN:268435457 /J /MT:8 /R:1 /W:1 /NP /LOG:C:\Logs\robo-large.log
```

Parallel jobs (one per top-level folder) can beat one monolithic run when disks/network can sustain it:
```bat
start "" robocopy "\\src\share\FolderA" "\\dst\share\FolderA" *.* /E /MT:16 /R:1 /W:1 /NP /LOG:C:\Logs\A.log
start "" robocopy "\\src\share\FolderB" "\\dst\share\FolderB" *.* /E /MT:16 /R:1 /W:1 /NP /LOG:C:\Logs\B.log
```

### Real-world tips
- Benchmark `/MT` on a representative subfolder first; the best value is environment-specific.
- For live migrations, bulk seed first, then re-run robocopy for the delta/catch-up pass.

## Auto-tune benchmark script — required fixes (TODO)

A draft PowerShell script that tests several `/MT` values, measures throughput,
picks the fastest, and optionally runs a two-pass small/large copy was reviewed.
Findings were validated against PowerShell 7.6.2 (installed in the dev container).
Note: robocopy is Windows-only and cannot run on Linux, so items tagged
[robocopy-docs] rest on documented behavior, not local execution. When we
build/finish the script, the corrected version MUST address these:

1. **`:Round` is a RUNTIME error, not a parse error.** [verified] The script parses
   clean, but `:Round(...)` throws `The term ':Round' is not recognized...` the moment
   `Run-RoboTest` builds its return object. On Windows the first robocopy copy actually
   runs, then the function throws while assembling its result — so it never returns,
   `$results` stays empty, and `$best[0]` blows up too. Fix: `[math]::Round(...)`.
2. **Keep the summary**: do NOT pass `/NJS` (and avoid `/NJH`) on benchmark runs.
   [robocopy-docs] The `Bytes :` line the script parses lives in the job summary that
   `/NJS` removes, so `$bytes` would always be 0 → every result 0 MBps.
3. **Reset state between runs** [robocopy-docs]: robocopy skips already-copied files, so
   back-to-back tests against the same destination make runs 2..n no-ops. Copy each test
   to a unique throwaway destination (e.g. `$Destination\_bench\MT$Threads`) and delete
   it afterward, or benchmark against a fixed representative sample.
4. **Pass extra args as an array, then splat** — not a single space-joined string.
   [verified] `"/MIN:268435457 /J"` reaches the native command as ONE argument
   (`</MIN:268435457 /J>`); the empty-string default passes a stray empty arg (`<>`).
   `@('/MIN:268435457','/J')` splatted with `@extra` produces two clean args.
5. **Byte parsing** [verified]: default robocopy output uses unit suffixes (e.g.
   `1.234 g`) and the `([\d,]+)` regex captures just `1`; it also reads the **Total**
   column, not **Copied** (a no-op run still reports full Total → fake high MBps).
   Add `/BYTES` for raw counts and parse the **Copied** column (2nd number).
6. **Check `$LASTEXITCODE`** [robocopy-docs]: robocopy success is 0–7 (1 = copied,
   3 = copied+extra, etc.); >=8 is failure. Don't count failed/partial copies as samples.
7. Non-issue (was wrongly flagged): the `Run-RoboTest` verb emits NO warning for a plain
   script [verified] — that only happens on module import. Pure style nit. `*.*` is the
   robocopy default, so it's redundant but harmless.

## Status of `scripts/Measure-RoboCopyThroughput.ps1`

Logic-verified, NOT yet hardware-verified. All checks so far ran against a fake
robocopy stub on PowerShell 7.6.2 (Linux) — argument array, exit-code handling,
`/BYTES` Copied-column parsing, ranking, cleanup, and non-interactive rendering
are confirmed. The actual robocopy invocation has never run, because robocopy is
Windows-only. Run the smoke test below on real Windows before trusting it on a
production copy.

### Windows smoke test (run before trusting on real data)
```powershell
# 1. Small source with mixed file sizes (one >256MB to exercise the split)
mkdir C:\smoke_src
fsutil file createnew C:\smoke_src\big.bin 300000000   # ~300 MB
"hi" | Out-File C:\smoke_src\small.txt

# 2. Fast pass
.\scripts\Measure-RoboCopyThroughput.ps1 -Source C:\smoke_src `
    -Destination C:\smoke_dst -LogDir C:\smoke_logs -ThreadTests 4,8

# 3. Two-pass split
.\scripts\Measure-RoboCopyThroughput.ps1 -Source C:\smoke_src `
    -Destination C:\smoke_dst -LogDir C:\smoke_logs -ThreadTests 4,8 -SplitBySize
```
Confirm against REAL robocopy (the things the Linux stub could not prove):
- RESULTS shows nonzero `MBCopied`/`MBps` → the regex matches real robocopy's
  `/BYTES` summary and reads the Copied column.
- A clean copy reports `ExitCode` 0–7 and `Failed = False` → exit-code mapping is right.
- `C:\smoke_dst\_bench\*` is cleaned up afterward (unless `-KeepData`).
- In `-SplitBySize`, `big.bin` is copied only in the `large` pass and `small.txt`
  only in the `small` pass → `/MAX` / `/MIN` size routing works.

## GUI: `gui/FastCopy.ps1` + `gui/MainWindow.xaml`

WPF front end hosted in PowerShell (Windows only). Source/destination pickers,
robocopy options (threads, retries/wait, `/J`, split-by-size, `/MIR`, `/COMPRESS`,
dry-run `/L`), a live command preview, a streaming log, and an "Auto-tune /MT"
button that launches `scripts/Measure-RoboCopyThroughput.ps1` in its own console.

Run on Windows:
```
powershell -ExecutionPolicy Bypass -File .\gui\FastCopy.ps1
```

Architecture note: the pure, testable logic (`New-RoboCopyArgs`,
`Format-RoboCommand`, `Get-RoboExitMeaning`, `Get-SizeSplitPasses`, plus the
shared quoting helper `ConvertTo-RoboArgLine`) is separated from
`Start-FastCopyGui`. The file guards its entry point with
`if ($MyInvocation.InvocationName -ne '.')`, so dot-sourcing it loads the
functions WITHOUT launching WPF — that's how the logic is unit-tested.

### TARGET RUNTIME: Windows PowerShell 5.1 (.NET Framework 4.8)
This is natively-shipped PowerShell and the REQUIRED target — not PS 7. Code must
avoid PS 7-isms: no `??` / `?.` / ternary / `&&` / `||` / `clean{}` blocks, and
no APIs that exist only on .NET Core / .NET 5+. The one that already bit us:

- **`ProcessStartInfo.ArgumentList` does NOT exist on .NET Framework 4.8.** [verified
  on PS 5.1] The GUI builds the robocopy command as a quoted `.Arguments` string via
  `ConvertTo-RoboArgLine` instead. That helper also backs `Format-RoboCommand`, so the
  on-screen preview is byte-for-byte the command actually launched. It quotes any token
  containing whitespace and doubles trailing backslashes so a quoted path ending in `\`
  can't escape its closing quote. (`$PSNativeCommandUseErrorActionPreference` in the
  benchmark script is a harmless no-op on 5.1; 5.1 native commands never throw on
  nonzero exit, which is the behavior we want anyway.)

### Status — VERIFIED ON WINDOWS 11 / PS 5.1 against REAL robocopy
Test harness: `tests/Run-AllTests.ps1` (23/23) + `tests/Probe-LiveCopyPath.ps1` (6/6).
Confirmed with the actual `robocopy.exe`:
- Benchmark script: `/BYTES` Copied-column parse (nonzero MBCopied), exit-code
  mapping (robocopy exit 1 → not failed), per-test `_bench` isolation, cleanup, and
  **ground-truth size routing** — small pass copied the small files only, large pass
  copied only the >256MB file.
- Pure functions: all arg-building / preview / exit-meaning / split checks pass.
- WPF: `MainWindow.xaml` loads via `XamlReader` and all 19 `x:Name` controls resolve.
- Live-copy path: robocopy launched through the GUI's `ProcessStartInfo.Arguments`
  mechanism copied files into a **destination path containing spaces** (the case the
  old `.ArgumentList` code would have crashed on).

Still NOT exercised interactively (no automated way): clicking through the actual
window — `FolderBrowserDialog` pickers, the Start/Cancel buttons, and the live log
streaming via `Register-ObjectEvent` + `DispatcherTimer` during a real copy. The
underlying mechanisms are verified; the click-path itself should be eyeballed once.
