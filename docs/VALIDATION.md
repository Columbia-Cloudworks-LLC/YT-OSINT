# Validation

## Automated checks

Use Windows PowerShell 5.1 with ImportExcel and Pester 3.4 or 4.10.1:

```powershell
.\tests\Run-Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-ViewerIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-QueueIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-SubjectsIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-UnifiedQueueIntegration.ps1
```

GitHub Actions runs syntax parsing, the fixture suite, and all four WPF scripts on Windows. Tests use `tests/fixtures/config.json`, not the user's live subject configuration. No YouTube requests are made by these checks.

The fixture suite covers configuration and identity, atomic writes, concurrent subject updates, VTT normalization, subtitle selection, cached transcript reuse, searches, timestamp links, acquisition failures, members-only skips, Excel structure, run accounting, persistent rate-limit scheduling, dependency verification, rollback/recovery, and maintenance locks.

Queue tests cover URL normalization and duplicate detection; whole-batch validation; stable subject assignments and rename guards; adding/removing work during an active import; sequential completion and ordinary failure continuation; rate-limit halting; pause/cancel/retry; abandoned-item recovery; runner exclusion; and actual cached ingestion through the queue-owned corpus lock. Concurrent runspaces edit configuration to check for lost updates.

## Actual WPF interaction

The viewer integration test exercises literal punctuation and Unicode matching, repeated highlights, empty/no-match results, row recycling, debounce, navigation, filtering, and virtualization with 5,003 segments. The main-window test checks metadata filtering, background caption search, numeric/timestamp column sorting in both directions, ignoring header/background double-clicks, and opening a transcript from a row.

The queue integration test replaces acquisition with a local adapter that deliberately holds a download open. While the queue worker is active, it drives the actual GUI to create and rename an unrelated subject, verify queued-subject name protection, append a URL, remove a pending item, and complete a corpus search. It then pauses after the current item, resumes, and closes during another active item to verify paused recovery. Queue files, synchronization, UI controls, and background workers are the real implementation.

This validates concurrency and interaction with controlled acquisition. It does not establish current YouTube availability or guarantee avoidance of rate limits.

The subject integration test exercises the actual name prompt and cancellation, automatic selection of a new subject, the right-hand channel pane, safe removal, archived search choices, and same-name recreation with a different ID and no inherited channels. Fixture tests also compare captured JSON bytes before/after archival, verify queued removal guards, and check that overlapping imports retain archived video ownership.

## Workbook and captured-data verification

The earlier captured corpus used for repair testing contained 113 video records and 18,951 transcript segments. Thirty-four members-only failure records were backed up and reclassified using saved listings, without new YouTube requests. Historical run logs were retained.

Excel previously rejected workbooks with overlapping worksheet-level and table-level AutoFilters. The exporter now uses a table filter when a table exists and a worksheet filter for header-only sheets. The rebuilt workbook opened normally in desktop Excel with all four tables retained. This optional check requires Excel:

```powershell
.\tests\Invoke-ExcelIntegration.ps1 -Path 'C:\path\to\YouTubeCorpus.xlsx'
```

A previous live attempt with yt-dlp 2025.01.26 failed with extractor errors. That is historical evidence, not a restriction on updates: current dependencies are maintained in the user's folder and can be updated from Settings. The subsequent user-provided corpus demonstrates successful capture; no fresh network acquisition is needed for queue regression tests.

## Separate integrations

- `Invoke-LiveIntegration.ps1`: downloads metadata/captions for the user's configured channels into an isolated corpus. May encounter rate limits; use a small limit deliberately.
- `Invoke-DependencyIntegration.ps1`: downloads upstream releases and tests verification/replacement in a temporary directory.
- `Invoke-RateLimitIntegration.ps1`: exercises native subtitle behavior against controlled local HTTP fixtures.
- `Invoke-RestartIntegration.ps1`: checks the automatic application restart handshake.

Do not run integrations that own dependency locks concurrently.

## Remaining manual checks

- Large multi-channel or multi-thousand-video queue throughput and memory profiling.
- Interactive browser playback at timestamp links and a complete accessibility review.
- Clean-machine dependency setup across supported Windows versions and organization policies.
- Disk exhaustion and process/power-loss injection at every persistence boundary.

Local searches scan per-video JSON; there is no database index. Viewer rows are virtualized, but metadata lists, search results, queue history, and Excel exports still use memory proportional to their contents. Clear finished queue history and narrow searches when appropriate.

## Unified scheduler verification

Channel tests cover subject protection before discovery, duplicate job rejection, real nested-listing parsing without inline downloads, saved channel names, shared batch ownership, cancellation with an active item, serial channel jobs, failed discovery continuation, rate-limit pause, interrupted discovery recovery, legacy queue migration, and independent video retry after a failed sync.

`Invoke-UnifiedQueueIntegration.ps1` drives the real Subjects, Channels, and Video Queue controls against an isolated fixture corpus. It verifies A–Z/Z–A sorting without changing selection, both channel label states, queueing another channel while downloading, subject-bound batch imports, duplicate suppression, selective cancellation, and eventual channel unlock. Acquisition is simulated; scheduling, persistence, locking, and UI workers are real. Run with `-ScreenshotDirectory .\docs\screenshots` to capture the three README screenshots without exposing personal configuration.
