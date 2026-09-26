Set-StrictMode -Version 2
function ConvertFrom-CorpusTimestamp {
    param([string]$Value)
    if($Value -notmatch '^(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{3})$') { throw "Invalid subtitle timestamp: $Value" }
    if([int]$Matches[2] -gt 59 -or [int]$Matches[3] -gt 59) { throw "Invalid subtitle timestamp: $Value" }
    return ([long]$Matches[1]*3600000 + [long]$Matches[2]*60000 + [long]$Matches[3]*1000 + [long]$Matches[4])
}
function Get-CorpusTimestampUrl {
    param([string]$VideoId,[long]$Milliseconds)
    return "https://www.youtube.com/watch?v=$VideoId&t=$([long][Math]::Floor($Milliseconds/1000.0))s"
}
function ConvertFrom-CorpusVtt {
    param([string]$Path,$Video,[string]$Source='Manual',[string]$Language='en',[string]$CapturedAt=([datetime]::UtcNow.ToString('o')),$Context=$null)
    $content=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8).Replace("`r",'')
    if($content -notmatch '^\uFEFF?WEBVTT') { throw "Malformed VTT: missing WEBVTT header in $Path" }
    $previous=@(); $previousEnd=-1L; $seen=@{}; $cueCount=0
    foreach($block in ($content -split '\n\s*\n')) {
        if($Context) { Test-CorpusCancellation $Context }
        if($block -match '^\s*(NOTE|STYLE|REGION)\b') { continue }
        $lines=$block -split '\n'; $timeIndex=-1
        for($i=0;$i -lt $lines.Count;$i++) { if($lines[$i] -match '^\s*((?:\d+:)?\d{2}:\d{2}[.,]\d{3})\s+-->\s+((?:\d+:)?\d{2}:\d{2}[.,]\d{3})') { $start=ConvertFrom-CorpusTimestamp $Matches[1]; $end=ConvertFrom-CorpusTimestamp $Matches[2]; $timeIndex=$i; break } }
        if($timeIndex -lt 0) { if($block -match '-->') { throw 'Malformed VTT timing line.' }; continue }
        $cueCount++
        if($end -lt $start) { throw 'Subtitle cue ends before it starts.' }
        if($timeIndex+1 -ge $lines.Count) { continue }
        $text=($lines[($timeIndex+1)..($lines.Count-1)] -join ' ')
        $text=[Net.WebUtility]::HtmlDecode(($text -replace '<[^>]+>',''))
        $text=($text -replace '\s+',' ').Trim(); if(-not $text) { continue }
        $words=@($text -split ' '); $trim=0
        # Only overlapping/touching auto cues are rolled forward. Natural repetitions in later speech survive.
        if($Source -eq 'Automatic' -and $start -le $previousEnd+80) {
            for($k=[Math]::Min($previous.Count,$words.Count);$k -gt 0;$k--) {
                if(($previous[($previous.Count-$k)..($previous.Count-1)] -join ' ') -ceq ($words[0..($k-1)] -join ' ')) { $trim=$k; break }
            }
        }
        $previous=$words; $previousEnd=$end
        if($trim -ge $words.Count) { continue }
        if($trim -gt 0) { $text=$words[$trim..($words.Count-1)] -join ' ' }
        $id=Get-CorpusId "$($Video.VideoId)|$Source|$Language|$start|$end|$text"
        if($seen.ContainsKey($id)) { continue }; $seen[$id]=$true
        $span=[timespan]::FromMilliseconds($start)
        [pscustomobject][ordered]@{
            SegmentId=$id; SubjectId=$Video.SubjectId; SubjectName=$Video.SubjectName; ChannelId=$Video.ChannelId; ChannelName=$Video.ChannelName
            VideoId=$Video.VideoId; VideoTitle=$Video.VideoTitle; PublishedDate=$Video.PublishedDate
            StartMilliseconds=$start; EndMilliseconds=$end; TimestampDisplay=('{0:00}:{1:00}:{2:00}.{3:000}' -f [Math]::Floor($span.TotalHours),$span.Minutes,$span.Seconds,$span.Milliseconds)
            TranscriptText=$text; TranscriptSource=$Source; Language=$Language; VideoUrl=$Video.VideoUrl
            TimestampUrl=(Get-CorpusTimestampUrl $Video.VideoId $start); CapturedAt=$CapturedAt
        }
    }
    if(-not $cueCount) { throw 'VTT contains no timed cues.' }
}
Export-ModuleMember -Function *-Corpus*
