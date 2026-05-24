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
