# Validation report

Validated on 2026-09-26. This report distinguishes deterministic application checks from network-dependent acceptance.

## Subtitle rate-limit handling

The full deterministic suite passes **79 tests**. New coverage checks original-English preference, mixed translated/original URL filtering, cache validation and reuse, explicit refresh, request spacing, timezone-safe persisted cooldowns, cancellation during the countdown, 2/4/8-minute backoff, retry exhaustion, and stopping subsequent videos and channels. It also verifies that the rate-limit reason survives the asynchronous GUI worker boundary and that a native process emitting HTTP 429 is interrupted promptly.

`tests/Invoke-RateLimitIntegration.ps1` ran the installed yt-dlp against a loopback HTTP fixture. It made exactly one request when the server returned 429, exposed the error without re-extracting the video, then made one request when the server returned a valid VTT and normalized that caption successfully. No media or YouTube requests were made. This check supplements mocked retry tests; it does not demonstrate that YouTube will lift a live restriction.

## User-folder installation and automatic restart

The native dependency location is now `%LOCALAPPDATA%\YT-OSINT\bin`. A real first installation downloaded and verified yt-dlp 2026.08.19, FFmpeg/ffprobe 9.0.2, and Deno 2.9.7 without elevation. The user removed the previous Windows-directory binaries; they are no longer required. ImportExcel 7.8.10 was already available in the user's module directory.

The complete update orchestrator also passed against real upstream packages in an isolated user profile, including replacements of existing copies, candidate and installed-version checks, checksummed backups, and a shared GUI-style progress context. ImportExcel passed its package check and fresh-process workbook round-trip. This catches the previous asynchronous download output leak, which caused a missing `Name` property error before elevation could start.

The deterministic suite now contains 60 tests, including the output-leak regression, user-path installation/replacement/recovery, failed candidate handling, and explicit FFmpeg/Deno path arguments. The tests preserve the real user's installed copies.

`tests/Invoke-RestartIntegration.ps1` starts a real fresh Windows PowerShell process, verifies that it waits for the old window's close signal, then completes WPF startup using the same corpus path containing spaces. On update failure the GUI stays open and shows the error instead of hiding it behind another status check.

The earlier Windows-directory/UAC implementation and original ingestion results below are historical; elevation no longer applies to dependency installation or updates. Successful full-channel caption ingestion is still a separate acceptance check.

## Dependency updater follow-up

The explicit dependency manager was added and tested after the original corpus validation below. The current local suite passes **55 tests**, with no skipped or pending cases. New tests cover daily-cache reuse/expiration/channel invalidation, Unknown network results, Git-build version handling, SHA256/SHA512 rejection, ZIP traversal prevention, changed-release rejection, pair rollback after verification or file-lock failures, interrupted recovery, external-change protection, module promotion/rollback, and maintenance-lock exclusion.

The WPF Settings → Dependencies page loaded all four dependency results through its background worker, remained on the dispatcher loop, and closed with the worker idle. Its actual rendering is recorded in `dependencies.png`.

The opt-in `tests/Invoke-DependencyIntegration.ps1` passed using real upstream packages:

| Dependency | Release tested | Verification |
|---|---|---|
| yt-dlp | 2026.08.19 | GitHub SHA256, executable version, real replacement in a temporary directory |
| FFmpeg / ffprobe | 9.0.2 essentials | Gyan SHA256, both executable versions, real pair replacement in a temporary directory |
| Deno | 2.9.7 | GitHub SHA256, executable version, real installation in a temporary directory |
| ImportExcel | 7.8.10 | Gallery SHA512, extraction, fresh-process import and XLSX round-trip |

These tests deliberately did **not** replace SystemRoot executables or install a module into the user's live module directory. UAC approval/decline and protected SystemRoot installation remain a manual acceptance check; the underlying replacement/rollback functions were exercised with real Windows files and executables in isolated directories. Startup still preserves installed versions. Explicit updates now replace them only after user selection and verification.

