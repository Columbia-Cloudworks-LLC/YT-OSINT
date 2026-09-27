# YT-OSINT

A Windows-native PowerShell/WPF utility for collecting YouTube metadata and English transcripts into a local, searchable evidence corpus. Export a real Excel workbook, search neighboring transcript context, and open a video at the matching timestamp. No Excel installation, API key, web server, Python runtime, or database is required.

**Validation status:** Windows fixture tests, the WPF transcript viewer, and Corpus search have been exercised. The captured corpus contains 113 video records and 18,951 transcript segments; the corrected workbook opens in desktop Excel with all four tables intact. See [validation details](docs/VALIDATION.md).

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

The initial subject is **Mo**, explicitly associated with `https://www.youtube.com/@atmoio` and `https://www.youtube.com/@lessbitter`. These are configuration entries, not special cases in application code. Importing is an explicit user action; startup does not sync channels.

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

Imports reuse valid saved English transcripts before sending video requests. To fetch them again, select **Refresh saved transcripts** on Channels or **Refresh saved transcript** on Individual Videos. The command-line equivalent is `-RefreshTranscript`. Cached imports keep their original capture timestamps; missing or malformed cache files are fetched again.

Caption selection prefers manual English, then original automatic English (`en-orig` when available). Translated URLs containing `tlang` are excluded, including translated entries mixed into a generic `en` track. Videos offering only translations are recorded as unavailable. The complete original metadata is retained; the downloader receives a separate copy containing only the selected caption track.

Requests are sequential, with 10 seconds between yt-dlp invocations, 1 second between extraction requests, and 10 seconds before subtitle downloads. The app controls retries and disables yt-dlp's immediate subtitle re-extraction fallback.

On HTTP 429, the entire sync queue pauses for **2, 4, then 8 minutes** before retrying. The status bar shows a countdown; Cancel remains available. A fourth 429 stops the run as **RateLimited**, without scheduling another video or channel. Completed metadata and transcripts remain saved; build the workbook separately if needed.

Cooldown deadlines and retry counts are saved in `%LOCALAPPDATA%\YT-OSINT\youtube-requests.json`, shared across this user's corpora and preserved across restarts. After retry exhaustion, wait at least another 8 minutes before explicitly starting a new sync. Metadata success alone does not reset subtitle backoff; a successful caption request does. These delays reduce unnecessary traffic but cannot guarantee that YouTube will accept a request.

## Desktop workflow

1. **Subjects:** select a subject, enter its display name, and rename it, or create another subject. Add channel URLs under the selected subject. Select an association to remove it; previously captured videos, observations, and transcripts remain.
2. **Channels:** select a configured source and sync it, or sync all sources. The table shows stable IDs, counts, last attempt, last successful sync, and status. URLs resolving to the same channel ID share canonical channel state. Conflicting subject ownership is rejected while the prior association is active.
3. **Individual Videos:** paste a watch, short, or live video URL. Choose an existing subject, create/select a new subject, or leave it unassigned. Reimporting an already assigned video without choosing a subject preserves its existing assignment.
4. **Corpus:** use **Find videos** to filter metadata or **Find in transcripts** to search captions, with optional subject/channel/video/date filters. Both use the same literal query field. Double-click a video or search result, or select it and press **Read transcript**. There is no separate Search tab.
5. **Transcript viewer:** read the full timestamped transcript. Type literal text to highlight every occurrence within each segment, ignoring case. **Previous match** and **Next match** navigate matching segments and wrap around; **Show matching segments only** hides other rows. Clear the query to restore the full transcript. Double-click a segment or use **Open selected timestamp** to open YouTube. Missing transcripts show an empty-state message. The viewer renders visible rows on demand, and loads only the selected video's saved transcript.
6. **Excel export:** GUI imports save the corpus without rebuilding Excel by default. Use **Export Excel workbook** when needed, or enable **Also export Excel after imports** for the current session. CLI imports retain automatic export. Excel is an optional view of the canonical JSON files.
7. **Logs / Status:** inspect progress, counts, warnings, and errors; open the structured per-run log directory.
8. **Settings → Dependencies:** check releases, review installed paths and providers, select updates, or recover an interrupted update. **Settings → Storage:** inspect paths and open data/configuration.

Members-only videos are recorded as **SkippedMembersOnly**, counted separately, and excluded from failure totals. Channel listings identify them before video requests; explicit membership errors during metadata retrieval also become skips. Existing transcripts are preserved. Known member skips are reused unless explicitly refreshed or a subsequent channel listing reports public/unlisted access. Other errors, including private videos and rate limits, retain their existing handling.

Long-running work executes in a background PowerShell runspace. WPF's dispatcher timer only transfers status and completed results. External processes use asynchronous stdout/stderr readers implemented in a small C# helper loaded by PowerShell. They create no console windows and use Windows-compatible structured argument quoting. Native command logs redact URLs and do not emit signed caption URLs.

The Cancel button stops additional items and terminates an active child process tree where practical. Completed atomic commits survive. Excel cancellation is checked between rows/stages; the final EPPlus save is not interruptible mid-write. The application stays interactive and honors cancellation at the next safe boundary. Closing during work requests cancellation and waits for safe cleanup. One operation writes at a time; an exclusive file handle prevents another application instance from writing concurrently.

## Files and architecture

