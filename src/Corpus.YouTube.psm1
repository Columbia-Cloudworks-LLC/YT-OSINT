Set-StrictMode -Version 2
function Get-CorpusYtArguments {
    $nativeRoot=Get-CorpusNativeRoot
    @('--ffmpeg-location',$nativeRoot,'--no-js-runtimes','--js-runtimes',('deno:'+(Join-Path $nativeRoot 'deno.exe')))
    @('--ignore-config','--no-color','--no-progress','--encoding','utf-8','--socket-timeout','30','--retries','2','--extractor-retries','2','--skip-download')
}
function Get-CorpusMetadata {
    param($Context,[string]$Url)
    $url=Assert-CorpusYouTubeUrl $Url
    $r=Invoke-CorpusProcess $Context (Join-Path (Get-CorpusNativeRoot) 'yt-dlp.exe') ((Get-CorpusYtArguments)+@('--no-playlist','--dump-single-json','--',$url)) -Quiet
    if($r.ExitCode) { throw "yt-dlp metadata retrieval failed (exit $($r.ExitCode)). See the run log for details." }
    try { $meta=$r.StdOut | ConvertFrom-Json } catch { throw 'yt-dlp returned invalid metadata JSON.' }
    if((Get-CorpusProperty $meta id '') -notmatch '^[A-Za-z0-9_-]{11}$') { throw 'The URL did not resolve to an individual YouTube video.' }
    return [pscustomobject]@{Metadata=$meta;Raw=$r.StdOut}
}
function ConvertTo-CorpusVideo {
    param($Metadata,[string]$SubjectId='',[string]$SubjectName='',[string]$CapturedAt=([datetime]::UtcNow.ToString('o')))
    $date=Get-CorpusProperty $Metadata upload_date ''; $published=$null
    if($date -match '^\d{8}$') { $published=[datetime]::ParseExact($date,'yyyyMMdd',[Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd') }
    $id=Get-CorpusProperty $Metadata id ''
    [pscustomobject][ordered]@{SubjectId=$SubjectId;SubjectName=$SubjectName;ChannelId=(Get-CorpusProperty $Metadata channel_id 'unknown');ChannelName=(Get-CorpusProperty $Metadata channel 'Unknown');VideoTitle=(Get-CorpusProperty $Metadata title $id);VideoId=$id;PublishedDate=$published;Duration=(Get-CorpusProperty $Metadata duration);VideoUrl="https://www.youtube.com/watch?v=$id";Description=(Get-CorpusProperty $Metadata description '');ViewCount=(Get-CorpusProperty $Metadata view_count);LikeCount=(Get-CorpusProperty $Metadata like_count);SubtitleSource='None';TranscriptAvailable=$false;MetadataCapturedAt=$CapturedAt;TranscriptCapturedAt=$null;LastSyncStatus='MetadataCaptured';TranscriptPath='';RawMetadataPath='';LastAttemptAt=$CapturedAt;LastError=''}
}
function Select-CorpusSubtitle {
    param($Metadata)
    foreach($kind in @('subtitles','automatic_captions')) {
        $subs=Get-CorpusProperty $Metadata $kind
        if(-not $subs) { continue }
        $languages=@($subs.PSObject.Properties | ForEach-Object { $_.Name } | Where-Object { $_ -match '^en(?:[-_].+)?$' } | Sort-Object @{Expression={if($_ -eq 'en'){0}elseif($_ -eq 'en-orig'){1}else{2}}}, @{Expression={$_}})
        foreach($language in $languages) {
            if(@($subs.$language | Where-Object { (Get-CorpusProperty $_ ext '') -eq 'vtt' }).Count) { return [pscustomobject]@{Language=$language;Source=$(if($kind -eq 'subtitles'){'Manual'}else{'Automatic'})} }
        }
    }
    return $null
}
function Save-CorpusRawArtifact {
    param([string]$Directory,[string]$FileName,[string]$Text,[string]$SourcePath='')
    [IO.Directory]::CreateDirectory($Directory) | Out-Null
    $bytes=if($SourcePath){[IO.File]::ReadAllBytes($SourcePath)}else{[Text.Encoding]::UTF8.GetBytes($Text)}
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $id=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant() } finally { $hash.Dispose() }
    $path=Join-Path $Directory "$id/$FileName"
    if(-not (Test-Path -LiteralPath $path)) {
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
        $temp="$path.$([guid]::NewGuid().ToString('N')).tmp"
        try { [IO.File]::WriteAllBytes($temp,$bytes); [IO.File]::Move($temp,$path) } finally { if(Test-Path $temp){Remove-Item -LiteralPath $temp} }
    }
    return $path
}
function Import-CorpusVideo {
    param($Context,[string]$Url,[string]$SubjectId='',[string]$SubjectName='',$Run=$null)
    Test-CorpusCancellation $Context
    Set-CorpusProgress $Context 'Metadata retrieval' $Url
    $capture=Get-CorpusMetadata $Context $Url; $meta=$capture.Metadata
    $v=ConvertTo-CorpusVideo $meta $SubjectId $SubjectName
    $old=Read-CorpusJson (Join-Path $Context.Root "data/normalized/videos/$($v.VideoId).json")
    if($Run) { if($old){$Run.VideosAlreadyKnown++}else{$Run.VideosAdded++} }
    if($old -and -not $SubjectId) { $v.SubjectId=$old.SubjectId; $v.SubjectName=$old.SubjectName }
    if($v.ChannelId -notmatch '^[A-Za-z0-9_-]+$') { throw 'yt-dlp returned an invalid channel ID.' }
    $rawDir=Join-Path $Context.Root "data/raw/$($v.ChannelId)/$($v.VideoId)"
    $raw=Save-CorpusRawArtifact $rawDir "$($v.VideoId).info.json" $capture.Raw
    $v.RawMetadataPath=$raw.Substring($Context.Root.Length+1)
    # Each observation records its capture time, even when artifact bytes are identical.
    Write-CorpusJson (Join-Path $rawDir "observations/$($Context.RunId)-$([datetime]::UtcNow.Ticks).json") ([ordered]@{CapturedAt=$v.MetadataCapturedAt;MetadataPath=$v.RawMetadataPath;RunId=$Context.RunId})
    if($old -and $old.TranscriptAvailable) {
        $v.TranscriptPath=$old.TranscriptPath; $v.TranscriptAvailable=$true; $v.TranscriptCapturedAt=$old.TranscriptCapturedAt; $v.SubtitleSource=$old.SubtitleSource
    }
    # Commit metadata before captions so a caption failure never discards it.
    Save-CorpusVideo $Context $v
    try {
        $sub=Select-CorpusSubtitle $meta
        if(-not $sub) {
            if(-not $v.TranscriptAvailable) { $v.LastSyncStatus='Unavailable' } else { $v.LastSyncStatus='CaptionsNoLongerAvailable' }
            if($Run) { $Run.TranscriptsUnavailable++ }
            Write-CorpusLog $Context Warning Subtitles $v.VideoId "Transcript unavailable for $($v.VideoId): no English manual or automatic VTT subtitles were reported by yt-dlp."
        } else {
            Set-CorpusProgress $Context 'Subtitle retrieval' $v.VideoTitle
            $stage=Join-Path $Context.Root "data/staging/$($Context.RunId)/$($v.VideoId)"
            [IO.Directory]::CreateDirectory($stage) | Out-Null
            try {
                $flag=if($sub.Source -eq 'Manual'){'--write-subs'}else{'--write-auto-subs'}
                $r=Invoke-CorpusProcess $Context (Join-Path (Get-CorpusNativeRoot) 'yt-dlp.exe') ((Get-CorpusYtArguments)+@('--load-info-json',$raw,$flag,'--sub-langs',$sub.Language,'--sub-format','vtt','--output',(Join-Path $stage '%(id)s.%(ext)s')))
                if($r.ExitCode) { throw "Subtitle retrieval failed (yt-dlp exit $($r.ExitCode))." }
                $file=@(Get-ChildItem $stage -Filter '*.vtt')
                if(-not $file.Count) { throw 'yt-dlp reported captions but did not produce a VTT file.' }
                $subtitle=Save-CorpusRawArtifact (Join-Path $rawDir "$($sub.Source)/$($sub.Language)") $file[0].Name '' $file[0].FullName
                Set-CorpusProgress $Context 'Transcript normalization' $v.VideoTitle
                $rows=@(ConvertFrom-CorpusVtt $subtitle $v $sub.Source $sub.Language $v.MetadataCapturedAt $Context)
                if(-not $rows.Count) { throw 'Subtitle file contains no usable transcript text.' }
                $v.TranscriptPath="data/normalized/transcripts/$($v.VideoId)/$($Context.RunId).json"
                Write-CorpusJson (Join-Path $Context.Root $v.TranscriptPath) $rows
                $v.TranscriptAvailable=$true; $v.TranscriptCapturedAt=$v.MetadataCapturedAt; $v.SubtitleSource=$sub.Source; $v.LastSyncStatus='Success'
                if($Run -and (-not $old -or -not $old.TranscriptAvailable)) { $Run.TranscriptsAdded++ }
            } finally { if(Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force } }
        }
    } catch {
        if($_.Exception -is [OperationCanceledException]) { $v.LastSyncStatus='Cancelled'; Save-CorpusVideo $Context $v; throw }
        $v.LastSyncStatus='Failed'; $v.LastError=$_.Exception.Message
        if($Run){$Run.Failures++}
        Write-CorpusLog $Context Error Subtitles $v.VideoId $v.LastError $_.ToString()
    }
    Save-CorpusVideo $Context $v
    return $v
}
function Save-CorpusFailure {
    param($Context,[string]$VideoId,[string]$Message,[string]$SubjectId='',[string]$SubjectName='',[string]$ChannelId='unknown')
    if($VideoId -notmatch '^[A-Za-z0-9_-]{11}$') { return }
    $v=Read-CorpusJson (Join-Path $Context.Root "data/normalized/videos/$VideoId.json")
    if(-not $v) { $v=ConvertTo-CorpusVideo ([pscustomobject]@{id=$VideoId;channel_id=$ChannelId}) $SubjectId $SubjectName; $v.MetadataCapturedAt=$null }
    $v.LastSyncStatus='Failed'; $v.LastAttemptAt=[datetime]::UtcNow.ToString('o'); $v.LastError=$Message
    Save-CorpusVideo $Context $v
    Write-CorpusJson (Join-Path $Context.Root "data/raw/$ChannelId/$VideoId/observations/$($Context.RunId)-$([datetime]::UtcNow.Ticks)-failure.json") ([ordered]@{CapturedAt=$v.LastAttemptAt;Status='Failed';Message=$Message})
}
function Sync-CorpusChannel {
    param($Context,[string]$Url,[string]$SubjectId,[string]$SubjectName,$Run,[int]$Limit=0)
    $url=Assert-CorpusYouTubeUrl $Url
    $attempt=[datetime]::UtcNow.ToString('o'); $key=Get-CorpusId $url
    Write-CorpusJson (Join-Path $Context.Root "data/normalized/channel-attempts/$key.json") ([ordered]@{Url=$url;LastAttempt=$attempt;Status='Running'})
    $channel=$null
    try {
        Set-CorpusProgress $Context 'Channel enumeration' $url 0 0
        $args=(Get-CorpusYtArguments)+@('--flat-playlist','--dump-single-json','--ignore-errors')
        if($Limit -gt 0){$args+=@('--playlist-end',"$Limit")}
        $r=Invoke-CorpusProcess $Context (Join-Path (Get-CorpusNativeRoot) 'yt-dlp.exe') ($args+@('--',$url)) -TimeoutSeconds 1800 -Quiet
        if($r.ExitCode){throw "Channel enumeration failed (yt-dlp exit $($r.ExitCode))."}
        $listing=$r.StdOut | ConvertFrom-Json
        $id=Get-CorpusProperty $listing channel_id (Get-CorpusProperty $listing id '')
        if($id -notmatch '^UC[A-Za-z0-9_-]{22}$'){throw 'URL did not resolve to a YouTube channel. Use a channel URL or handle.'}
        $old=Read-CorpusJson (Join-Path $Context.Root "data/normalized/channels/$id.json")
        # The resolved ID, rather than a channel name, identifies aliases of the same channel.
        if($old -and $old.SubjectId -and $old.SubjectId -ne $SubjectId) {
            $config=Get-CorpusConfig $Context.Root
            $owner=@($config.subjects | Where-Object id -eq $old.SubjectId)
            if($owner.Count -and @($owner[0].channels | Where-Object { $_.url -in $old.Urls }).Count) { throw 'This channel ID is already explicitly assigned to another subject.' }
        }
        $urls=@($url); if($old){$urls=@($old.Urls)+$url | Select-Object -Unique}
        $channel=[pscustomobject]@{SubjectId=$SubjectId;Subject=$SubjectName;ChannelName=(Get-CorpusProperty $listing channel (Get-CorpusProperty $listing title $id));ChannelId=$id;Handle=(Get-CorpusProperty $listing uploader_id '');Url=$url;Urls=@($urls);FirstCaptured=$(if($old){$old.FirstCaptured}else{$attempt});LastSync=$(if($old){$old.LastSync}else{$null});LastAttempt=$attempt;VideosDiscovered=0;TranscriptCount=0;WithoutTranscripts=0;Failures=0;Status='Running'}
        $null=Save-CorpusRawArtifact (Join-Path $Context.Root "data/raw/$id/channel") 'channel.info.json' $r.StdOut
        $entries=[Collections.Generic.List[object]]::new(); $seen=@{}
        function Add-Entries($node) {
            if($node.PSObject.Properties['entries']) { foreach($e in $node.entries){if($e){Add-Entries $e}} }
            elseif((Get-CorpusProperty $node id '') -match '^[A-Za-z0-9_-]{11}$' -and -not $seen.ContainsKey($node.id)) { $seen[$node.id]=$true; $entries.Add($node) }
        }
        Add-Entries $listing
        if(-not $entries.Count -and $r.StdErr){throw 'Channel enumeration returned zero videos with extractor warnings; this is not a confirmed empty channel. Check the log and installed yt-dlp version.'}
        if($Limit -gt 0 -and $entries.Count -gt $Limit){$entries=@($entries | Select-Object -First $Limit)}
        $Run.VideosDiscovered+=$entries.Count; $channel.VideosDiscovered=$entries.Count
        Write-CorpusJson (Join-Path $Context.Root "data/normalized/channels/$id.json") $channel
        $n=0; $before=$Run.Failures
        foreach($e in $entries) {
            Test-CorpusCancellation $Context; $n++
            Set-CorpusProgress $Context "Syncing $($channel.ChannelName)" $e.id $n $entries.Count
            try { $null=Import-CorpusVideo $Context "https://www.youtube.com/watch?v=$($e.id)" $SubjectId $SubjectName $Run }
            catch {
                if($_.Exception -is [OperationCanceledException]){throw}
                $Run.Failures++; Save-CorpusFailure $Context $e.id $_.Exception.Message $SubjectId $SubjectName $id
                Write-CorpusLog $Context Error Video $e.id $_.Exception.Message $_.ToString()
            }
        }
        $videos=@(Get-CorpusVideos $Context.Root | Where-Object ChannelId -eq $id)
        $channel.TranscriptCount=@($videos | Where-Object TranscriptAvailable).Count
        $channel.WithoutTranscripts=@($videos | Where-Object {-not $_.TranscriptAvailable}).Count
        $channel.Failures=$Run.Failures-$before; $channel.Status=if($channel.Failures){'Partial'}else{'Success'}
        if(-not $channel.Failures){$channel.LastSync=[datetime]::UtcNow.ToString('o')}
    } catch {
        if($channel){$channel.Status=if($_.Exception -is [OperationCanceledException]){'Cancelled'}else{'Failed'}}
        throw
    } finally {
        if($channel){Write-CorpusJson (Join-Path $Context.Root "data/normalized/channels/$($channel.ChannelId).json") $channel}
        Write-CorpusJson (Join-Path $Context.Root "data/normalized/channel-attempts/$key.json") ([ordered]@{Url=$url;LastAttempt=$attempt;Status=$(if($channel){$channel.Status}elseif($Context.Shared -and $Context.Shared.Cancel){'Cancelled'}else{'Failed'})})
    }
}
Export-ModuleMember -Function *-Corpus*
