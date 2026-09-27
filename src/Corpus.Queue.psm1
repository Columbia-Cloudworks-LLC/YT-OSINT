Set-StrictMode -Version 2
function Get-CorpusQueue {
    param([string]$Root)
    if(Test-Path -LiteralPath (Join-Path $Root '.yt-osint-migration-incomplete')){throw 'This corpus copy is incomplete. Use the original corpus.'}
    $queue=Read-CorpusJson (Join-Path $Root 'data/queue.json')
    if(-not $queue){$queue=[pscustomobject]@{SchemaVersion=1;Paused=$true;Items=@();SyncJobs=@()}}
    if($queue.SchemaVersion -ne 1){throw 'Unsupported queue format.'}
    if(-not $queue.PSObject.Properties['SyncJobs']){$queue | Add-Member NoteProperty SyncJobs @()}
    if(-not $queue.PSObject.Properties['DiscoveryJobIds']){$queue | Add-Member NoteProperty DiscoveryJobIds @($queue.SyncJobs | Where-Object Status -in @('Pending','Discovering','Downloading','Cancelling') | ForEach-Object {$_.Id})}
    foreach($job in $queue.SyncJobs){if(-not $job.PSObject.Properties['ClearedResults']){$job | Add-Member NoteProperty ClearedResults ([pscustomobject]@{Completed=0;Skipped=0;Failed=0;Cancelled=0})}}
    foreach($item in $queue.Items){
        if(-not $item.PSObject.Properties['JobIds']){$item | Add-Member NoteProperty JobIds @()}
        if(-not $item.PSObject.Properties['Batch']){$item | Add-Member NoteProperty Batch $true}
        if(-not $item.PSObject.Properties['ListingEntry']){$item | Add-Member NoteProperty ListingEntry $null}
    }
    return $queue
}
function Save-CorpusQueue {
    param([string]$Root,$Queue)
    Update-CorpusSyncStates $Root $Queue
    Write-CorpusJson (Join-Path $Root 'data/queue.json') $Queue
}
function Enter-CorpusQueueRunner {
    param([string]$Root)
    $null=[IO.Directory]::CreateDirectory((Join-Path $Root 'data'))
    try{return [IO.File]::Open((Join-Path $Root 'data/queue-runner.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{throw 'This corpus queue is already running in another window.'}
}
function Initialize-CorpusQueue {
    param([string]$Root)
    try{$runner=Enter-CorpusQueueRunner $Root}catch{return Get-CorpusQueue $Root}
    try {
        $lock=Enter-CorpusConfigLock $Root
        try {
            $queue=Get-CorpusQueue $Root;$queue.Paused=$true
            foreach($job in $queue.SyncJobs){if($job.Status -eq 'Discovering'){$job.Status='Pending'}}
            foreach($item in $queue.Items){if($item.Status -eq 'Running'){$item.Status='Pending';$item.Detail='Interrupted. Resume to continue using saved work.';$item.FinishedAt=$null}}
            Save-CorpusQueue $Root $queue
            return $queue
        } finally {$lock.Dispose()}
    } finally {$runner.Dispose()}
}
function Add-CorpusQueueUrls {
    param([string]$Root,[string]$Text,[string]$SubjectId='',[switch]$RefreshTranscript,[switch]$ExportWorkbook,[string]$JobId='', $ListingEntries=@())
    $entries=[Collections.Generic.List[object]]::new();$invalid=[Collections.Generic.List[string]]::new();$line=0
    foreach($value in ($Text -split '\r?\n')) {
        $line++;$url=$value.Trim();if(-not $url){continue}
        try{$id=Get-CorpusVideoIdFromUrl $url;if(-not $id){throw 'Not an individual video URL'};$entries.Add([pscustomobject]@{Id=$id;Url="https://www.youtube.com/watch?v=$id"})}
        catch {$invalid.Add("Line ${line}: enter an HTTPS YouTube video URL.")}
    }
    if($invalid.Count){$message=(@($invalid | Select-Object -First 5) -join "`n");if($invalid.Count -gt 5){$message+="`n… and $($invalid.Count-5) more invalid lines."};throw $message}
    if(-not $entries.Count){throw 'Paste at least one video URL, one per line.'}
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root;$config=Get-CorpusConfig $Root
        if($SubjectId -and -not @($config.subjects | Where-Object id -eq $SubjectId).Count){throw 'The selected subject no longer exists.'}
        if($JobId -and -not @($queue.SyncJobs | Where-Object {$_.Id -eq $JobId -and $_.Status -eq 'Discovering'}).Count){return [pscustomobject]@{Added=0;Duplicates=0}}
        $added=0;$duplicates=0;$seen=@{};$listingById=@{};$newItems=[Collections.Generic.List[object]]::new()
        foreach($listing in $ListingEntries){$listingById[$listing.id]=$listing}
        foreach($item in $queue.Items){if($item.Status -in @('Pending','Running')){$seen[$item.VideoId]=$item}}
        foreach($entry in $entries){
            if($seen.ContainsKey($entry.Id)){
                $existing=$seen[$entry.Id]
                if($JobId){$existing.JobIds=@(@($existing.JobIds)+$JobId | Select-Object -Unique)}else{$existing.Batch=$true}
                $duplicates++;continue
            }
            $video=Read-CorpusJson (Join-Path $Root "data/normalized/videos/$($entry.Id).json")
            $archived=if($video){$config.archivedSubjects | Where-Object id -eq $video.SubjectId | Select-Object -First 1}else{$null}
            $effectiveId=if($archived){$archived.id}elseif($SubjectId){$SubjectId}elseif($video){$video.SubjectId}else{''}
            $subject=@((@($config.subjects)+@($config.archivedSubjects)) | Where-Object id -eq $effectiveId)
            if($effectiveId -and -not $subject.Count){throw 'A saved video references a missing subject. Select a subject explicitly.'}
            $newItem=[pscustomobject][ordered]@{
                Id=[guid]::NewGuid().ToString('N');VideoId=$entry.Id;Url=$entry.Url
                Title=$(if($video){$video.VideoTitle}else{Get-CorpusProperty $listingById[$entry.Id] title $entry.Id});SubjectId=$effectiveId;SubjectName=$(if($subject.Count){$subject[0].name}else{''})
                Status='Pending';Detail='';AddedAt=[datetime]::UtcNow.ToString('o');StartedAt=$null;FinishedAt=$null
                RefreshTranscript=[bool]$RefreshTranscript;ExportWorkbook=[bool]$ExportWorkbook
                JobIds=@(if($JobId){$JobId});Batch=(-not $JobId);ListingEntry=$listingById[$entry.Id]
            }
            $newItems.Add($newItem);$seen[$entry.Id]=$newItem;$added++
        }
        $queue.Items=@($queue.Items)+@($newItems)
        Save-CorpusQueue $Root $queue
        return [pscustomobject]@{Added=$added;Duplicates=$duplicates}
    } finally {$lock.Dispose()}
}
function Remove-CorpusQueueItems {
    param([string]$Root,[string[]]$Ids)
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root;$removed=0;$skipped=0
        $selected=@{};foreach($id in @($Ids | Select-Object -Unique)){if($id){$selected[$id]=$true}}
        $drop=@{};$jobsById=@{};foreach($job in $queue.SyncJobs){$jobsById[$job.Id]=$job}
        $skipped=$selected.Count
        foreach($item in $queue.Items){
            if(-not $selected.ContainsKey($item.Id) -or $item.Status -ne 'Pending'){continue}
            foreach($jobId in $item.JobIds){if($jobsById.ContainsKey($jobId)){$jobsById[$jobId] | Add-Member NoteProperty PartialImport $true -Force}}
            if(@($item.JobIds).Count){
                $item.Status='Cancelled';$item.Detail='Removed before download; partial channel import';$item.FinishedAt=[datetime]::UtcNow.ToString('o')
            }else{$drop[$item.Id]=$true}
            $removed++;$skipped--
        }
        $queue.Items=@($queue.Items | Where-Object {-not $drop.ContainsKey($_.Id)})
        Save-CorpusQueue $Root $queue
        return [pscustomobject]@{Removed=$removed;Skipped=$skipped}
    } finally {$lock.Dispose()}
}
function Update-CorpusQueue {
    param([string]$Root,[ValidateSet('Pause','Remove','Retry','ClearFinished')][string]$Action,[string]$Id='')
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root
        if($Action -eq 'Pause'){$queue.Paused=$true}
        elseif($Action -eq 'ClearFinished'){
            $jobsById=@{};foreach($job in $queue.SyncJobs){$jobsById[$job.Id]=$job}
            foreach($item in $queue.Items){
                if($item.Status -in @('Pending','Running')){continue}
                foreach($jobId in $item.JobIds){
                    if($jobsById.ContainsKey($jobId)){
                        $counts=$jobsById[$jobId].ClearedResults
                        if($counts.PSObject.Properties[$item.Status]){$counts.($item.Status)++}
                    }
                }
            }
            $queue.Items=@($queue.Items | Where-Object Status -in @('Pending','Running'))
        }
        else {
            $matches=@($queue.Items | Where-Object Id -eq $Id)
            if(-not $matches.Count){throw 'This queue item no longer exists.'};$item=$matches[0]
            if($Action -eq 'Remove'){
                if($item.Status -ne 'Pending'){throw 'Only pending items can be removed.'}
                foreach($job in $queue.SyncJobs){if($job.Id -in $item.JobIds){$job | Add-Member NoteProperty PartialImport $true -Force}}
                if(@($item.JobIds).Count){$item.Status='Cancelled';$item.Detail='Removed before download';$item.FinishedAt=[datetime]::UtcNow.ToString('o')}else{$queue.Items=@($queue.Items | Where-Object Id -ne $Id)}
            } else {
                if($item.Status -notin @('Failed','Cancelled')){throw 'Only failed or cancelled items can be retried.'}
                if(@($queue.Items | Where-Object {$_.VideoId -eq $item.VideoId -and $_.Status -in @('Pending','Running')}).Count){throw 'This video is already queued.'}
                $subject=@((Get-CorpusConfig $Root).subjects | Where-Object id -eq $item.SubjectId)
                if($item.SubjectId -and -not $subject.Count){throw 'The subject no longer exists. Add the URL again with a current subject.'}
                $activeJobs=@($queue.SyncJobs | Where-Object {$_.Id -in $item.JobIds -and $_.Status -in @('Pending','Discovering','Downloading','Cancelling')})
                if($activeJobs.Count){$item=$item | Select-Object *;$item.Id=[guid]::NewGuid().ToString('N');$item.AddedAt=[datetime]::UtcNow.ToString('o');$queue.Items=@($queue.Items)+$item}
                $item.SubjectName=if($subject.Count){$subject[0].name}else{''}
                $item.Status='Pending';$item.Detail='';$item.StartedAt=$null;$item.FinishedAt=$null;$item.JobIds=@();$item.Batch=$true
            }
        }
        Save-CorpusQueue $Root $queue
    } finally {$lock.Dispose()}
}
function Invoke-CorpusQueue {
    param([string]$Root,$Shared=$null)
    $runner=Enter-CorpusQueueRunner $Root;$writer=$null;$dependency=$null;$commit=$null
    try {
        $dependency=Enter-CorpusDependencyLock;$commit=Enter-CorpusDependencyLock -Commit
        $writer=[IO.File]::Open((Join-Path $Root 'data/corpus.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $lock=Enter-CorpusConfigLock $Root
        try {
            $queue=Get-CorpusQueue $Root;$queue.Paused=$false
            foreach($job in $queue.SyncJobs){if($job.Status -eq 'Discovering'){$job.Status='Pending'}}
            foreach($item in $queue.Items){if($item.Status -eq 'Running'){$item.Status='Pending';$item.Detail='Resuming interrupted work.'}}
            Save-CorpusQueue $Root $queue
        } finally {$lock.Dispose()}
        while($true){
            $lock=Enter-CorpusConfigLock $Root
            try {
                $queue=Get-CorpusQueue $Root
                if($queue.Paused -or ($Shared -and $Shared.Cancel)){break}
                $pending=@($queue.Items | Where-Object Status -eq Pending | Select-Object -First 1)
                $discover=$null
                $jobs=@($queue.SyncJobs | Where-Object Status -eq Pending | Select-Object -First 1)
                if($jobs.Count){
                    $discover=$jobs[0];$discover.Status='Discovering';Save-CorpusQueue $Root $queue
                }
                if(-not $discover -and -not $pending.Count){$queue.Paused=$true;Save-CorpusQueue $Root $queue;break}
                if($discover){$item=$null}else {
                $item=$pending[0];$item.Status='Running';$item.StartedAt=[datetime]::UtcNow.ToString('o');$item.Detail='Downloading metadata and transcript'
                }
                Save-CorpusQueue $Root $queue
            } finally {$lock.Dispose()}
            if($Shared){$Shared.Progress=@{Stage=$(if($discover){'Discovering channel'}else{'Downloading video'});Item=$(if($discover){$discover.Url}else{$item.Title});Current=0;Total=0}}
            if($discover){Invoke-CorpusQueuedDiscovery $Root $discover $Shared;continue}
            $status='Completed';$detail='';$pause=$false
            try {
                $run=Invoke-CorpusOperation $Root Video @{Url=$item.Url;SubjectId=$item.SubjectId;SubjectName=$item.SubjectName;RefreshTranscript=$item.RefreshTranscript;SkipWorkbook=(-not $item.ExportWorkbook);ListingEntry=$item.ListingEntry} $Shared -CorpusLock $writer
                if($run.MembersOnlySkipped -gt 0){$status='Skipped';$detail='Members-only video'}
                elseif($run.TranscriptsUnavailable -gt 0){$status='Skipped';$detail='No original English transcript available'}
                elseif($run.FinalState -ne 'Success'){$status='Failed';$detail="Import ended: $($run.FinalState)"}
            } catch {
                $detail=$_.Exception.GetBaseException().Message
                if(($Shared -and $Shared.Cancel) -or $_.Exception -is [OperationCanceledException]){
                    $status=if($Shared -and $Shared.ContainsKey('Shutdown') -and $Shared.Shutdown){'Pending'}else{'Cancelled'};$pause=$true
                } elseif(Test-CorpusRateLimitError $_.Exception){$status='Pending';$pause=$true;$detail='Rate limited. Wait for the cooldown, then resume.'}
                else {$status='Failed'}
            }
            $lock=Enter-CorpusConfigLock $Root
            try {
                # Reload before completion: the GUI may have appended, removed, or paused items meanwhile.
                $queue=Get-CorpusQueue $Root;$saved=@($queue.Items | Where-Object Id -eq $item.Id)[0]
                $saved.Status=$status;$saved.Detail=$detail;$saved.FinishedAt=[datetime]::UtcNow.ToString('o')
                $video=Read-CorpusJson (Join-Path $Root "data/normalized/videos/$($item.VideoId).json")
                if($video){$saved.Title=$video.VideoTitle}
                if($pause){$queue.Paused=$true}
                Save-CorpusQueue $Root $queue
            } finally {$lock.Dispose()}
            if($pause){break}
        }
    } finally {
        try{$lock=Enter-CorpusConfigLock $Root;try{$queue=Get-CorpusQueue $Root;$queue.Paused=$true;Save-CorpusQueue $Root $queue}finally{$lock.Dispose()}}finally{if($writer){$writer.Dispose()};if($commit){$commit.ReleaseMutex();$commit.Dispose()};if($dependency){$dependency.ReleaseMutex();$dependency.Dispose()};$runner.Dispose()}
    }
}
function Update-CorpusSyncStates {
    param([string]$Root,$Queue)
    foreach($job in $Queue.SyncJobs){
        if($job.Status -notin @('Downloading','Cancelling')){continue}
        $children=@($Queue.Items | Where-Object {$job.Id -in $_.JobIds})
        if(@($children | Where-Object Status -in @('Pending','Running')).Count){continue}
        $cleared=Get-CorpusProperty $job ClearedResults $null
        $failed=@($children | Where-Object Status -eq Failed).Count+[int](Get-CorpusProperty $cleared Failed 0)
        $cancelled=@($children | Where-Object Status -eq Cancelled).Count+[int](Get-CorpusProperty $cleared Cancelled 0)
        $total=$children.Count
        foreach($status in @('Completed','Skipped','Failed','Cancelled')){$total += [int](Get-CorpusProperty $cleared $status 0)}
        $job.Status=if((Get-CorpusProperty $job PartialImport $false) -and $job.Status -ne 'Cancelling'){'Partial'}elseif($job.Status -eq 'Cancelling' -or ($total -gt 0 -and $cancelled -eq $total)){'Cancelled'}elseif($failed -gt 0 -or $cancelled -gt 0){'Partial'}else{'Completed'}
        $job.Detail="$total videos; $failed failed; $cancelled cancelled"
        $job.FinishedAt=[datetime]::UtcNow.ToString('o')
        if($job.ChannelId){
            $path=Join-Path $Root "data/normalized/channels/$($job.ChannelId).json";$channel=Read-CorpusJson $path
            if($channel){
                $videos=@(Get-CorpusVideos $Root | Where-Object ChannelId -eq $job.ChannelId)
                $channel.TranscriptCount=@($videos | Where-Object TranscriptAvailable).Count
                $channel.WithoutTranscripts=@($videos | Where-Object {-not $_.TranscriptAvailable}).Count
                $channel.Failures=$failed
                $channel.MembersOnlySkipped=@($videos | Where-Object LastSyncStatus -eq SkippedMembersOnly).Count
                $channel.Status=$job.Status;if($job.Status -eq 'Completed'){$channel.LastSync=$job.FinishedAt}
                Write-CorpusJson $path $channel
            }
            Write-CorpusJson (Join-Path $Root "data/normalized/channel-attempts/$(Get-CorpusId $job.Url).json") ([ordered]@{Url=$job.Url;LastAttempt=$job.AddedAt;Status=$job.Status})
        }
    }
}
function Add-CorpusSyncJob {
    param([string]$Root,[string]$Url,[string]$SubjectId,[switch]$RefreshTranscript,[switch]$ExportWorkbook)
    $lock=Enter-CorpusConfigLock $Root
    try {
        $config=Get-CorpusConfig $Root;$subjects=@($config.subjects | Where-Object id -eq $SubjectId)
        if(-not $subjects.Count -or -not @($subjects[0].channels | Where-Object url -eq $Url).Count){throw 'Select a configured channel and subject.'}
        $queue=Get-CorpusQueue $Root
        $known=@(Get-ChildItem (Join-Path $Root data/normalized/channels) -Filter '*.json' | ForEach-Object {Read-CorpusJson $_.FullName} | Where-Object {$Url -in $_.Urls})
        $channelId=if($known.Count){$known[0].ChannelId}else{''}
        if(@($queue.SyncJobs | Where-Object {($_.Url -eq $Url -or ($channelId -and $_.ChannelId -eq $channelId)) -and $_.Status -in @('Pending','Discovering','Downloading','Cancelling')}).Count){return $null}
        $job=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');Url=$Url;SubjectId=$SubjectId;SubjectName=$subjects[0].name;ChannelId=$channelId;Status='Pending';Detail='Waiting for discovery';AddedAt=[datetime]::UtcNow.ToString('o');FinishedAt=$null;RefreshTranscript=[bool]$RefreshTranscript;ExportWorkbook=[bool]$ExportWorkbook}
        if(-not @($queue.SyncJobs | Where-Object Status -in @('Pending','Discovering','Downloading','Cancelling')).Count -and -not @($queue.Items | Where-Object Status -in @('Pending','Running')).Count){$queue.DiscoveryJobIds=@()}
        $queue.DiscoveryJobIds=@($queue.DiscoveryJobIds)+$job.Id
        $queue.SyncJobs=@($queue.SyncJobs)+$job;Save-CorpusQueue $Root $queue;return $job.Id
    } finally {$lock.Dispose()}
}
function Stop-CorpusSyncJob {
    param([string]$Root,[string]$Id)
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root;$jobs=@($queue.SyncJobs | Where-Object Id -eq $Id)
        if(-not $jobs.Count){throw 'Sync job no longer exists.'};$job=$jobs[0]
        if($job.Status -notin @('Pending','Discovering','Downloading','Cancelling')){return}
        $job.Status='Cancelling';$job.Detail='Cancelling waiting downloads; an active download may finish.'
        foreach($item in $queue.Items){
            if($Id -notin $item.JobIds -or $item.Status -ne 'Pending'){continue}
            $other=@($queue.SyncJobs | Where-Object {$_.Id -ne $Id -and $_.Id -in $item.JobIds -and $_.Status -in @('Pending','Discovering','Downloading')})
            if($item.Batch -or $other.Count){$item.JobIds=@($item.JobIds | Where-Object {$_ -ne $Id});continue}
            if(-not $other.Count){$item.Status='Cancelled';$item.Detail='Channel sync cancelled';$item.FinishedAt=[datetime]::UtcNow.ToString('o')}
        }
        Save-CorpusQueue $Root $queue
    } finally {$lock.Dispose()}
}
function Invoke-CorpusQueuedDiscovery {
    param([string]$Root,$Job,$Shared)
    if($Shared){$Shared.ActiveSyncId=$Job.Id}
    $status='Downloading';$detail='';$channelId='';$pause=$false
    try {
        $ctx=New-CorpusContext $Root $Shared
        $run=[pscustomobject]@{VideosDiscovered=0;MembersOnlySkipped=0;Failures=0}
        $result=Sync-CorpusChannel $ctx $Job.Url $Job.SubjectId $Job.SubjectName $run -DiscoverOnly
        $channelId=$result.ChannelId
        if(@($result.Entries).Count){
            $text=(@($result.Entries | ForEach-Object {"https://www.youtube.com/watch?v=$($_.id)"}) -join "`n")
            $null=Add-CorpusQueueUrls $Root $text $Job.SubjectId -RefreshTranscript:$Job.RefreshTranscript -ExportWorkbook:$Job.ExportWorkbook -JobId $Job.Id -ListingEntries $result.Entries
        }
    } catch {
        $detail=$_.Exception.GetBaseException().Message
        if(Test-CorpusRateLimitError $_.Exception){$status='Pending';$pause=$true}
        elseif($_.Exception -is [OperationCanceledException]){
            $status=if($Shared -and $Shared.ContainsKey('Shutdown') -and $Shared.Shutdown){'Pending'}else{'Cancelled'}
            $pause=($Shared -and $Shared.Cancel)
        } else {$status='Failed'}
    } finally {if($Shared){$Shared.ActiveSyncId=''}}
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root;$saved=@($queue.SyncJobs | Where-Object Id -eq $Job.Id)[0]
        if($saved.Status -eq 'Discovering'){$saved.Status=$status;$saved.Detail=$detail;if($status -in @('Cancelled','Failed')){$saved.FinishedAt=[datetime]::UtcNow.ToString('o')}}
        if($channelId){$saved.ChannelId=$channelId}
        if($pause){$queue.Paused=$true};Save-CorpusQueue $Root $queue
    } finally {$lock.Dispose()}
}

