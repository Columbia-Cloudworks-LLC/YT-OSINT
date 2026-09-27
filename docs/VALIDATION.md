# Validation

## Automated checks

Use Windows PowerShell 5.1 with ImportExcel and Pester 3.4 or 4.10.1:

```powershell
.\tests\Run-Tests.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-ViewerIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-QueueIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-SubjectsIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-UnifiedQueueIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-SelectionStorageIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-DiscoveryQueueIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-QueuePerformanceIntegration.ps1
```

GitHub Actions runs syntax parsing, the fixture suite, and all seven WPF scripts on Windows (the performance script uses 12,000 rows in CI). Tests use `tests/fixtures/config.json`, not the user's live subject configuration. No YouTube requests are made by these checks.

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

- Long-running multi-channel throughput and memory profiling with representative discovery payloads and captured corpus data.
- Interactive browser playback at timestamp links and a complete accessibility review.
- Clean-machine dependency setup across supported Windows versions and organization policies.
- Disk exhaustion and process/power-loss injection at every persistence boundary.

Local searches scan per-video JSON; there is no database index. Viewer rows are virtualized, but metadata lists, search results, queue history, and Excel exports still use memory proportional to their contents. Clear finished queue history and narrow searches when appropriate.

## Large-queue responsiveness

`Invoke-QueuePerformanceIntegration.ps1` defaults to isolated 12,000-, 50,000-, and 100,000-row fixtures, using the same background-GC host configuration as the app launcher. It drives the actual WPF window through background loading, scrolling, programmatic text edits, sorting, a one-row background update, history clearing with 1,001 selected pending rows, removal of 3,000–5,000 selected pending rows in one command, a simulated active download and pause. It checks row/collection identity, selection and sort retention, actual container virtualization, cached counts, host GC-policy restoration and absence of unrelated corpus refreshes. JSON persistence, locks and scheduler behavior are real; acquisition alone is simulated. Run integrations sequentially.

An Input-priority dispatcher probe samples every 20 ms, reporting additional scheduling delay, with a 95th-percentile budget of 100 ms and maximum of 1,000 ms. This detects stalls, but is not a hardware-independent guarantee of keyboard or mouse latency. Sort time and maximum collection-application slice time are reported separately. Machine load, WPF layout, garbage collection and storage affect timings. Results are saved to ignored `work/queue-performance-results.json`.

`QueueView.Tests.ps1` also checks header sorting and selection retention, incremental notifications/identity, nonadjacent removals, additions, empty queues, cached counts, yielding during large batches, and a single collection change for bulk removal. Snapshots and persistence still require work proportional to queue size; the UI no longer performs queue parsing or full row reconstruction on each update.

Local Windows PowerShell 5.1 results on 2026-09-27 (synthetic fixtures, one complete run):

| Queue rows | Pending rows removed together | P95 extra dispatcher delay | Maximum extra delay | Column sort |
| ---: | ---: | ---: | ---: | ---: |
| 12,000 | 3,000 | 29.6 ms | 231.0 ms | 62.4 ms |
| 50,000 | 5,000 | 29.0 ms | 237.9 ms | 174.8 ms |
| 100,000 | 5,000 | 34.9 ms | 321.5 ms | 244.5 ms |

All three passed the stated budgets, including preservation of 1,001 selected rows during bulk clearing. These timings measure dispatcher availability, not transaction completion: reading and saving the entire JSON document still takes substantial time at 100,000 rows. A storage redesign remains a separate throughput improvement.

## Unified scheduler verification

Channel tests cover subject protection before discovery, duplicate job rejection, real nested-listing parsing without inline downloads, saved channel names, shared batch ownership, cancellation with an active item, discovery of all queued channels before videos, channels added during active downloads, failed discovery continuation, rate-limit pause, interrupted discovery recovery, legacy queue migration, and independent video retry after a failed sync.

`Invoke-UnifiedQueueIntegration.ps1` drives the real Subjects, Channels, and Video Queue controls against an isolated fixture corpus. It verifies A–Z/Z–A sorting without changing selection, both channel label states, queueing another channel while downloading, subject-bound batch imports, duplicate suppression, selective cancellation, and eventual channel unlock. Acquisition is simulated; scheduling, persistence, locking, and UI workers are real. The dedicated screenshot generator below replaces every documented screenshot without exposing personal configuration.

## Queue redesign and storage acceptance

The fixture suite verifies discovery before even older batch URLs, shared video deduplication across discovered channels, discovery of channels added mid-download, and safe pause/resume between discoveries. Clear-finished tests cover every terminal state, shared active jobs, repeated clearing, persistence/reload, accurate failure totals, preserved previous full-sync timestamps, and successful finalization after successful history is cleared. Progress tests distinguish discovery counts from visible video counts.

`Invoke-DiscoveryQueueIntegration.ps1` tests the actual WPF Start/Pause/Pausing button, its bottom-right placement and action icons, discovery/download progress, every colored row badge, and clearing terminal rows during active downloads. It checks that no channel discovery is left behind the completed downloads and that cleared failures still produce partial channel outcomes.

`Invoke-SelectionStorageIntegration.ps1` verifies multi-selection retention during refresh, bulk pending removal, preservation of unsaved subject edits, freshness preferences saved to an isolated profile, switch/create, verified relocation, and a real restart into the moved corpus with the queue paused. Storage fixtures test validation, source/destination runner locks, copied-file verification, and rejection of an incomplete copy.

## Updating all screenshots

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Update-Screenshots.ps1
```

This loads the actual application with isolated sample subjects, channels and queue states. It replaces `docs/screenshot.png`, `docs/dependencies.png`, and the Subjects, Channels, Queue, Discovery and Storage screenshots under `docs/screenshots/`. No live YouTube requests, dependency release checks, or personal configuration are used. The dependency page intentionally shows unqueried sample rows. Inspect the resulting images for clipping, stale controls, misleading status and private data before committing.

For this project, a request to make changes includes implementation, tests, all affected documentation, regeneration/review of all documented screenshots, and commit/push. See the repository's `AGENTS.md`.
