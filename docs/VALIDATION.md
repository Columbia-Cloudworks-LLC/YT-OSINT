# Validation report

Validated on 2026-09-26. This report distinguishes deterministic application checks from network-dependent acceptance.

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
