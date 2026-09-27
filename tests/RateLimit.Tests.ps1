$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Describe 'Original English subtitle selection' {
    It 'prefers manual captions and then original automatic captions' {
        $meta=[pscustomobject]@{subtitles=[pscustomobject]@{en=@([pscustomobject]@{ext='vtt';url='https://example.invalid/manual'})};automatic_captions=[pscustomobject]@{'en-orig'=@([pscustomobject]@{ext='vtt';url='https://example.invalid/original?lang=en'});en=@([pscustomobject]@{ext='vtt';url='https://example.invalid/translated?lang=fr&tlang=en'})}}
        (Select-CorpusSubtitle $meta).Source | Should Be Manual
        $meta.subtitles=[pscustomobject]@{}
        (Select-CorpusSubtitle $meta).Language | Should Be 'en-orig'
    }
    It 'filters translated URLs from mixed en entries and disables extraction fallback' {
        $meta=[pscustomobject]@{id='abcDEF12_-3';webpage_url='https://www.youtube.com/watch?v=abcDEF12_-3';automatic_captions=[pscustomobject]@{en=@([pscustomobject]@{ext='vtt';url='https://example.invalid/caption?lang=fr&tlang=en'},[pscustomobject]@{ext='vtt';url='https://example.invalid/caption?lang=en'})}}
        $sub=Select-CorpusSubtitle $meta
        $sub.Track.url | Should Be 'https://example.invalid/caption?lang=en'
        $path=Join-Path $TestDrive request.json
        Save-CorpusCaptionRequest $meta $sub $path
        $copy=Read-CorpusJson $path
        @($copy.automatic_captions.en).Count | Should Be 1
        ($null -eq $copy.PSObject.Properties['webpage_url']) | Should Be $true
        $meta.automatic_captions.en.Count | Should Be 2
        $meta.webpage_url | Should Match youtube
    }
    It 'does not request translation-only English tracks' {
        $meta=[pscustomobject]@{automatic_captions=[pscustomobject]@{en=@([pscustomobject]@{ext='vtt';url='https://example.invalid/caption?lang=fr&tlang=en'})}}
        (Select-CorpusSubtitle $meta) | Should BeNullOrEmpty
    }
}
Describe 'Persistent YouTube request scheduling' {
    BeforeEach {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) ([hashtable]::Synchronized(@{Cancel=$false;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new();Progress=$null}))
        $previousLocalAppData=$env:LOCALAPPDATA
        $env:LOCALAPPDATA=Join-Path $ctx.Root profile
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=0;ResumeAfter='';NextRequestAt='';Halted=$false}
        & (Get-Module Corpus.RateLimit) {$script:TestTime=[datetime]::SpecifyKind([datetime]'2026-09-26T12:00:00',[DateTimeKind]::Utc)}
        Mock Get-CorpusRequestTime -ModuleName Corpus.RateLimit {$script:TestTime}
        Mock Wait-CorpusRequestTick -ModuleName Corpus.RateLimit {$script:TestTime=$script:TestTime.AddSeconds(60)}
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=429;StdOut='';StdErr='ERROR: HTTP Error 429: Too Many Requests'}}
    }
    AfterEach {$env:LOCALAPPDATA=$previousLocalAppData}
    It 'normalizes cooldown timestamps independently of local timezone' {
        (ConvertTo-CorpusRequestTime '2026-09-26T07:02:00-05:00').ToString('HH:mm:ss') | Should Be '12:02:00'
        (ConvertTo-CorpusRequestTime '2026-09-26T12:02:00Z').Kind | Should Be Utc
    }
    It 'backs off 2, 4 and 8 minutes then stops after three retries' {
        {Invoke-CorpusYouTubeProcess $ctx @('fixture') -Kind Subtitle} | Should Throw
        Assert-MockCalled Invoke-CorpusProcess -ModuleName Corpus.RateLimit -Times 4 -Exactly -Scope It
        $state=Read-CorpusRequestState
        $state.Halted | Should Be $true
        $state.RateLimitCount | Should Be 4
        $messages=@(Get-Content $ctx.LogPath | ForEach-Object {($_ | ConvertFrom-Json).Message}) -join ' '
        $messages | Should Match '120 seconds';$messages | Should Match '240 seconds';$messages | Should Match '480 seconds'
    }
    It 'recognizes subtitle 429 warnings even when yt-dlp exits successfully' {
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=0;StdOut='';StdErr='WARNING: HTTP Error 429: Too Many Requests'}}
        {Invoke-CorpusYouTubeProcess $ctx @('fixture') -Kind Subtitle} | Should Throw
        (Read-CorpusRequestState).Halted | Should Be $true
    }
    It 'blocks a new context until the final cooldown expires without sending a request' {
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=4;ResumeAfter='2026-09-26T12:08:00Z';NextRequestAt='';Halted=$true}
        {Invoke-CorpusYouTubeProcess $ctx @('fixture')} | Should Throw
        Assert-MockCalled Invoke-CorpusProcess -ModuleName Corpus.RateLimit -Times 0 -Exactly -Scope It
    }
    It 'honors a saved cooldown with a cancellable countdown and retains it on cancellation' {
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=1;ResumeAfter='2026-09-26T12:02:00Z';NextRequestAt='';Halted=$false}
        & (Get-Module Corpus.RateLimit) {param($shared) $script:TestShared=$shared} $ctx.Shared
        Mock Wait-CorpusRequestTick -ModuleName Corpus.RateLimit {$script:TestShared.Cancel=$true}
        {Invoke-CorpusYouTubeProcess $ctx @('fixture')} | Should Throw
        $ctx.Shared.Progress.Stage | Should Match 'resuming in 120s'
        (Read-CorpusRequestState).ResumeAfter | Should Be '2026-09-26T12:02:00Z'
        Assert-MockCalled Invoke-CorpusProcess -ModuleName Corpus.RateLimit -Times 0 -Exactly -Scope It
    }
    It 'waits through persisted cooldown before a successful retry and clears caption failures' {
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=2;ResumeAfter='2026-09-26T12:04:00Z';NextRequestAt='';Halted=$false}
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}}
        $result=Invoke-CorpusYouTubeProcess $ctx @('fixture') -Kind Subtitle
        $result.ExitCode | Should Be 0
        (Read-CorpusRequestState).RateLimitCount | Should Be 0
        Assert-MockCalled Wait-CorpusRequestTick -ModuleName Corpus.RateLimit -Times 4 -Exactly -Scope It
    }
    It 'does not mistake metadata success for recovery of subtitle throttling' {
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=2;ResumeAfter='2026-09-26T11:59:00Z';NextRequestAt='';Halted=$false}
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}}
        $null=Invoke-CorpusYouTubeProcess $ctx @('fixture')
        (Read-CorpusRequestState).RateLimitCount | Should Be 2
    }
    It 'spaces invocations and leaves non-429 failures to the normal error handling' {
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=1;StdOut='';StdErr='HTTP Error 403: Forbidden'}}
        $null=Invoke-CorpusYouTubeProcess $ctx @('fixture')
        $null=Invoke-CorpusYouTubeProcess $ctx @('fixture')
        Assert-MockCalled Wait-CorpusRequestTick -ModuleName Corpus.RateLimit -Times 1 -Exactly -Scope It
        (Read-CorpusRequestState).RateLimitCount | Should Be 0
    }
    It 'allows a user retry after the final cooldown and resets the attempt budget' {
        Write-CorpusJson (Get-CorpusRequestStatePath) @{RateLimitCount=4;ResumeAfter='2026-09-26T11:59:00Z';NextRequestAt='';Halted=$true}
        Mock Invoke-CorpusProcess -ModuleName Corpus.RateLimit {[pscustomobject]@{ExitCode=0;StdOut='';StdErr=''}}
        $null=Invoke-CorpusYouTubeProcess $ctx @('fixture')
        (Read-CorpusRequestState).Halted | Should Be $false
        (Read-CorpusRequestState).RateLimitCount | Should Be 0
    }
}
Describe 'Rate limit stops the entire queue' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
    }
    It 'does not schedule a second channel and records RateLimited instead of Failed' {
        Mock Invoke-CorpusProcess -ModuleName Corpus.Operations {[pscustomobject]@{ExitCode=0;StdOut='fixture';StdErr=''}}
        Mock Sync-CorpusChannel -ModuleName Corpus.Operations {Stop-CorpusRateLimit}
        {Invoke-CorpusOperation $root SyncAll} | Should Throw
        Assert-MockCalled Sync-CorpusChannel -ModuleName Corpus.Operations -Times 1 -Exactly -Scope It
        $run=Read-CorpusJson (Get-ChildItem (Join-Path $root data/normalized/runs) -Filter '*.json')[0].FullName
        $run.FinalState | Should Be RateLimited
    }
    It 'does not schedule a second video after retries are exhausted' {
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {[pscustomobject]@{ExitCode=0;StdErr='';StdOut='{"id":"UC1234567890123456789012","entries":[{"id":"abcDEF12_-3"},{"id":"defDEF12_-3"}]}'} }
        Mock Import-CorpusVideo -ModuleName Corpus.YouTube {Stop-CorpusRateLimit}
        $run=[pscustomobject]@{VideosDiscovered=0;Failures=0}
        try {Corpus.YouTube\Sync-CorpusChannel $ctx 'https://www.youtube.com/@atmoio' mo Mo $run;throw 'Expected rate limit'} catch {(Test-CorpusRateLimitError $_.Exception) | Should Be $true}
        Assert-MockCalled Import-CorpusVideo -ModuleName Corpus.YouTube -Times 1 -Exactly -Scope It
        (Read-CorpusJson (Join-Path $root data/normalized/channels/UC1234567890123456789012.json)).Status | Should Be RateLimited
    }
}
Describe 'Cached transcript reuse' {
    BeforeEach {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $fixture=Get-Content (Join-Path $PSScriptRoot fixtures/video.info.json) -Raw -Encoding UTF8 | ConvertFrom-Json
        $video=ConvertTo-CorpusVideo $fixture mo Mo
        $video.TranscriptAvailable=$true;$video.TranscriptPath='data/normalized/transcripts/cached.json'
        Write-CorpusJson (Join-Path $ctx.Root $video.TranscriptPath) @(ConvertFrom-CorpusVtt (Join-Path $PSScriptRoot fixtures/rolling.en.vtt) $video Manual)
        Save-CorpusVideo $ctx $video
        Mock Get-CorpusMetadata -ModuleName Corpus.YouTube {throw 'Network request attempted'}
    }
    It 'reuses a valid transcript before making any metadata or subtitle request' {
        $result=Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3' mo Mo
        $result.TranscriptPath | Should Be $video.TranscriptPath
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 0 -Exactly -Scope It
    }
    It 'does not trust missing or corrupt transcript files' {
        [IO.File]::WriteAllText((Join-Path $ctx.Root $video.TranscriptPath),'{broken')
        (Test-CorpusCachedTranscript $ctx $video) | Should Be $false
        {Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3'} | Should Throw
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 1 -Exactly -Scope It
    }
    It 'honors explicit refresh even when a valid cached transcript exists' {
        {Import-CorpusVideo $ctx 'https://youtu.be/abcDEF12_-3' -RefreshTranscript} | Should Throw
        Assert-MockCalled Get-CorpusMetadata -ModuleName Corpus.YouTube -Times 1 -Exactly -Scope It
    }
}
Describe 'Rate limit status across the GUI worker boundary' {
    It 'preserves the typed stop reason through asynchronous PowerShell invocation' {
        $worker=[powershell]::Create()
        try {
            $null=$worker.AddScript({param($path) Import-Module $path -Force;Stop-CorpusRateLimit}).AddArgument((Join-Path $project 'src/Corpus.RateLimit.psm1'))
            $handle=$worker.BeginInvoke()
            try {$null=$worker.EndInvoke($handle);throw 'Expected worker to stop'}
            catch {(Test-CorpusRateLimitError $_.Exception) | Should Be $true}
        } finally {$worker.Dispose()}
    }
}
Describe 'Early native 429 interruption' {
    It 'stops a running process without waiting for its next request or timeout' {
        $ctx=New-CorpusContext (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $result=Invoke-CorpusProcess $ctx (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @('-NoProfile','-Command','[Console]::Error.WriteLine("ERROR: HTTP Error 429: Too Many Requests");Start-Sleep -Seconds 30') -StopOnRateLimit -Quiet
        $result.RateLimited | Should Be $true
        ($watch.Elapsed.TotalSeconds -lt 15) | Should Be $true
    }
}
