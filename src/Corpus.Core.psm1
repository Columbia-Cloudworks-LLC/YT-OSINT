Set-StrictMode -Version 2
function Get-CorpusProperty {
    param($Object, [string]$Name, $Default=$null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Write-CorpusJson {
    param([string]$Path, $Value)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject $Value -Depth 60), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) } else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-CorpusJson {
    param([string]$Path, $Default=$null)
    if (Test-Path -LiteralPath $Path) {
        # Hold a consistent file snapshot without blocking another worker's atomic replacement.
        $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
        try{return ($reader.ReadToEnd() | ConvertFrom-Json)}finally{$reader.Dispose()}
    }
    return $Default
}
function Get-CorpusId {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
}
function Assert-CorpusYouTubeUrl {
    param([string]$Url)
    $uri=$null
    if (-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -notin @('youtube.com','www.youtube.com','m.youtube.com','youtu.be') -or $uri.UserInfo) { throw 'Enter an HTTPS YouTube channel or video URL.' }
    return $uri.AbsoluteUri.TrimEnd('/')
}
function Get-CorpusConfig {
    param([string]$Root)
    if(Test-Path -LiteralPath (Join-Path $Root '.yt-osint-migration-incomplete')){throw 'This destination contains an incomplete corpus copy. Use the original corpus and retry Move into a new empty folder.'}
    $config=Read-CorpusJson (Join-Path $Root 'config.json')
    if (-not $config -or -not $config.PSObject.Properties['subjects']) { throw 'config.json must contain a subjects array.' }
    if(-not $config.PSObject.Properties['archivedSubjects']){$config | Add-Member NoteProperty archivedSubjects @()}
    $ids=@{}
    foreach($s in (@($config.subjects)+@($config.archivedSubjects))) {
        if (-not $s.id -or -not $s.name -or $ids.ContainsKey($s.id)) { throw 'Subjects require unique nonempty IDs and display names.' }
        $ids[$s.id]=$true
        foreach($c in $s.channels) { $null=Assert-CorpusYouTubeUrl $c.url }
    }
    return $config
}
function Enter-CorpusConfigLock {
    param([string]$Root)
    $null=[IO.Directory]::CreateDirectory((Join-Path $Root 'data'))
    $deadline=[datetime]::UtcNow.AddSeconds(5)
    while($true){
        try{return [IO.File]::Open((Join-Path $Root 'data/config.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{if([datetime]::UtcNow -ge $deadline){throw 'Configuration is busy. Try again shortly.'};Start-Sleep -Milliseconds 25}
    }
}
function Test-CorpusSubjectQueued {
    param([string]$Root,[string]$SubjectId)
    if(-not $SubjectId){return $false}
    $queue=Read-CorpusJson (Join-Path $Root 'data/queue.json')
    if($queue -and $queue.PSObject.Properties['SyncJobs'] -and @($queue.SyncJobs | Where-Object {$_.SubjectId -eq $SubjectId -and $_.Status -in @('Pending','Discovering','Downloading','Cancelling')}).Count){return $true}
    return ($queue -and @($queue.Items | Where-Object {$_.SubjectId -eq $SubjectId -and $_.Status -in @('Pending','Running')}).Count -gt 0)
}
function Set-CorpusSubject {
    param([string]$Root,[string]$Name,[string]$Id='')
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Enter a subject name.' }
    $configLock=Enter-CorpusConfigLock $Root
    try {
    $c=Get-CorpusConfig $Root
    if (-not $Id) {
        $existing=@($c.subjects | Where-Object { $_.name -eq $Name.Trim() })
        if($existing.Count) { return $existing[0].id }
        $Id=[guid]::NewGuid().ToString('N')
        $c.subjects=@($c.subjects)+[pscustomobject]@{id=$Id;name=$Name.Trim();channels=@()}
    } else {
        if(Test-CorpusSubjectQueued $Root $Id){throw 'This subject has pending or active queue items. Finish or remove them before renaming.'}
        $s=@($c.subjects | Where-Object id -eq $Id)
        if(-not $s.Count) { throw 'Subject no longer exists.' }; $s[0].name=$Name.Trim()
    }
    Write-CorpusJson (Join-Path $Root 'config.json') $c
    return $Id
    } finally {$configLock.Dispose()}
}
function Remove-CorpusSubject {
    param([string]$Root,[string]$Id)
    try{$writer=[IO.File]::Open((Join-Path $Root 'data/corpus.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch [IO.IOException]{throw 'Pause capture work and wait for the active item to finish before removing a subject.'}
    $lock=$null
    try {
        $lock=Enter-CorpusConfigLock $Root
        if(Test-CorpusSubjectQueued $Root $Id){throw 'This subject has pending or active queue items. Finish or remove them before removing the subject.'}
        $config=Get-CorpusConfig $Root
        $subject=@($config.subjects | Where-Object id -eq $Id)
        if(-not $subject.Count){throw 'Subject no longer exists.'}
        $subject[0] | Add-Member NoteProperty archivedAt ([datetime]::UtcNow.ToString('o')) -Force
        $config.archivedSubjects=@($config.archivedSubjects)+$subject[0]
        $config.subjects=@($config.subjects | Where-Object id -ne $Id)
        Write-CorpusJson (Join-Path $Root 'config.json') $config
    } finally {if($lock){$lock.Dispose()};$writer.Dispose()}
}
function Get-CorpusArchivedVideoSubject {
    param([string]$Root,$Video)
    if(-not $Video -or -not $Video.SubjectId -or -not (Test-Path (Join-Path $Root config.json))){return $null}
    return ((Get-CorpusConfig $Root).archivedSubjects | Where-Object id -eq $Video.SubjectId | Select-Object -First 1)
}
function Set-CorpusChannelAssociation {
    param([string]$Root,[string]$SubjectId,[string]$Url,[switch]$Remove)
    $url=Assert-CorpusYouTubeUrl $Url
    $configLock=Enter-CorpusConfigLock $Root
    try {
    $c=Get-CorpusConfig $Root
    $s=@($c.subjects | Where-Object id -eq $SubjectId)
    if(-not $s.Count) { throw 'Select a subject first.' }
    if($Remove) { $s[0].channels=@($s[0].channels | Where-Object url -ne $url) }
    else {
        foreach($other in $c.subjects) { if($other.id -ne $SubjectId -and @($other.channels | Where-Object url -eq $url).Count) { throw 'This URL is already assigned to another subject. Remove that association first.' } }
        if(-not @($s[0].channels | Where-Object url -eq $url).Count) { $s[0].channels=@($s[0].channels)+[pscustomobject]@{url=$url} }
    }
    Write-CorpusJson (Join-Path $Root 'config.json') $c
    } finally {$configLock.Dispose()}
}
function New-CorpusContext {
    param([string]$Root,$Shared=$null)
    foreach($dir in @('data/subjects','data/raw','data/normalized/videos','data/normalized/channels','data/normalized/runs','output','logs')) { [IO.Directory]::CreateDirectory((Join-Path $Root $dir)) | Out-Null }
    $id=[guid]::NewGuid().ToString('N')
    return [pscustomobject]@{Root=$Root; RunId=$id; Shared=$Shared; LogPath=(Join-Path $Root "logs/$id.jsonl")}
}
function Get-CorpusVideos {
    param([string]$Root)
    $config=Get-CorpusConfig $Root
    foreach($f in Get-ChildItem (Join-Path $Root 'data/normalized/videos') -Filter '*.json' -ErrorAction SilentlyContinue) {
        $v=Read-CorpusJson $f.FullName
        $s=@((@($config.subjects)+@($config.archivedSubjects)) | Where-Object id -eq $v.SubjectId)
        if($s.Count) { $v.SubjectName=$s[0].name }
        $v
    }
}
function Save-CorpusVideo {
    param($Context,$Video)
    if($Video.VideoId -notmatch '^[A-Za-z0-9_-]{11}$') { throw 'Invalid YouTube video ID.' }
    Write-CorpusJson (Join-Path $Context.Root "data/normalized/videos/$($Video.VideoId).json") $Video
}
function Get-CorpusTranscript {
    param([string]$Root,$Video)
    if($Video.TranscriptPath) { @(Read-CorpusJson (Join-Path $Root $Video.TranscriptPath) @()) }
}
function Find-CorpusTranscript {
    param($Context,[string]$Text='', [string]$Subject='', [string]$Channel='', [string]$Video='', [string]$From='', [string]$To='')
    $videos=@(Get-CorpusVideos $Context.Root); $n=0
    foreach($v in $videos) {
        Test-CorpusCancellation $Context; $n++; Set-CorpusProgress $Context 'Searching' $v.VideoTitle $n $videos.Count
        if($Subject -and $v.SubjectId -ne $Subject -and $v.SubjectName -ne $Subject) { continue }
        if($Channel -and $v.ChannelId -ne $Channel -and $v.ChannelName -notlike "*$Channel*") { continue }
        if($Video -and $v.VideoId -ne $Video -and $v.VideoTitle -notlike "*$Video*") { continue }
        if(($From -and (-not $v.PublishedDate -or [datetime]$v.PublishedDate -lt [datetime]$From)) -or ($To -and (-not $v.PublishedDate -or [datetime]$v.PublishedDate -ge ([datetime]$To).Date.AddDays(1)))) { continue }
        $rows=@(Get-CorpusTranscript $Context.Root $v)
        for($i=0;$i -lt $rows.Count;$i++) {
            if($rows[$i].TranscriptText.IndexOf($Text,[StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $r=$rows[$i] | Select-Object *; $r.SubjectName=$v.SubjectName
            $r | Add-Member NoteProperty Context (($rows[[Math]::Max(0,$i-1)..[Math]::Min($rows.Count-1,$i+1)].TranscriptText) -join ' ')
            $r
        }
    }
}
Export-ModuleMember -Function *-Corpus*