function Get-CorpusQueueItemIndicator {
    param([string]$Status)
    switch($Status){
        'Pending'   {return [pscustomobject]@{Glyph='…';Color='#A96900';Label='Pending'}}
        'Running'   {return [pscustomobject]@{Glyph='▶';Color='#176BC1';Label='Downloading'}}
        'Completed' {return [pscustomobject]@{Glyph='✓';Color='#23844A';Label='Completed'}}
        'Skipped'   {return [pscustomobject]@{Glyph='−';Color='#657489';Label='Skipped'}}
        'Failed'    {return [pscustomobject]@{Glyph='!';Color='#C52A35';Label='Failed'}}
        'Cancelled' {return [pscustomobject]@{Glyph='×';Color='#A94350';Label='Cancelled'}}
        default     {return [pscustomobject]@{Glyph='?';Color='#657489';Label=$Status}}
    }
}
function Get-CorpusQueueProgress {
    param($Queue)
    $discoveryIds=@(Get-CorpusProperty $Queue DiscoveryJobIds @())
    $jobs=@($Queue.SyncJobs | Where-Object {$_.Id -in $discoveryIds -or $_.Status -in @('Pending','Discovering','Downloading','Cancelling')})
    $waiting=@($jobs | Where-Object Status -in @('Pending','Discovering')).Count
    $discovered=$jobs.Count-$waiting
    $pending=@($Queue.Items | Where-Object Status -eq Pending).Count
    $running=@($Queue.Items | Where-Object Status -eq Running).Count
    $finished=$Queue.Items.Count-$pending-$running
    $failures=@($Queue.Items | Where-Object Status -eq Failed).Count
    $discoveryFailures=@($jobs | Where-Object Status -eq Failed).Count
    if($waiting){
        $phase=if($running){'Finishing current video before discovery'}elseif($Queue.Paused -and @($jobs | Where-Object Status -eq Discovering).Count){'Pausing discovery'}elseif($Queue.Paused){'Discovery paused'}else{'Discovering channels'}
        $text="${phase}: $discovered of $($jobs.Count) listed or resolved · $($Queue.Items.Count) videos currently listed. Downloads wait for every queued channel."
        $maximum=[math]::Max(1,$jobs.Count);$value=$discovered
    }else{
        $phase=if(-not $Queue.Items.Count){'Queue empty'}elseif(-not $pending -and -not $running){'Queue complete'}elseif($Queue.Paused -and $running){'Pausing downloads'}elseif($Queue.Paused){'Queue paused'}else{'Downloading videos'}
        $text="$phase · $finished of $($Queue.Items.Count) visible videos finished · $pending pending · $running downloading · $failures failed"
        $maximum=[math]::Max(1,$Queue.Items.Count);$value=$finished
    }
    if($discoveryFailures){$text+=" · $discoveryFailures channel discovery failures (see Channels)"}
    [pscustomobject]@{Text=$text;Phase=$phase;Maximum=$maximum;Value=$value;Pending=$pending;Running=$running;Finished=$finished;WaitingChannels=$waiting;DiscoveryTotal=$jobs.Count;DiscoveryFinished=$discovered}
}

Export-ModuleMember -Function Get-CorpusQueue,Get-CorpusQueueItemIndicator,Get-CorpusQueueProgress,Enter-CorpusQueueRunner,Remove-CorpusQueueItems,Initialize-CorpusQueue,Add-CorpusQueueUrls,Update-CorpusQueue,Invoke-CorpusQueue,Add-CorpusSyncJob,Stop-CorpusSyncJob
