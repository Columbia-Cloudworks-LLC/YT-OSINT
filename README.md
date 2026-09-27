# YT-OSINT

A Windows-native PowerShell/WPF utility for collecting YouTube metadata and English transcripts into a local, searchable evidence corpus. Queue batches of videos, read and search timestamped transcripts in the GUI, and optionally export an Excel workbook. No Excel installation, API key, web server, Python runtime, or database is required.

**Validation status:** Windows fixture tests and real WPF interaction tests cover the import queue, concurrent subject editing, transcript viewer, search, and sorting. Tests run against isolated fixture configurations, never your personal subject list. See [validation details](docs/VALIDATION.md) and the [queue guide](docs/QUEUE.md).

## First launch

Use 64-bit Windows 10/11 with Windows PowerShell 5.1 and .NET Framework 4.8. Extract or clone the repository into a user-writable local folder. Start:

```powershell
.\Start-YouTubeCorpus.bat
```

Equivalent command:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\YouTubeCorpus.ps1
```

Execution-policy bypass applies only to that process. It does not change machine policy. Organization-enforced execution restrictions still apply. The application needs network access to YouTube, GitHub releases, gyan.dev, and PowerShell Gallery during the relevant operations.

The initial subject is **Mo**, explicitly associated with `https://www.youtube.com/@atmoio` and `https://www.youtube.com/@lessbitter`. These are configuration entries, not special cases in application code. Importing is an explicit user action; startup does not sync channels or automatically resume a saved queue. When updating an existing installation, preserve your own `config.json` and `data/`.

## Dependencies

Native tools live in `%LOCALAPPDATA%\YT-OSINT\bin`: `yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`, and `deno.exe`. Installation and updates run as the current user without UAC. The app uses these exact paths, including yt-dlp's FFmpeg and JavaScript runtime options, without modifying PATH. Existing Windows-directory or PATH copies are not used or changed.

Startup installs missing tools from verified upstream packages. Existing user-folder versions are preserved until you choose an update. FFmpeg and ffprobe are installed and repaired together. Deno is included for yt-dlp's YouTube support. ARM64 Windows requires x64 emulation for these binaries.

ImportExcel is loaded if available; otherwise the verified Gallery package is installed into the current user's WindowsPowerShell module directory. Excel itself is unnecessary. Download and verification progress appear in the status bar; errors are saved in per-run logs. Settings remains accessible if installation fails.

**Existing yt-dlp versions may stop working when YouTube changes.** Use Settings → Dependencies to check and update. Do not interpret extraction failures as empty channels.

