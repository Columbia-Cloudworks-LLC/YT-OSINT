$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Describe 'Members-only identification' {
    It 'recognizes explicit membership messages but not ordinary failures or titles' {
        (Test-CorpusMembersOnlyMessage 'ERROR: Join this channel to get access to members-only content like this video, and other exclusive perks.') | Should Be $true
        (Test-CorpusMembersOnlyMessage "ERROR: This video is available to this channel's members on level: Supporter") | Should Be $true
        (Test-CorpusMembersOnlyMessage 'ERROR: Private video') | Should Be $false
        (Test-CorpusMembersOnlyMessage 'ERROR: Video unavailable') | Should Be $false
        (Test-CorpusMembersOnlyMessage 'ERROR: HTTP Error 429: Too Many Requests') | Should Be $false
        (Test-CorpusMembersOnlyMessage 'ERROR: members-only review: This video is not available') | Should Be $false
    }
    It 'converts a metadata membership response to a skip result' {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {[pscustomobject]@{ExitCode=1;StdOut='';StdErr='ERROR: Join this channel to get access to members-only content like this video'}}
        $capture=Get-CorpusMetadata $ctx 'https://youtu.be/abcDEF12_-3'
        $capture.MembersOnly | Should Be $true
    }
    It 'logs a native membership response as an informational skip rather than an error' {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $result=Invoke-CorpusProcess $ctx (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @('-NoProfile','-Command','[Console]::Error.WriteLine("ERROR: Join this channel to get access to members-only content like this video");exit 1') -AllowMembersOnly
        $result.MembersOnly | Should Be $true
        $events=@(Get-Content $ctx.LogPath | ForEach-Object {$_ | ConvertFrom-Json})
        @($events | Where-Object Severity -eq Error).Count | Should Be 0
        $events[-1].Message | Should Match skipping
    }
}
Describe 'Members-only skip persistence and accounting' {
    BeforeEach {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Copy-Item (Join-Path $project config.json) (Join-Path $ctx.Root config.json)
        $run=[pscustomobject]@{VideosDiscovered=0;VideosAdded=0;VideosAlreadyKnown=0;Failures=0;MembersOnlySkipped=0}
    }
    It 'skips entries identified by the listing without requesting those videos' {
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {[pscustomobject]@{ExitCode=0;StdErr='';StdOut='{"id":"UC1234567890123456789012","channel":"Fixture","entries":[{"id":"abcDEF12_-3","title":"Members video","availability":"subscriber_only"}]}'} }
        Mock Import-CorpusVideo -ModuleName Corpus.YouTube {throw 'Should not request the member video'}
        Sync-CorpusChannel $ctx 'https://www.youtube.com/@atmoio' mo Mo $run
        $run.MembersOnlySkipped | Should Be 1
        $run.Failures | Should Be 0
        Assert-MockCalled Import-CorpusVideo -ModuleName Corpus.YouTube -Times 0 -Exactly -Scope It
        $v=Read-CorpusJson (Join-Path $ctx.Root data/normalized/videos/abcDEF12_-3.json)
        $v.LastSyncStatus | Should Be SkippedMembersOnly
        $v.VideoTitle | Should Be 'Members video'
        $v.ChannelId | Should Be UC1234567890123456789012
        (Read-CorpusJson (Join-Path $ctx.Root data/normalized/channels/UC1234567890123456789012.json)).Status | Should Be Success
    }
    It 'preserves a previously captured transcript when marking a video members-only' {
        $v=ConvertTo-CorpusVideo ([pscustomobject]@{id='abcDEF12_-3'}) mo Mo
        $v.TranscriptAvailable=$true;$v.TranscriptPath='data/normalized/transcripts/old.json';Save-CorpusVideo $ctx $v
        $saved=Save-CorpusMembersOnlyVideo $ctx $v.VideoId mo Mo $run
        $saved.TranscriptAvailable | Should Be $true
        $saved.TranscriptPath | Should Be $v.TranscriptPath
        $saved.LastError | Should BeNullOrEmpty
        $run.Failures | Should Be 0
    }
    It 'reuses cached membership status without a network request' {
        $null=Save-CorpusMembersOnlyVideo $ctx 'abcDEF12_-3' mo Mo
        Mock Get-CorpusMetadata -ModuleName Corpus.YouTube {throw 'Should not request a known member video'}
        $v=Corpus.YouTube\Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3' mo Mo $run
        $v.LastSyncStatus | Should Be SkippedMembersOnly
        $run.MembersOnlySkipped | Should Be 1
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 0 -Exactly -Scope It
    }
    It 'rechecks a known members-only video when the latest listing reports public access' {
        $null=Save-CorpusMembersOnlyVideo $ctx 'abcDEF12_-3' mo Mo
        Mock Get-CorpusMetadata -ModuleName Corpus.YouTube {throw 'Metadata was requested'}
        {Corpus.YouTube\Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3' mo Mo $run -ListingEntry ([pscustomobject]@{availability='public'})} | Should Throw
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 1 -Exactly -Scope It
    }
    It 'allows an explicit refresh of cached membership status' {
        $null=Save-CorpusMembersOnlyVideo $ctx 'abcDEF12_-3' mo Mo
        Mock Get-CorpusMetadata -ModuleName Corpus.YouTube {throw 'Metadata was requested'}
        {Corpus.YouTube\Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3' mo Mo $run -RefreshTranscript} | Should Throw
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 1 -Exactly -Scope It
    }
    It 'still records ordinary video failures while continuing past members-only entries' {
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {[pscustomobject]@{ExitCode=0;StdErr='';StdOut='{"id":"UC1234567890123456789012","entries":[{"id":"abcDEF12_-3","availability":"subscriber_only"},{"id":"badDEF12_-3"}]}'} }
        Mock Import-CorpusVideo -ModuleName Corpus.YouTube {throw 'Private video'}
        Sync-CorpusChannel $ctx 'https://www.youtube.com/@atmoio' mo Mo $run
        $run.MembersOnlySkipped | Should Be 1
        $run.Failures | Should Be 1
        (Read-CorpusJson (Join-Path $ctx.Root data/normalized/videos/badDEF12_-3.json)).LastSyncStatus | Should Be Failed
    }
}
