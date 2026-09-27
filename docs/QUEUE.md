# Shared channel and video queue

## Add work

In **Subjects**, select a subject on the left. Subjects start in A–Z order; switch to Z–A without losing the selection. The upper right pane manages that subject's channels. The lower pane accepts one HTTPS YouTube video URL per line. Press **Add URLs to queue** to attach the batch to the selected subject. Watch, youtu.be, shorts, live, and embed video URLs are accepted. Invalid batches are rejected together with line numbers and the input is retained.

In **Channels**, select a channel on the left to view its details and controls on the right. Before discovery, the list shows a URL-derived label and subject in parentheses. After discovery, the saved channel name is used. **Queue channel sync** schedules discovery and downloads; **Queue all channels** adds configured channels that are not already scheduled. Selecting another channel never changes an existing job's source, subject, refresh choice, or export choice.

Both entry points use the same sequential worker. Adding work does not start a paused queue: use **Video Queue → Start / resume**. Additions during a running queue are picked up automatically. No parallel YouTube requests are introduced. The video list contains only individual videos; discovery jobs appear as status on the selected channel and in the queue's channel-sync count.

A sync moves through Queued, Discovering, and Downloading before Completed, Partial, Failed, or Cancelled. The channel's sync button stays disabled while its job is active, including when paused. The next channel discovery waits until the previous channel's downloads finish or are cancelled. Batch videos and channel discoveries otherwise follow enqueue order; a discovered channel's videos are appended to the video list.

## Duplicate videos and ownership

Video IDs are deduplicated across pending/running batch and sync work. A duplicate request shares the existing item, retaining the first item's subject and refresh/export settings. Sync jobs retain references to shared videos so they can wait for completion without downloading twice. An explicit batch claim is preserved when a channel sync is cancelled. Completed videos can be queued again; valid transcripts are reused unless refresh was selected. Full video media is never downloaded.

Each job and video stores stable subject IDs. Changing UI selection never reassigns queued work. Archived captures retain their original subject identity even when reimported through a new subject. Newly created subjects do not inherit archived captures.

## Manage work

| Control | Behavior |
|---|---|
| Start / resume | Run pending discovery and video work sequentially. |
| Pause after current | Finish the active discovery or download, then stop. Discovered videos remain pending. |
| Cancel current and pause | Stop the current discovery/import safely and leave later work pending. |
| Remove pending item | Remove an unstarted batch item. Sync-linked items remain as Cancelled history so their job can account for them. |
| Retry selected | Retry a Failed/Cancelled video as an independent item, preserving its assignment and refreshing its subject name. When its sync is still active, the original failure remains in history for accurate sync totals. |
| Clear finished | Clear terminal video history and preserve captures; terminal items referenced by an active sync are retained until that sync finishes. |
| Channels → Cancel sync | Stop discovery and cancel downloads belonging only to that sync that have not started. Shared batch downloads remain. An active video is allowed to finish before the channel unlocks. |

Video states are Pending, Running, Completed, Skipped, Failed, or Cancelled. Skipped includes members-only videos and videos without eligible original English captions. Failures remain visible and retryable but do not permanently lock a channel. After failed discovery, queue the channel again. An empty channel can complete successfully only when discovery returns no extractor warnings.

Ordinary failures permit later work. Exhausted HTTP 429 retries pause the entire scheduler and return the affected discovery/video to Pending. The shared cooldown must expire before requests resume. Sorting the video table changes presentation only; manual queue reordering is not provided.

## Work while downloading

Subject creation, association edits, browsing, searches, transcript reading, additional channel sync requests, and adding/removing pending URLs remain available. Foreground saves and refreshes may briefly disable their controls, independently of the acquisition worker.

A subject cannot be renamed or removed while it owns pending/running videos **or active channel jobs**, including jobs awaiting discovery and paused jobs. Both the UI and storage layer enforce this. Unrelated subjects remain editable. Removal additionally requires the capture/export writer to be idle. Retrying history for an archived subject is rejected; add the URL again through a current subject, retaining archived ownership for existing captures.

Manual Excel export and dependency maintenance require the worker to be idle. Pause and wait for the current operation first. Queue items remember their optional Excel export setting; for large batches, export once after downloads finish.

## Restart and recovery

`data/queue.json` is saved atomically. Existing video-only queue files are upgraded in memory without losing entries. Closing cancels acquisition safely, preserves interrupted work for resume, and leaves the queue paused. Orphaned Running videos and Discovering jobs are reset only after acquiring the exclusive runner lock. Completed captures are reused. Startup never auto-resumes.

Only one application window may own the runner. Do not edit runtime JSON or delete lock files to bypass it. Back up configuration and data together while idle; queue history contains source URLs and subject names and is excluded from Git.

## Implementation

`Corpus.Queue.psm1` stores video `Items` and channel `SyncJobs`. Video `JobIds` link shared work; `Batch` retains an independent batch claim. Discovery uses the same channel parser as CLI sync with `DiscoverOnly`, preserving channel names, IDs, raw listings, membership hints, and ownership checks. Each downloaded video still goes through `Corpus.Operations.psm1` and its run logging. CLI actions continue to execute directly under the same exclusive corpus lock.

`data/queue-runner.lock` owns scheduling; `data/corpus.lock` excludes competing captures/exports. Dependency mutexes prevent executable replacement during acquisition. `data/config.lock` serializes short queue/subject transactions, with no network request inside it. Completion reloads the latest queue under this lock to preserve concurrent additions, removals, and cancellation requests.
