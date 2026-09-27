$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations','Queue')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Describe 'Archived subject identity and corpus preservation' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        $meta=Read-CorpusJson (Join-Path $PSScriptRoot fixtures/video.info.json)
        $video=ConvertTo-CorpusVideo $meta mo Mo
        $video.TranscriptPath="data/normalized/transcripts/$($video.VideoId).json";$video.TranscriptAvailable=$true
        $rows=@(ConvertFrom-CorpusVtt (Join-Path $PSScriptRoot fixtures/rolling.en.vtt) $video Manual)
        Write-CorpusJson (Join-Path $root $video.TranscriptPath) $rows;Save-CorpusVideo $ctx $video
    }
    It 'archives configuration only, preserving every captured file and the last subject name' {
        $null=Set-CorpusSubject $root 'Renamed Mo' mo
        $path=Join-Path $root "data/normalized/videos/$($video.VideoId).json"
        $before=[IO.File]::ReadAllText($path);$transcript=[IO.File]::ReadAllText((Join-Path $root $video.TranscriptPath))
        Remove-CorpusSubject $root mo
        (Get-CorpusConfig $root).subjects.Count | Should Be 0
        (Get-CorpusConfig $root).archivedSubjects[0].id | Should Be mo
        [IO.File]::ReadAllText($path) | Should Be $before
        [IO.File]::ReadAllText((Join-Path $root $video.TranscriptPath)) | Should Be $transcript
        @(Get-CorpusVideos $root)[0].SubjectName | Should Be 'Renamed Mo'
        @(Find-CorpusTranscript $ctx -Subject mo -Text 'Hello').Count | Should BeGreaterThan 0
    }
    It 'allocates a fresh ID for the same name and permits reassociating channels for future syncs' {
        Remove-CorpusSubject $root mo
        $newId=Set-CorpusSubject $root Mo
        $newId | Should Not Be mo
        Set-CorpusChannelAssociation $root $newId 'https://www.youtube.com/@atmoio'
        (Get-CorpusConfig $root).subjects[0].id | Should Be $newId
        @(Get-CorpusVideos $root)[0].SubjectId | Should Be mo
        {Set-CorpusSubject $root Changed mo} | Should Throw
        {Set-CorpusChannelAssociation $root mo 'https://youtube.com/@other'} | Should Throw
    }
    It 'preserves archived ownership on a cached import into a new subject' {
        Remove-CorpusSubject $root mo;$newId=Set-CorpusSubject $root Mo
        $result=Import-CorpusVideo $ctx $video.VideoUrl $newId Mo
        $result.SubjectId | Should Be mo
        $result.TranscriptAvailable | Should Be $true
        $null=Add-CorpusQueueUrls $root $video.VideoUrl $newId
        (Get-CorpusQueue $root).Items[0].SubjectId | Should Be mo
    }
    It 'preserves archived ownership when a channel listing identifies an old video as members-only' {
        Remove-CorpusSubject $root mo;$newId=Set-CorpusSubject $root New
        $result=Save-CorpusMembersOnlyVideo $ctx $video.VideoId $newId New
        $result.SubjectId | Should Be mo;$result.TranscriptAvailable | Should Be $true
    }
    It 'blocks removal for pending and running work, including paused queues' {
        $null=Add-CorpusQueueUrls $root $video.VideoUrl mo
        {Remove-CorpusSubject $root mo} | Should Throw
        $q=Get-CorpusQueue $root;$q.Items[0].Status='Running';Write-CorpusJson (Join-Path $root data/queue.json) $q
        {Remove-CorpusSubject $root mo} | Should Throw
        (Get-CorpusConfig $root).subjects.Count | Should Be 1
    }
    It 'excludes an active capture writer from racing subject removal' {
        $writer=[IO.File]::Open((Join-Path $root data/corpus.lock),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{{Remove-CorpusSubject $root mo} | Should Throw;(Get-CorpusConfig $root).subjects.Count | Should Be 1}finally{$writer.Dispose()}
        Remove-CorpusSubject $root mo
        (Get-CorpusConfig $root).subjects.Count | Should Be 0
    }
    It 'does not revive archived subjects when retrying old failed queue history' {
        $null=Add-CorpusQueueUrls $root $video.VideoUrl mo
        $q=Get-CorpusQueue $root;$q.Items[0].Status='Failed';Write-CorpusJson (Join-Path $root data/queue.json) $q
        Remove-CorpusSubject $root mo
        {Update-CorpusQueue $root Retry $q.Items[0].Id} | Should Throw
        {Add-CorpusQueueUrls $root 'https://youtu.be/newDEF12_-3' mo} | Should Throw
    }
    It 'keeps archive identity separate from newly captured video assignments' {
        Remove-CorpusSubject $root mo;$newId=Set-CorpusSubject $root Mo
        $newVideo=ConvertTo-CorpusVideo ([pscustomobject]@{id='newDEF12_-3';title='New capture'}) $newId Mo
        Save-CorpusVideo $ctx $newVideo
        @(Get-CorpusVideos $root | Where-Object SubjectId -eq mo).Count | Should Be 1
        @(Get-CorpusVideos $root | Where-Object SubjectId -eq $newId).Count | Should Be 1
    }
}