Sources: [yt-dlp](https://github.com/yt-dlp/yt-dlp), [Gyan FFmpeg essentials](https://www.gyan.dev/ffmpeg/builds/), [Deno](https://github.com/denoland/deno), and [ImportExcel](https://www.powershellgallery.com/packages/ImportExcel).

## Safe dependency updates

![Dependency management page](docs/dependencies.png)

Settings → Dependencies shows installed and available versions, providers, and paths. Startup checks releases in the background at most once every 24 hours; **Check now** bypasses the cache. Checks only fetch metadata and probe local versions. Network failures show **Unknown** and disable the affected update. GitHub requests are unauthenticated and may be rate limited.

Select dependencies and press **Update selected**. The short confirmation tells you the application will restart automatically after successful updates. Changing yt-dlp's stable/nightly channel requires a new check; the preference is saved when the update succeeds. Unfamiliar FFmpeg versions are labeled **Different channel / build**; replacements use the Gyan essentials pair. Newer versions on the same channel are not automatically downgraded.

Updates download into user-owned staging and verify GitHub/Gyan SHA256 or Gallery SHA512 package hashes before running candidates. Native files are backed up, journaled, replaced, and verified again. A failure rolls back that dependency; FFmpeg/ffprobe are one rollback unit. ImportExcel versions are installed side by side and verified with a fresh-process XLSX round-trip before selecting the new manifest.

After success, the GUI closes and relaunches with the same corpus root and the Dependencies page open. On failure or cancellation it stays open and shows the error. If some dependencies already changed, **Restart now** reloads them; imports remain disabled until restart. Closing during installation waits for a safe boundary and respects the request to close. Command-line updates report their result without opening a GUI.

Session-wide locks exclude imports and other maintenance during installation. A durable journal supports recovery after interruption: use **Recover interrupted update** to restore the recorded originals. Recovery refuses to overwrite externally changed files. No elevation is involved.

Native staging, backups, and journals live in `%LOCALAPPDATA%\YT-OSINT\updates`. Completed downloads are removed; backups remain until you choose to remove them. Never delete pending recovery records. Per-corpus settings and the daily cache live in `data/dependencies/`; logs remain under `logs/`. This migration does not use old Windows-directory update journals or backups.

Command-line equivalents (run from the repository):

```powershell
.\Update-Dependencies.ps1 -Action Check -Force
.\Update-Dependencies.ps1 -Action Check -Channel nightly -Force
.\Update-Dependencies.ps1 -Action Update -Name yt-dlp,Deno -Channel stable
.\Update-Dependencies.ps1 -Action Recover
```

The CLI Update action is itself the explicit update request. Native tools and ImportExcel are updated without elevation. Pester is a development dependency pinned to supported major versions, and Windows PowerShell/.NET remain under Windows servicing.

## Subtitle pacing and rate limits

Imports reuse valid saved English transcripts before sending video requests. To fetch them again, select **Refresh saved transcripts** on Channels or **Refresh saved transcripts** on Video Queue before adding URLs. The command-line equivalent is `-RefreshTranscript`. Cached imports keep their original capture timestamps; missing or malformed cache files are fetched again.

Caption selection prefers manual English, then original automatic English (`en-orig` when available). Translated URLs containing `tlang` are excluded, including translated entries mixed into a generic `en` track. Videos offering only translations are recorded as unavailable. The complete original metadata is retained; the downloader receives a separate copy containing only the selected caption track.

Requests are sequential, with 10 seconds between yt-dlp invocations, 1 second between extraction requests, and 10 seconds before subtitle downloads. The app controls retries and disables yt-dlp's immediate subtitle re-extraction fallback.

On HTTP 429, the entire sync queue pauses for **2, 4, then 8 minutes** before retrying. The status bar, or the Video Queue status during batch imports, shows a countdown; cancellation remains available. A fourth 429 stops the run as **RateLimited**, without scheduling another video or channel. Completed metadata and transcripts remain saved; build the workbook separately if needed. For the persistent video queue, the active item returns to Pending and the queue pauses. Resume explicitly after the cooldown.

Cooldown deadlines and retry counts are saved in `%LOCALAPPDATA%\YT-OSINT\youtube-requests.json`, shared across this user's corpora and preserved across restarts. After retry exhaustion, wait at least another 8 minutes before explicitly starting a new sync. Metadata success alone does not reset subtitle backoff; a successful caption request does. These delays reduce unnecessary traffic but cannot guarantee that YouTube will accept a request.

## Desktop workflow

1. **Subjects:** select a subject in the left pane to see its channels on the right. **Add subject** prompts for a name, refreshes the list, and selects the new subject so you can add channels immediately. Rename the selected subject using its name field. **Remove subject** asks for confirmation, then archives the subject; captured files remain unchanged. Pending/Running queue items block both rename and removal. Removal also waits for capture/export work to be idle, preventing assignment races. New subjects and unrelated subjects remain editable during queued downloads.
2. **Channels:** select a configured source and sync it, or sync all sources. The table shows stable IDs, counts, last attempt, last successful sync, and status. URLs resolving to the same channel ID share canonical channel state. Conflicting subject ownership is rejected while the prior association is active. Channel sync remains a separate operation; finish or pause the video queue before starting one.
3. **Video Queue:** paste one video URL per line, choose a subject, and press **Add URLs to queue**. Invalid batches are rejected with line numbers; duplicate pending/active video IDs are skipped. Press **Start / resume** to process items sequentially. Use **Pause after current**, **Cancel current and pause**, **Remove pending item**, **Retry selected**, and **Clear finished** to manage work. Titles appear when already known or after an import. Leaving the subject unassigned preserves an existing video’s subject. See the [queue guide](docs/QUEUE.md).
4. **Corpus:** use **Find videos** to filter metadata or **Find in transcripts** to search captions, with optional subject/channel/video/date filters. Both use the same literal query field. Click a column header to sort ascending; click again for descending. Double-click a video or search result, or select it and press **Read transcript**. There is no separate Search tab. Button icons distinguish the transcript reader, YouTube links, Excel, and workbook export; text labels remain visible. The bundled vector icons work offline and scale with Windows display settings.
5. **Transcript viewer:** read the full timestamped transcript. Type literal text to highlight every occurrence within each segment, ignoring case. **Previous match** and **Next match** navigate matching segments and wrap around; **Show matching segments only** hides other rows. Clear the query to restore the full transcript. Double-click a segment or use **Open selected timestamp** to open YouTube. Missing transcripts show an empty-state message. The viewer renders visible rows on demand, and loads only the selected video's saved transcript.
6. **Excel export:** GUI imports save the corpus without rebuilding Excel by default. Use **Export Excel workbook** when needed, or enable **Also export Excel after imports** for the current session. Queued items remember the export and refresh choices made when they were added. CLI imports retain automatic export. Excel is an optional view of the canonical JSON files.
7. **Logs / Status:** inspect progress, counts, warnings, and errors; open the structured per-run log directory.
8. **Settings → Dependencies:** check releases, review installed paths and providers, select updates, or recover an interrupted update. **Settings → Storage:** inspect paths and open data/configuration.

Removed subjects leave the managed list, import selector, and future channel syncs. Their IDs, final names, and historical associations stay in `config.json` under `archivedSubjects`; their captures remain searchable through the Corpus subject filter, marked **(archived)**. A new subject with the same name receives a fresh ID and no inherited channels. Reimporting an already captured video preserves its archived subject assignment, even when a new subject is selected; new video IDs can belong to the new subject. Old failed queue history cannot revive a removed subject. Removal does not delete or rewrite videos, transcript snapshots, channel records, or run logs.

Members-only videos are recorded as **SkippedMembersOnly**, counted separately, and excluded from failure totals. Channel listings identify them before video requests; explicit membership errors during metadata retrieval also become skips. Existing transcripts are preserved. Known member skips are reused unless explicitly refreshed or a subsequent channel listing reports public/unlisted access. Other errors, including private videos and rate limits, retain their existing handling.

Queue processing has its own background PowerShell runspace, separate from subject edits, corpus refreshes, and searches. WPF's dispatcher timer transfers progress and results. You can append or remove pending items and edit unrelated subjects during downloads. While the queue worker is active, channel sync, manual exports, and dependency maintenance are disabled to avoid conflicting writers. External processes use asynchronous stdout/stderr readers implemented in a small C# helper loaded by PowerShell. They create no console windows and use Windows-compatible structured argument quoting. Native command logs redact URLs and do not emit signed caption URLs.

The main Cancel button cancels the current foreground operation, such as search or channel sync. **Cancel current and pause** cancels the active queue item and keeps the remaining pending items. Both terminate an active child process tree where practical. Completed atomic commits survive. Excel cancellation is checked between rows/stages; the final EPPlus save is not interruptible mid-write. The application stays interactive and honors cancellation at the next safe boundary. Closing during work requests cancellation and waits for safe cleanup. Only one capture/export writer and one queue runner can operate on a corpus. Queue and subject changes share a separate short file lock, so downloads do not block configuration edits. Closing during a queued import returns the interrupted item to Pending and saves the queue paused. Abandoned Running items are recovered to Pending when no queue runner owns them; the next launch requires an explicit resume.

## Files and architecture

```text
Start-YouTubeCorpus.bat       Windows launcher
YouTubeCorpus.ps1             GUI and command-line entry point
Install-Dependencies.ps1      Missing-dependency bootstrap
Update-Dependencies.ps1       Explicit user-folder dependency maintenance CLI
Test-DependencyModule.ps1     Fresh-process module/workbook verification
config.json                  User-managed subjects and channel URLs
src/Corpus.Core.psm1          Atomic JSON, configuration, local queries
src/Corpus.YouTube.psm1       yt-dlp adapter, captures, channel/video ingestion
src/Corpus.RateLimit.psm1     Persistent pacing, cooldown, and bounded retries
src/Corpus.Transcript.psm1    VTT parsing and rolling-caption normalization
src/Corpus.Excel.psm1         ImportExcel/EPPlus workbook generation
src/Corpus.Operations.psm1    Locking, run accounting, cancellation orchestration
src/Corpus.Queue.psm1         Durable batch queue, claiming, controls and recovery
src/Corpus.Dependencies.psm1  Release checks, caching, staging, module updates
src/Corpus.DependencyTransaction.psm1  Native pair commit, backup, rollback/recovery
src/Corpus.Process.*          Native execution and async output capture
src/Corpus.Gui.*              WPF layout and background-worker coordination
src/Corpus.Viewer.*           Virtualized transcript reader and literal highlighting
src/Corpus.Icons.*            Shared vector button icons and accessible labels
src/Corpus.Logging.psm1       JSONL logs and progress notifications
data/queue.json               Pending items, subject IDs, options and queue history
data/config.lock              Short configuration/queue transaction lock
data/queue-runner.lock        Exclusive queue runner handle
data/corpus.lock              Exclusive capture/export writer handle
data/raw/CHANNEL/VIDEO/       Content-addressed original metadata and subtitles
data/normalized/videos/      One canonical document per video ID
data/normalized/transcripts/ Immutable transcript captures, selected by each video
data/normalized/channels/    One canonical channel state per channel ID
data/normalized/runs/        Execution records including incomplete/failed runs
output/YouTubeCorpus.xlsx     Regenerable research workbook
logs/                        Per-run JSONL and dependency logs
tests/                       Offline Pester tests and separate live test runner
```

Raw files use SHA256 content directories and stable channel/video identities, never titles. Identical downloads reuse the same file. Separate observation JSON records retain capture timestamps even when bytes do not change. Metadata snapshots preserve changing titles, descriptions, counters, names, and reported availability. Failure observations record inaccessible videos. Original metadata/subtitles are not edited during normalization.

Canonical video records reference one completed transcript snapshot. Normalized segments have deterministic SHA256 identities based on video, source, language, start/end times, and text. Repeat imports reuse valid saved transcripts. Explicit refreshes replace the canonical pointer without appending duplicate Excel rows. A failed caption refresh retains the last valid transcript and marks the latest attempt failed. Atomic sibling-file replacement prevents a partially written JSON file from becoming canonical. Abandoned `Running`/`CommittingWorkbook` run records are marked `Interrupted` when the next writer obtains the lock.

VTT normalization decodes entities, removes VTT/HTML tags, joins wrapped lines, ignores blank cues and metadata blocks, and removes shared suffix/prefix words from overlapping or touching automatic cues. Manual dialogue and later intentional repetitions are retained. This is a conservative caption heuristic, not speech recognition; unusual caption editing patterns may still produce imperfect segmentation. Only English tracks with VTT renditions are imported. Raw captions remain available for auditing or future reprocessing.

## Workbook

The workbook contains **Videos**, **Transcript**, **Channels**, and **Runs**. Transcript rows include publication date, subject/channel/title, timestamp, text, source, capture time, and a genuine hyperlink such as `https://www.youtube.com/watch?v=VIDEO_ID&t=42s`. URLs round down to whole seconds. Tables support AutoFilter and Ctrl+F, freeze headers, wrap long text, and use numeric Excel date values.

Untrusted captions/titles are stored as cell values, never formulas. Excel's 32,767-character cell limit truncates display values only; full text remains local. Transcript rows beyond Excel's worksheet limit continue in `Transcript_2`, etc. An excessive Videos sheet raises a clear error. Excel builds use a temporary workbook and atomic replacement; a locked destination leaves the previous workbook intact. CLI syncs export automatically. GUI syncs and queued videos export only when the export option was selected; a queued item records that choice at enqueue time. For large batches, leave it off and export once after the queue finishes. Cancellation or exhausted rate-limit retries stop before that build; saved captures remain available for a separate workbook build. If the build fails, the finalized local run record is authoritative; the previous workbook may show older run information.

Back up `config.json`, `data/` (including `queue.json`), and optionally `logs/` while the app is closed or idle. Rebuild after restoring them with Build Excel; no live YouTube access is needed for export. Keep raw captures private unless you deliberately choose to share them. Git ignores runtime corpus data, queues, logs, and workbooks. `config.json` is a tracked starter file: keep local subject edits private unless you explicitly intend to commit them.

## Command line

```powershell
# Same ingestion implementation as the GUI
.\YouTubeCorpus.ps1 -Action SyncAll
.\YouTubeCorpus.ps1 -Action SyncChannel -Url 'https://www.youtube.com/@atmoio'
.\YouTubeCorpus.ps1 -Action Video -Url 'https://www.youtube.com/watch?v=VIDEO_ID' -SubjectId mo
.\YouTubeCorpus.ps1 -Action Build
.\YouTubeCorpus.ps1 -Action Search -Text 'search phrase'

# Bounded diagnostic import; zero means no application-imposed limit
.\YouTubeCorpus.ps1 -Action SyncChannel -Url 'https://www.youtube.com/@atmoio' -Limit 2
```

The persistent batch queue is managed through the GUI; the existing CLI actions continue to run directly. `-Root` selects a separate writable corpus directory containing a valid `config.json`. `-SkipDependencies` is for fixture tests/offline diagnostics and skips installation; required operations still need their modules/binaries. GUI cancellation is the supported graceful-cancellation path; abruptly killing a CLI process preserves completed items and leaves its running record for recovery on the next write.

## Tests

Use Windows PowerShell 5.1. The test runner supports Windows-shipped Pester 3.4 and Pester 4.10.1. ImportExcel must be available. If needed:

```powershell
Install-Module ImportExcel -Scope CurrentUser
Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser
.\tests\Run-Tests.ps1
```

The deterministic suite uses local metadata/VTT fixtures; it does not access YouTube or install native dependencies. It covers configuration, relationships, identifiers, parser edge cases, rolling captions, timestamp links, repeated acquisition via a mocked external adapter, raw deduplication/history, failure persistence and continuation, search context, process output, cancellation/run records, and real XLSX content/locking. The queue tests also cover deduplication, atomic validation, subject locks, concurrent configuration writers, pause/cancel/retry/recovery, rate-limit halting, and cached imports under the queue writer lock. GitHub Actions runs the suite and all three WPF integration scripts on Windows.

Actual WPF interaction tests (local fixtures; no YouTube requests):

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-ViewerIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-QueueIntegration.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-SubjectsIntegration.ps1
```

The queue integration test holds a simulated download open while exercising real controls for subject creation/rename, adding/removing URLs, corpus search, pause/resume, and window-close recovery. The simulation replaces only acquisition; queue storage, locks, and GUI workers are real.

Separate network integration:

```powershell
.\tests\Invoke-LiveIntegration.ps1 -Limit 2
```

This checks dependencies and syncs the channels in your current configuration twice into a new isolated temporary corpus, prints its directory, creates a workbook, and writes `integration-results.json`. Exit 2 reports live extraction failures; it is not a successful transcript acceptance result. A larger limit or `-Limit 0` can take a long time and encounter rate limits. It never downloads full video media.

A separate updater integration test downloads real releases, verifies checksums and versions, replaces native binaries **only inside a temporary test directory**, and checks the ImportExcel workbook round-trip without installing it:

```powershell
.\tests\Invoke-DependencyIntegration.ps1
```

A timed WPF startup test is also available:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\YouTubeCorpus.ps1 -SmokeTest
```

## Troubleshooting and limits

- **Subject rename/removal locked:** finish, cancel, or remove every Pending/Running item for that subject. Pausing keeps pending names locked. Other subjects can still be edited.
- **Queue paused after restart:** select Start / resume. Downloads never resume automatically; completed captures are reused.
- **Another queue is running:** use the window that owns the queue, or wait for it to finish. Do not delete lock files to bypass an active worker.
- **Failed queue item:** review its Details and Logs, then use Retry selected. Ordinary failures do not stop subsequent items; persistent rate limiting does.
- **HTTP 429:** let the cooldown complete; repeated restarts do not clear it. After retries are exhausted, wait at least 8 minutes before starting another sync. Saved transcripts are reused by default.
- **No English captions:** this is an explicit unavailable status, not a parsing success. No automatic speech-to-text fallback is attempted.
- **YouTube extraction, private/deleted videos, sign-in, or rate limiting:** inspect the sanitized yt-dlp error in the run log. Retry later or review the installed yt-dlp version in Settings → Dependencies. Browser cookies and authenticated-only content are not configured by this version.
- **No videos plus extractor warnings:** treated as a channel failure; raw listing remains available when a stable channel ID was resolved.
- **Dependency failure:** the exact failing native name/path and version-check error are recorded. Existing files remain intact. This version requires successful native checks before enabling normal GUI operations.
- **Workbook locked:** close it in Excel or its viewer and build again. Raw/canonical captures survive workbook failure.
- **Insufficient disk space:** free space and retry; per-item commits remain. Temporary/staging files from a forcibly terminated process can be removed after all application instances close.
- **Very large corpora:** normalized files are read per video, but metadata/search result sets and EPPlus workbooks reside in memory. Expect increased memory use; use search filters. A database is intentionally not introduced.
- **Cancellation delay:** child processes are stopped promptly; archive download/extraction during dependency installation and a final workbook serialization complete at safe boundaries. No UI-thread `DoEvents()` loop is used.
- **Full Windows acceptance remains manual:** interactive browser playback, very large batches, disk exhaustion, and crash/power-loss fault injection beyond the tested recovery cases remain manual checks. Do not equate passing offline tests with those checks.

This is an evidence retrieval utility. It does not label statements true, false, contradictory, hypocritical, or misleading.
