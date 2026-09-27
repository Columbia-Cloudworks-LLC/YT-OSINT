# Video queue

## Add a batch

Open **Video Queue**, paste one HTTPS YouTube video URL per line, choose a subject, then press **Add URLs to queue**. Watch, youtu.be, shorts, live, and embed video URLs are accepted. Channel and playlist URLs are not batch video entries; use the Channels workflow for a channel sync.

The app validates the entire batch before saving anything. If a line is invalid, the input stays in place and the error identifies its line number. URL variants resolve to the same video ID. Duplicates within the batch or against existing Pending/Running items are skipped and counted. A video already completed may be added again; a valid captured transcript is reused unless **Refresh saved transcripts** was selected.

Adding URLs does not start a paused queue. Press **Start / resume** when ready. Items added during an active queue join its tail and are processed automatically unless you pause. Unknown titles initially display the video ID; adding a batch makes no requests just to look up titles. Full video media is never downloaded.

Each item stores a stable subject ID and the subject name at enqueue time. If no subject is selected, an already captured video's existing assignment is retained. An unassigned new video remains unassigned. If a captured video belongs to an archived subject, reimporting it preserves that archived assignment even if a different subject is selected. Newly created subjects do not inherit archived captures. Refresh and optional Excel export choices are captured when adding the item, rather than changing underneath an active batch.

## Manage work

| Control | Behavior |
|---|---|
| Start / resume | Process pending items sequentially. No parallel YouTube downloads. |
| Pause after current | Finish the active item, then stop before claiming another. |
| Cancel current and pause | Cancel the active import at a safe boundary; keep later items pending. |
| Remove pending item | Delete the selected unstarted item. Active or finished items cannot be removed this way. |
| Retry selected | Put a Failed or Cancelled item back into Pending, using its subject's current name. Resume separately if paused. |
| Clear finished | Remove terminal queue history only; preserve Pending/Running items and all captured corpus data. |

The displayed status is Pending, Running, Completed, Skipped, Failed, or Cancelled. Skipped includes members-only videos and videos without eligible original English captions. Details explain skips and failures. Ordinary failures permit the next item; a persistent YouTube rate limit pauses the whole queue and returns the active item to Pending. The existing shared cooldown must expire before requests can resume.

The order of pending processing follows the stored list; sorting the displayed queue changes only its presentation. Retry restores the item at its existing position. Queue reordering is not provided.

## Work while downloading

Subject creation, channel association edits, corpus browsing, searches, transcript reading, and adding/removing pending URLs remain available during queued imports. The foreground worker may briefly disable its own actions while saving or refreshing; it is independent of the acquisition worker.

A subject's name and removal are locked whenever any item for it is Pending or Running, including when the queue is paused. The Rename and Remove subject buttons are disabled and the persistence layer independently enforces the restriction. New subjects and unrelated names remain editable. Removal of any subject additionally requires capture/export work to be idle; pause and wait for the current item first. Cancelled, Failed, Completed, and Skipped items do not lock names; retry refreshes the stored name and locks it again. If the subject has since been removed, retry is rejected; add the URL again using a current subject. Existing archived captures retain their original subject identity.

Channel sync is still a separate operation. Channel sync, manual Excel export, and dependency maintenance are disabled while the queue worker is active. Pause and wait for the active item to finish before using those actions. The main status-bar Cancel controls foreground work; queue cancellation has its own button.

## Restart and recovery

The queue is saved atomically in `data/queue.json`. Closing the window cancels active acquisition safely, returns interrupted work to Pending, and leaves the queue paused. A new window recovers abandoned Running items only if no runner owns the queue. It never auto-resumes downloads. Captures completed before an interruption are reused on resume.

A second application window may inspect the queue, but cannot run it concurrently. Editing runtime JSON directly while the application is working is unsupported. Back up the configuration and data together while idle; queue history contains source URLs and subject names and is excluded from Git.

## Implementation

`Corpus.Queue.psm1` owns validation, queue mutations, claims, and completion transitions. `Corpus.Operations.psm1` still handles acquisition and run records; the queue passes its exclusive corpus writer handle to avoid reacquiring it. Dependency mutexes remain held while the queue runs, preventing maintenance from changing executables underneath an import.

`data/queue-runner.lock` has one open exclusive handle for the runner's lifetime. `data/corpus.lock` excludes competing capture/export operations. `data/config.lock` serializes short queue and subject transactions. No configuration lock spans a network request. Completion reloads the latest queue while holding that short lock, so items added or removed during an import are preserved. Subject renames and queue additions use the same lock to prevent a name-check/enqueue race.

Readers use a consistent file handle with sharing that permits atomic replacement. Each JSON update writes a sibling temporary file and replaces the destination. Lock files may remain on disk: ownership is the open handle, not file existence; Windows releases handles when a process exits.
