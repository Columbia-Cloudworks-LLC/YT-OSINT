$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$fixture=Get-Content (Join-Path $PSScriptRoot 'fixtures/video.info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$vtt=Join-Path $PSScriptRoot 'fixtures/rolling.en.vtt'
Describe 'Configuration and stable identities' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $root -ItemType Directory | Out-Null
        Copy-Item (Join-Path $project 'config.json') (Join-Path $root 'config.json')
        $ctx=New-CorpusContext $root
    }
    It 'loads seeded subject and two explicitly associated channels' {
        $c=Get-CorpusConfig $root;$c.subjects.Count | Should Be 1;$c.subjects[0].channels.Count | Should Be 2
    }
    It 'creates subjects idempotently and renames without changing identity' {
        $id=Set-CorpusSubject $root 'Research';(Set-CorpusSubject $root 'Research') | Should Be $id
        $null=Set-CorpusSubject $root 'Renamed' $id
        (Get-CorpusConfig $root).subjects[1].id | Should Be $id
    }
    It 'deduplicates associations and removes them without deleting corpus files' {
        Set-CorpusChannelAssociation $root mo 'https://www.youtube.com/@atmoio'
        (Get-CorpusConfig $root).subjects[0].channels.Count | Should Be 2
        $v=ConvertTo-CorpusVideo $fixture mo Mo;Save-CorpusVideo $ctx $v
        Set-CorpusChannelAssociation $root mo 'https://www.youtube.com/@atmoio' -Remove
        @(Get-CorpusVideos $root).Count | Should Be 1
        (Get-CorpusConfig $root).subjects[0].channels.Count | Should Be 1
    }
    It 'rejects conflicting ownership and invalid source hosts' {
        $id=Set-CorpusSubject $root Other
        {Set-CorpusChannelAssociation $root $id 'https://www.youtube.com/@atmoio'} | Should Throw
        {Assert-CorpusYouTubeUrl 'https://youtube.com.evil.test/a'} | Should Throw
        {Assert-CorpusYouTubeUrl 'file:///C:/Windows'} | Should Throw
    }
    It 'rejects duplicate subject IDs' {
        Write-CorpusJson (Join-Path $root config.json) @{subjects=@(@{id='a';name='A';channels=@()},@{id='a';name='B';channels=@()})}
        {Get-CorpusConfig $root} | Should Throw
    }
    It 'produces deterministic collision-resistant IDs' {
        (Get-CorpusId 'a|1') | Should Be (Get-CorpusId 'a|1')
        (Get-CorpusId 'a|1') | Should Not Be (Get-CorpusId 'a|2')
    }
}
Describe 'Transcript normalization' {
    BeforeEach {$video=ConvertTo-CorpusVideo $fixture mo Mo}
    It 'calculates milliseconds including hours and fractional seconds' {
        (ConvertFrom-CorpusTimestamp '01:02:03.456') | Should Be 3723456
        (ConvertFrom-CorpusTimestamp '02:03.456') | Should Be 123456
        {ConvertFrom-CorpusTimestamp '00:99:00.000'} | Should Throw
    }
    It 'floors URL seconds and uses the canonical watch URL' {
        (Get-CorpusTimestampUrl $video.VideoId 2999) | Should Be 'https://www.youtube.com/watch?v=abcDEF12_-3&t=2s'
    }
    It 'deduplicates rolling auto captions but retains later intentional repetition' {
        $rows=@(ConvertFrom-CorpusVtt $vtt $video Automatic)
        $rows.Count | Should Be 5
        $rows[0].TranscriptText | Should Be 'Hello & welcome'
        $rows[1].TranscriptText | Should Be 'to café'
        $rows[2].TranscriptText | Should Be 'today'
        $rows[3].TranscriptText | Should Be 'today today'
        $rows[4].TranscriptText | Should Be 'Unicode 世界'
        $rows[0].TimestampDisplay | Should Be '00:00:01.000'
    }
    It 'does not remove repeated manual dialogue' {
        @(ConvertFrom-CorpusVtt $vtt $video Manual).Count | Should Be 6
    }
    It 'uses stable segment IDs across capture times' {
        $a=@(ConvertFrom-CorpusVtt $vtt $video Automatic en '2025-01-01')
        $b=@(ConvertFrom-CorpusVtt $vtt $video Automatic en '2025-01-02')
        ($a.SegmentId -join ',') | Should Be ($b.SegmentId -join ',')
    }
    It 'rejects malformed subtitles without silently losing content' {
        $bad=Join-Path $TestDrive bad.vtt;[IO.File]::WriteAllText($bad,"WEBVTT`n`n00:99:00.000 --> 00:00:01.000`ntext")
        {ConvertFrom-CorpusVtt $bad $video} | Should Throw
    }
    It 'normalizes metadata with nullable missing fields and proper dates' {
        $video.PublishedDate | Should Be '2025-01-02';$video.Duration | Should Be 92.4
        (ConvertTo-CorpusVideo ([pscustomobject]@{id='abcDEF12_-3'})).ViewCount | Should Be $null
    }
    It 'prefers manual English then automatic English' {
        (Select-CorpusSubtitle $fixture).Source | Should Be Manual
        $m=$fixture | ConvertTo-Json -Depth 20 | ConvertFrom-Json;$m.subtitles=[pscustomobject]@{}
        (Select-CorpusSubtitle $m).Source | Should Be Automatic
    }
}
Describe 'Persistence, repeat imports and failures' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $root -ItemType Directory | Out-Null
        Copy-Item (Join-Path $project config.json) (Join-Path $root config.json)
        $ctx=New-CorpusContext $root;$video=ConvertTo-CorpusVideo $fixture mo Mo
    }
    It 'upserts videos without duplicate rows and preserves metadata artifacts by content' {
        Save-CorpusVideo $ctx $video;Save-CorpusVideo $ctx $video
        @(Get-CorpusVideos $root).Count | Should Be 1
        $path=Save-CorpusRawArtifact (Join-Path $root raw) 'video.info.json' '{"title":"one"}'
        (Save-CorpusRawArtifact (Join-Path $root raw) 'video.info.json' '{"title":"one"}') | Should Be $path
        $other=Save-CorpusRawArtifact (Join-Path $root raw) 'video.info.json' '{"title":"two"}'
        $other | Should Not Be $path
        [IO.File]::ReadAllText($path) | Should Be '{"title":"one"}'
    }
    It 'preserves a valid transcript when a later capture fails' {
        $video.TranscriptAvailable=$true;$video.TranscriptPath='data/normalized/example.json';Save-CorpusVideo $ctx $video
        Save-CorpusFailure $ctx $video.VideoId 'Private video' mo Mo $video.ChannelId
        $loaded=@(Get-CorpusVideos $root)[0];$loaded.LastSyncStatus | Should Be Failed;$loaded.TranscriptAvailable | Should Be $true
    }
    It 'provides neighboring search context and filters' {
        $rows=@(ConvertFrom-CorpusVtt $vtt $video Automatic);$video.TranscriptPath='data/normalized/transcript.json';$video.TranscriptAvailable=$true
        Write-CorpusJson (Join-Path $root $video.TranscriptPath) $rows;Save-CorpusVideo $ctx $video
        $found=@(Find-CorpusTranscript $ctx 'café' -Subject mo -From '2025-01-01' -To '2025-01-03')
        $found.Count | Should Be 1;$found[0].Context | Should Match 'Hello & welcome to café today'
        @(Find-CorpusTranscript $ctx 'café' -Subject absent).Count | Should Be 0
    }
    It 'observes cancellation without corrupting committed data' {
        Save-CorpusVideo $ctx $video;$ctx.Shared=@{Cancel=$true}
        {Test-CorpusCancellation $ctx} | Should Throw
        @(Get-CorpusVideos $root).Count | Should Be 1
    }
}
Describe 'Native process wrapper' {
    BeforeEach {$root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root}
    It 'quotes spaces, embedded quotes, empty arguments and trailing slashes' {
        [YouTubeCorpus.ProcessRunner]::Quote('C:\with space\') | Should Be '"C:\with space\\"'
        [YouTubeCorpus.ProcessRunner]::Quote('a"b') | Should Be '"a\"b"'
        [YouTubeCorpus.ProcessRunner]::Quote('') | Should Be '""'
    }
    It 'captures stdout, stderr and exit status without treating warnings as failure' {
        $r=Invoke-CorpusProcess $ctx (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @('-NoProfile','-Command','[Console]::Out.WriteLine("hello");[Console]::Error.WriteLine("warning");exit 0')
        $r.ExitCode | Should Be 0;$r.StdOut | Should Match hello;$r.StdErr | Should Match warning
    }
}
Describe 'Excel fixture export' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $root -ItemType Directory | Out-Null
        Copy-Item (Join-Path $project config.json) (Join-Path $root config.json)
        $ctx=New-CorpusContext $root;$video=ConvertTo-CorpusVideo $fixture mo Mo
        $video.TranscriptPath='data/normalized/transcript.json';$video.TranscriptAvailable=$true
        Write-CorpusJson (Join-Path $root $video.TranscriptPath) @(ConvertFrom-CorpusVtt $vtt $video Automatic)
        Save-CorpusVideo $ctx $video
    }
    It 'creates all sheets, real hyperlinks, typed dates, filters and safe text' {
        $path=Export-CorpusWorkbook $ctx
        $pkg=Open-ExcelPackage $path
        try {
            $pkg.Workbook.Worksheets.Count | Should Be 4
            $sheet=$pkg.Workbook.Worksheets['Transcript'];$sheet.Dimension.End.Row | Should Be 6
            $sheet.Cells[2,9].Hyperlink.AbsoluteUri | Should Be 'https://www.youtube.com/watch?v=abcDEF12_-3&t=1s'
            $sheet.Cells[2,3].Value.GetType().Name | Should Be Double
            $sheet.Tables.Count | Should Be 1
            $pkg.Workbook.Worksheets['Videos'].Cells[2,10].Formula | Should BeNullOrEmpty
        }finally{$pkg.Dispose()}
        $null=Export-CorpusWorkbook $ctx
        @(Import-Excel $path -WorksheetName Videos).Count | Should Be 1
        @(Import-Excel $path -WorksheetName Transcript).Count | Should Be 5
    }
    It 'leaves the prior workbook intact when its destination is locked' {
        $path=Export-CorpusWorkbook $ctx;$before=([Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($path))))
        $handle=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try{{Export-CorpusWorkbook $ctx} | Should Throw}finally{$handle.Dispose()}
        ([Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($path)))) | Should Be $before
    }
}
Describe 'Fixture acquisition workflow through the YouTube adapter' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $root -ItemType Directory | Out-Null
        Copy-Item (Join-Path $project config.json) (Join-Path $root config.json)
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/video.info.json') (Join-Path $root fixture.info.json)
        Copy-Item $vtt (Join-Path $root fixture.vtt)
        $ctx=New-CorpusContext $root
        Mock Get-CorpusMetadata -ModuleName Corpus.YouTube {
            param($Context,$Url)
            $raw=[IO.File]::ReadAllText((Join-Path $Context.Root fixture.info.json))
            [pscustomobject]@{Metadata=($raw | ConvertFrom-Json);Raw=$raw}
        }
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {
            param($Context,$Arguments)
            $index=[Array]::IndexOf($Arguments,'--output')
            $dir=Split-Path $Arguments[$index+1] -Parent
            Copy-Item (Join-Path $Context.Root fixture.vtt) (Join-Path $dir 'abcDEF12_-3.en.vtt')
            [pscustomobject]@{StdOut='';StdErr='';ExitCode=0}
        }
    }
    It 'reimports unchanged metadata and captions without duplicating canonical videos or segments' {
        $a=Import-CorpusVideo $ctx 'https://www.youtube.com/watch?v=abcDEF12_-3' mo Mo
        $ctx2=New-CorpusContext $root
        $b=Import-CorpusVideo $ctx2 'https://www.youtube.com/watch?v=abcDEF12_-3' mo Mo
        @(Get-CorpusVideos $root).Count | Should Be 1
        $rows=@(Get-CorpusTranscript $root $b)
        $rows.Count | Should Be 6
        @($rows.SegmentId | Sort-Object -Unique).Count | Should Be 6
        @(Get-ChildItem (Join-Path $root data/raw) -Recurse -Filter '*.vtt').Count | Should Be 1
        @(Get-ChildItem (Join-Path $root data/raw) -Recurse -Filter '*.info.json').Count | Should Be 1
        @(Get-ChildItem (Join-Path $root data/raw) -Recurse -Filter '*.json' | Where-Object DirectoryName -match observations).Count | Should Be 1
        $a.LastSyncStatus | Should Be Success;$b.LastSyncStatus | Should Be Success
    }
    It 'keeps a previous transcript when the next subtitle download fails' {
        $first=Import-CorpusVideo $ctx 'https://www.youtube.com/watch?v=abcDEF12_-3' mo Mo
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube { [pscustomobject]@{StdOut='';StdErr='rate limited';ExitCode=1} }
        $second=Import-CorpusVideo (New-CorpusContext $root) 'https://www.youtube.com/watch?v=abcDEF12_-3' mo Mo -RefreshTranscript
        $second.LastSyncStatus | Should Be Failed
        $second.TranscriptPath | Should Be $first.TranscriptPath
        @(Get-CorpusTranscript $root $second).Count | Should Be 6
    }
    It 'continues to the second video when the first video fails' {
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {
            [pscustomobject]@{ExitCode=0;StdErr='';StdOut='{"id":"UC1234567890123456789012","channel_id":"UC1234567890123456789012","channel":"Fixture","entries":[{"id":"badDEF12_-3"},{"id":"abcDEF12_-3"}]}'}
        }
        Mock Import-CorpusVideo -ModuleName Corpus.YouTube {
            param($Context,$Url)
            if($Url -match 'badDEF'){throw 'Simulated private video'}
            $meta=[IO.File]::ReadAllText((Join-Path $Context.Root fixture.info.json)) | ConvertFrom-Json
            $v=ConvertTo-CorpusVideo $meta mo Mo;Save-CorpusVideo $Context $v;return $v
        }
        $run=[pscustomobject]@{VideosDiscovered=0;Failures=0}
        Sync-CorpusChannel $ctx 'https://www.youtube.com/@atmoio' mo Mo $run
        $run.Failures | Should Be 1
        @(Get-CorpusVideos $root).Count | Should Be 2
        (Read-CorpusJson (Join-Path $root data/normalized/videos/badDEF12_-3.json)).LastSyncStatus | Should Be Failed
        Test-Path (Join-Path $root data/normalized/videos/abcDEF12_-3.json) | Should Be $true
    }
}
Describe 'Run accounting and cancellation' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $root -ItemType Directory | Out-Null
        Copy-Item (Join-Path $project config.json) (Join-Path $root config.json)
        $ctx=New-CorpusContext $root
        Mock Invoke-CorpusProcess -ModuleName Corpus.Operations { [pscustomobject]@{ExitCode=0;StdOut='fixture 1.0';StdErr=''} }
    }
    It 'records Cancelled and stops scheduling further channels' {
        $shared=[hashtable]::Synchronized(@{Cancel=$true;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new();Progress=$null})
        {Invoke-CorpusOperation $root SyncAll @{} $shared} | Should Throw
        $files=@(Get-ChildItem (Join-Path $root data/normalized/runs) -Filter '*.json')
        $files.Count | Should Be 1
        (Read-CorpusJson $files[0].FullName).FinalState | Should Be Cancelled
    }
    It 'records a build run and includes its finalized summary in the workbook' {
        $run=Invoke-CorpusOperation $root Build
        $run.FinalState | Should Be Success
        $records=@(Import-Excel (Join-Path $root output/YouTubeCorpus.xlsx) -WorksheetName Runs)
        $records.Count | Should Be 1;$records[0].FinalState | Should Be Success
    }
}