```text
Start-YouTubeCorpus.bat       Windows launcher
YouTubeCorpus.ps1             GUI and command-line entry point
Install-Dependencies.ps1      Missing-dependency bootstrap
Update-Dependencies.ps1       Explicit maintenance CLI and elevated native helper
Test-DependencyModule.ps1     Fresh-process module/workbook verification
config.json                  User-managed subjects and channel URLs
src/Corpus.Core.psm1          Atomic JSON, configuration, local queries
src/Corpus.YouTube.psm1       yt-dlp adapter, captures, channel/video ingestion
src/Corpus.RateLimit.psm1     Persistent pacing, cooldown, and bounded retries
src/Corpus.Transcript.psm1    VTT parsing and rolling-caption normalization
src/Corpus.Excel.psm1         ImportExcel/EPPlus workbook generation
src/Corpus.Operations.psm1    Locking, run accounting, cancellation orchestration
src/Corpus.Dependencies.psm1  Release checks, caching, staging, module updates
src/Corpus.DependencyTransaction.psm1  Native pair commit, backup, rollback/recovery
src/Corpus.Process.*          Native execution and async output capture
src/Corpus.Gui.*              WPF layout and background-worker coordination
src/Corpus.Viewer.*           Virtualized transcript reader and literal highlighting
src/Corpus.Logging.psm1       JSONL logs and progress notifications
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

Untrusted captions/titles are stored as cell values, never formulas. Excel's 32,767-character cell limit truncates display values only; full text remains local. Transcript rows beyond Excel's worksheet limit continue in `Transcript_2`, etc. An excessive Videos sheet raises a clear error. Excel builds use a temporary workbook and atomic replacement; a locked destination leaves the previous workbook intact. Syncs that reach completion automatically build the workbook, even if some items failed. Cancellation or exhausted rate-limit retries stop before that build; saved captures remain available for a separate workbook build. If the build fails, the finalized local run record is authoritative; the previous workbook may show older run information.

Back up `config.json`, `data/`, and optionally `logs/`. Rebuild after restoring them with Build Excel; no live YouTube access is needed for export. Keep raw captures private unless you deliberately choose to share them. Git ignores all runtime corpus data, logs, and workbooks.

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

`-Root` selects a separate writable corpus directory containing a valid `config.json`. `-SkipDependencies` is for fixture tests/offline diagnostics and skips installation; required operations still need their modules/binaries. GUI cancellation is the supported graceful-cancellation path; abruptly killing a CLI process preserves completed items and leaves its running record for recovery on the next write.

## Tests

Use Windows PowerShell 5.1. The test runner supports Windows-shipped Pester 3.4 and Pester 4.10.1. ImportExcel must be available. If needed:

```powershell
Install-Module ImportExcel -Scope CurrentUser
Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser
.\tests\Run-Tests.ps1
```

The deterministic suite uses local metadata/VTT fixtures; it does not access YouTube or install native dependencies. It covers configuration, relationships, identifiers, parser edge cases, rolling captions, timestamp links, repeated acquisition via a mocked external adapter, raw deduplication/history, failure persistence and continuation, search context, process output, cancellation/run records, and real XLSX content/locking. GitHub Actions runs it on Windows.

Separate network integration:

```powershell
.\tests\Invoke-LiveIntegration.ps1 -Limit 2
```

This checks dependencies and syncs both configured channels twice into a new isolated temporary corpus, prints its directory, creates a workbook, and writes `integration-results.json`. Exit 2 reports live extraction failures; it is not a successful transcript acceptance result. A larger limit or `-Limit 0` can take a long time and encounter rate limits. It never downloads full video media.

A separate updater integration test downloads real releases, verifies checksums and versions, replaces native binaries **only inside a temporary test directory**, and checks the ImportExcel workbook round-trip without installing it:

```powershell
.\tests\Invoke-DependencyIntegration.ps1
```

A timed WPF startup test is also available:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\YouTubeCorpus.ps1 -SmokeTest
```

## Troubleshooting and limits

- **HTTP 429:** let the cooldown complete; repeated restarts do not clear it. After retries are exhausted, wait at least 8 minutes before starting another sync. Saved transcripts are reused by default.
- **No English captions:** this is an explicit unavailable status, not a parsing success. No automatic speech-to-text fallback is attempted.
- **YouTube extraction, private/deleted videos, sign-in, or rate limiting:** inspect the sanitized yt-dlp error in the run log. Retry later or review the installed yt-dlp version in Settings → Dependencies. Browser cookies and authenticated-only content are not configured by this version.
- **No videos plus extractor warnings:** treated as a channel failure; raw listing remains available when a stable channel ID was resolved.
- **Dependency failure:** the exact failing native name/path and version-check error are recorded. Existing files remain intact. This version requires successful native checks before enabling normal GUI operations.
- **Workbook locked:** close it in Excel or its viewer and build again. Raw/canonical captures survive workbook failure.
- **Insufficient disk space:** free space and retry; per-item commits remain. Temporary/staging files from a forcibly terminated process can be removed after all application instances close.
- **Very large corpora:** normalized files are read per video, but metadata/search result sets and EPPlus workbooks reside in memory. Expect increased memory use; use search filters. A database is intentionally not introduced.
- **Cancellation delay:** child processes are stopped promptly; archive download/extraction during elevated bootstrap and a final workbook serialization complete at safe boundaries. No UI-thread `DoEvents()` loop is used.
- **Full Windows acceptance remains manual:** interactive browser timestamp navigation and a successful live full-channel caption import require validation in a suitable Windows environment. Do not equate passing offline tests with those checks.

This is an evidence retrieval utility. It does not label statements true, false, contradictory, hypocritical, or misleading.
