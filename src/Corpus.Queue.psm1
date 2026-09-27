Set-StrictMode -Version 2
function Get-CorpusQueue {
    param([string]$Root)
    $queue=Read-CorpusJson (Join-Path $Root 'data/queue.json')
    if(-not $queue){return [pscustomobject]@{SchemaVersion=1;Paused=$true;Items=@()}}
    if($queue.SchemaVersion -ne 1){throw 'Unsupported queue format.'}
    return $queue
}
function Save-CorpusQueue {
    param([string]$Root,$Queue)
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
            foreach($item in $queue.Items){if($item.Status -eq 'Running'){$item.Status='Pending';$item.Detail='Interrupted. Resume to continue using saved work.';$item.FinishedAt=$null}}
            Save-CorpusQueue $Root $queue
            return $queue
        } finally {$lock.Dispose()}
    } finally {$runner.Dispose()}
}
function Add-CorpusQueueUrls {
    param([string]$Root,[string]$Text,[string]$SubjectId='',[switch]$RefreshTranscript,[switch]$ExportWorkbook)
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
        $added=0;$duplicates=0;$seen=@{}
        foreach($item in $queue.Items){if($item.Status -in @('Pending','Running')){$seen[$item.VideoId]=$true}}
        foreach($entry in $entries){
            if($seen.ContainsKey($entry.Id)){$duplicates++;continue}
            $video=Read-CorpusJson (Join-Path $Root "data/normalized/videos/$($entry.Id).json")
            $archived=Get-CorpusArchivedVideoSubject $Root $video
            $effectiveId=if($archived){$archived.id}elseif($SubjectId){$SubjectId}elseif($video){$video.SubjectId}else{''}
            $subject=@((@($config.subjects)+@($config.archivedSubjects)) | Where-Object id -eq $effectiveId)
            if($effectiveId -and -not $subject.Count){throw 'A saved video references a missing subject. Select a subject explicitly.'}
            $queue.Items=@($queue.Items)+[pscustomobject][ordered]@{
                Id=[guid]::NewGuid().ToString('N');VideoId=$entry.Id;Url=$entry.Url
                Title=$(if($video){$video.VideoTitle}else{$entry.Id});SubjectId=$effectiveId;SubjectName=$(if($subject.Count){$subject[0].name}else{''})
                Status='Pending';Detail='';AddedAt=[datetime]::UtcNow.ToString('o');StartedAt=$null;FinishedAt=$null
                RefreshTranscript=[bool]$RefreshTranscript;ExportWorkbook=[bool]$ExportWorkbook
            }
            $seen[$entry.Id]=$true;$added++
        }
        Save-CorpusQueue $Root $queue
        return [pscustomobject]@{Added=$added;Duplicates=$duplicates}
    } finally {$lock.Dispose()}
}
function Update-CorpusQueue {
    param([string]$Root,[ValidateSet('Pause','Remove','Retry','ClearFinished')][string]$Action,[string]$Id='')
    $lock=Enter-CorpusConfigLock $Root
    try {
        $queue=Get-CorpusQueue $Root
        if($Action -eq 'Pause'){$queue.Paused=$true}
        elseif($Action -eq 'ClearFinished'){$queue.Items=@($queue.Items | Where-Object {$_.Status -in @('Pending','Running')})}
        else {
            $matches=@($queue.Items | Where-Object Id -eq $Id)
            if(-not $matches.Count){throw 'This queue item no longer exists.'};$item=$matches[0]
            if($Action -eq 'Remove'){
                if($item.Status -ne 'Pending'){throw 'Only pending items can be removed.'}
                $queue.Items=@($queue.Items | Where-Object Id -ne $Id)
            } else {
                if($item.Status -notin @('Failed','Cancelled')){throw 'Only failed or cancelled items can be retried.'}
                if(@($queue.Items | Where-Object {$_.VideoId -eq $item.VideoId -and $_.Status -in @('Pending','Running')}).Count){throw 'This video is already queued.'}
                $subject=@((Get-CorpusConfig $Root).subjects | Where-Object id -eq $item.SubjectId)
                if($item.SubjectId -and -not $subject.Count){throw 'The subject no longer exists. Add the URL again with a current subject.'}
                $item.SubjectName=if($subject.Count){$subject[0].name}else{''}
                $item.Status='Pending';$item.Detail='';$item.StartedAt=$null;$item.FinishedAt=$null
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
            foreach($item in $queue.Items){if($item.Status -eq 'Running'){$item.Status='Pending';$item.Detail='Resuming interrupted work.'}}
            Save-CorpusQueue $Root $queue
        } finally {$lock.Dispose()}
        while($true){
            $lock=Enter-CorpusConfigLock $Root
            try {
                $queue=Get-CorpusQueue $Root
                if($queue.Paused -or ($Shared -and $Shared.Cancel)){break}
                $pending=@($queue.Items | Where-Object Status -eq Pending | Select-Object -First 1)
                if(-not $pending.Count){$queue.Paused=$true;Save-CorpusQueue $Root $queue;break}
                $item=$pending[0];$item.Status='Running';$item.StartedAt=[datetime]::UtcNow.ToString('o');$item.Detail='Downloading metadata and transcript'
                Save-CorpusQueue $Root $queue
            } finally {$lock.Dispose()}
            $status='Completed';$detail='';$pause=$false
            try {
                $run=Invoke-CorpusOperation $Root Video @{Url=$item.Url;SubjectId=$item.SubjectId;SubjectName=$item.SubjectName;RefreshTranscript=$item.RefreshTranscript;SkipWorkbook=(-not $item.ExportWorkbook)} $Shared -CorpusLock $writer
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
Export-ModuleMember -Function Get-CorpusQueue,Initialize-CorpusQueue,Add-CorpusQueueUrls,Update-CorpusQueue,Invoke-CorpusQueue
