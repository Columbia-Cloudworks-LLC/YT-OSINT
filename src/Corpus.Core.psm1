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
    if (Test-Path -LiteralPath $Path) { $data=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json; return $data }
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
    $config=Read-CorpusJson (Join-Path $Root 'config.json')
    if (-not $config -or -not $config.PSObject.Properties['subjects']) { throw 'config.json must contain a subjects array.' }
    $ids=@{}
    foreach($s in $config.subjects) {
        if (-not $s.id -or -not $s.name -or $ids.ContainsKey($s.id)) { throw 'Subjects require unique nonempty IDs and display names.' }
        $ids[$s.id]=$true
        foreach($c in $s.channels) { $null=Assert-CorpusYouTubeUrl $c.url }
    }
    return $config
}
function Set-CorpusSubject {
    param([string]$Root,[string]$Name,[string]$Id='')
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Enter a subject name.' }
    $c=Get-CorpusConfig $Root
    if (-not $Id) {
        $existing=@($c.subjects | Where-Object { $_.name -eq $Name.Trim() })
        if($existing.Count) { return $existing[0].id }
        $Id=[guid]::NewGuid().ToString('N')
        $c.subjects=@($c.subjects)+[pscustomobject]@{id=$Id;name=$Name.Trim();channels=@()}
    } else {
        $s=@($c.subjects | Where-Object id -eq $Id)
        if(-not $s.Count) { throw 'Subject no longer exists.' }; $s[0].name=$Name.Trim()
    }
    Write-CorpusJson (Join-Path $Root 'config.json') $c
    return $Id
}
function Set-CorpusChannelAssociation {
    param([string]$Root,[string]$SubjectId,[string]$Url,[switch]$Remove)
    $url=Assert-CorpusYouTubeUrl $Url
    $c=Get-CorpusConfig $Root
    $s=@($c.subjects | Where-Object id -eq $SubjectId)
    if(-not $s.Count) { throw 'Select a subject first.' }
    if($Remove) { $s[0].channels=@($s[0].channels | Where-Object url -ne $url) }
    else {
        foreach($other in $c.subjects) { if($other.id -ne $SubjectId -and @($other.channels | Where-Object url -eq $url).Count) { throw 'This URL is already assigned to another subject. Remove that association first.' } }
        if(-not @($s[0].channels | Where-Object url -eq $url).Count) { $s[0].channels=@($s[0].channels)+[pscustomobject]@{url=$url} }
    }
    Write-CorpusJson (Join-Path $Root 'config.json') $c
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
        $s=@($config.subjects | Where-Object id -eq $v.SubjectId)
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