The live read-only check correctly identified the existing yt-dlp as outdated, the installed FFmpeg as a different Git/full build, Deno as missing, and ImportExcel as current. Original live YouTube extraction results below remain historical; successful full-channel ingestion was not retested as part of this updater change.

## Original corpus validation

## Environment

| Component | Tested version |
|---|---|
| Windows | NT 10.0.26200.0, x64 |
| Windows PowerShell | 5.1.26100.9444 |
| Pester | 3.4.0 locally; CI is configured for 4.10.1 |
| ImportExcel | 7.8.10 |
| yt-dlp | 2025.01.26, existing SystemRoot binary |
| FFmpeg / ffprobe | 2025-01-22-git-e20ee9f9ae-full_build-www.gyan.dev |

All three SystemRoot binaries were already present. Their versions were checked with redirected native process execution. They were not overwritten, upgraded, or re-downloaded. ImportExcel was already available and imported successfully. The bootstrap completed without UAC.

## Automated checks

The deterministic Pester suite passes with no skipped or pending cases. It exercises configuration validation, stable IDs, subject/channel associations, metadata normalization, VTT timestamps/tags/Unicode, rolling-caption deduplication, caption preference, failure persistence, search context, external output/argument handling, workbook hyperlinks/date types/formula safety/locking, repeated imports, artifact deduplication, continued processing after an individual video failure, run records and cancellation.

Two actual acquisition calls using fixture adapters produce one canonical video and six unique manual-caption segments. They reuse one metadata artifact and one raw subtitle artifact, while retaining two observation records. A subsequent failed caption download preserves the previously valid transcript. The automatic-caption fixture produces five normalized segments, retaining later intentional repetition and multilingual text.

The native WPF startup smoke test completes dependency verification and background refresh, shows the seeded subject, advances at least sixteen dispatcher ticks, then exits with the worker idle. A screenshot was rendered from the actual WPF window. This validates startup and dispatcher execution; it is not a complete manual interaction or large-corpus responsiveness benchmark.

## Live integration against configured channels

The live runner requested a maximum of two videos per channel and ran twice in an isolated corpus. It used the existing binaries exactly as configured for the application, without substituting a newer yt-dlp.

| Check | First run | Second run |
|---|---:|---:|
| Channels requested | 2 | 2 |
| Video IDs discovered | 2 | 2 |
| Canonical video records | 2 | 2 |
| Unique canonical video IDs | 2 | 2 |
| Transcripts captured | 0 | 0 |
| Failures (videos + channel enumeration) | 3 | 3 |
| Final state | Partial | Partial |
| Workbook produced | Yes | Yes |

For `@atmoio`, enumeration returned video IDs `rLCCpuLwbMs` and `puI3KrbKZOU`. Metadata retrieval for both failed with yt-dlp's `The page needs to be reloaded` error. The second video was attempted after the first failure; failure records survived reruns without duplicates.

For `@lessbitter`, the installed extractor warned about unsupported `LOCKUP_CONTENT_TYPE_VIDEO` entries and produced zero usable videos. The application reports this as failed enumeration, not as a successfully empty channel. A channel listing artifact was preserved where the channel ID was available.

The repeated live test produced a valid workbook and persisted run/failure records. It did **not** validate successful live transcript ingestion, full-channel enumeration, or search over real channel captions. The old extractor is incompatible with the observed responses; the application's explicit no-upgrade policy leaves its maintenance to the administrator.

## Remaining manual acceptance

- Clean Windows machine: absent dependency downloads, checksum verification, UAC approval/decline, native install, Gallery install, resume, then a second launch with no UAC.
- Successful full sync of both channels using a separately maintained compatible yt-dlp installation and permitted YouTube access.
- Large import interaction: moving/minimizing the window, switching tabs, cancelling active work, and reopening the corpus.
- Browser navigation from a real captured caption and Excel hyperlink to verify YouTube playback near the expected timestamp.
- Network drop, disk exhaustion, and power-loss fault injection beyond the tested atomic-write and locked-workbook cases.

No claim of full end-to-end acceptance is made for these unperformed checks.
