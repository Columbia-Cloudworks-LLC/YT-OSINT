$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations','Queue')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Describe 'Persistent batch queue and subject protection' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
    }
    It 'normalizes URL variants and skips duplicate video IDs without sending network requests' {
        $r=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://www.youtube.com/watch?v=abcDEF12_-3&t=20`nhttps://youtube.com/shorts/xyzDEF12_-3" mo
        $r.Added | Should Be 2;$r.Duplicates | Should Be 1
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 2;$q.Paused | Should Be $true
        $q.Items[0].SubjectId | Should Be mo;$q.Items[0].Url | Should Be 'https://www.youtube.com/watch?v=abcDEF12_-3'
        (Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo).Duplicates | Should Be 1
    }
    It 'rejects an entire invalid batch without losing or partially adding items' {
        {Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtube.com/@channel" mo} | Should Throw
        @( (Get-CorpusQueue $root).Items).Count | Should Be 0
        {Add-CorpusQueueUrls $root 'https://youtube.com.evil.test/watch?v=abcDEF12_-3' mo} | Should Throw
        {Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' missing} | Should Throw
    }
    It 'locks queued subject names while permitting new subjects and association updates' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        {Set-CorpusSubject $root Renamed mo} | Should Throw
        $id=Set-CorpusSubject $root Other
        Set-CorpusSubject $root Updated $id | Should Be $id
        Set-CorpusChannelAssociation $root mo 'https://youtube.com/@additional'
        (Get-CorpusConfig $root).subjects[0].channels.Count | Should Be 3
        $q=Get-CorpusQueue $root;Update-CorpusQueue $root Remove $q.Items[0].Id
        Set-CorpusSubject $root Renamed mo | Should Be mo
    }
    It 'protects the existing subject when a saved video is queued without an explicit subject' {
        $video=ConvertTo-CorpusVideo ([pscustomobject]@{id='abcDEF12_-3'}) mo Mo;Save-CorpusVideo $ctx $video
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3'
        (Get-CorpusQueue $root).Items[0].SubjectId | Should Be mo
        {Set-CorpusSubject $root Renamed mo} | Should Throw
    }
    It 'does not remove an active item and recovers an orphaned item paused' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        $q=Get-CorpusQueue $root;$q.Items[0].Status='Running';$q.Paused=$false;Write-CorpusJson (Join-Path $root data/queue.json) $q
        {Update-CorpusQueue $root Remove $q.Items[0].Id} | Should Throw
        $restored=Initialize-CorpusQueue $root;$restored.Paused | Should Be $true;$restored.Items[0].Status | Should Be Pending
    }
    It 'does not recover or start a second runner while another process owns the queue' {
        $null=Initialize-CorpusQueue $root
        $guard=[IO.File]::Open((Join-Path $root data/queue-runner.lock),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            {Invoke-CorpusQueue $root} | Should Throw
            (Initialize-CorpusQueue $root).Paused | Should Be $true
        } finally {$guard.Dispose()}
    }
    It 'refreshes subject names on retry and refuses a duplicate pending retry' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        $q=Get-CorpusQueue $root;$q.Items[0].Status='Failed';Write-CorpusJson (Join-Path $root data/queue.json) $q
        $null=Set-CorpusSubject $root Renamed mo
        Update-CorpusQueue $root Retry $q.Items[0].Id
        (Get-CorpusQueue $root).Items[0].SubjectName | Should Be Renamed
        {Update-CorpusQueue $root Retry $q.Items[0].Id} | Should Throw
    }
}
Describe 'Sequential queue processing' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        $null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3" mo
        $shared=[hashtable]::Synchronized(@{Cancel=$false;Shutdown=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {[pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}}
    }
    It 'drains sequentially, persists completion, and unlocks the subject' {
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;@($q.Items | Where-Object Status -eq Completed).Count | Should Be 2;$q.Paused | Should Be $true
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 2 -Exactly -Scope It
        Set-CorpusSubject $root Renamed mo | Should Be mo
    }
    It 'preserves queue additions and removals made during an active item, then pauses' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {
            $q=Get-CorpusQueue $Root
            if($q.Items[0].Status -ne 'Running'){throw 'Current item was not claimed.'}
            $blocked=$false;try{$null=Set-CorpusSubject $Root Blocked mo}catch{$blocked=$true};if(-not $blocked){throw 'Queued subject was renamed.'}
            $new=Set-CorpusSubject $Root AddedDuringDownload
            $null=Add-CorpusQueueUrls $Root 'https://youtu.be/newDEF12_-3' $new
            Update-CorpusQueue $Root Remove $q.Items[1].Id
            Update-CorpusQueue $Root Pause
            [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
        }
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 2;$q.Items[0].Status | Should Be Completed;$q.Items[1].VideoId | Should Be newDEF12_-3;$q.Items[1].Status | Should Be Pending
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 1 -Exactly -Scope It
    }
    It 'continues after ordinary failures and retains the error' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {if($Arguments.Url -match 'abcDEF12_-3'){throw 'Video unavailable'};[pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Items[0].Status | Should Be Failed;$q.Items[0].Detail | Should Match unavailable;$q.Items[1].Status | Should Be Completed
    }
    It 'stops the queue on exhausted rate limiting and leaves the current item pending' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {Stop-CorpusRateLimit}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Paused | Should Be $true;@($q.Items | Where-Object Status -eq Pending).Count | Should Be 2
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 1 -Exactly -Scope It
    }
    It 'cancels only the current item and pauses before the next' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {$Shared.Cancel=$true;throw [OperationCanceledException]::new('Cancelled')}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Items[0].Status | Should Be Cancelled;$q.Items[1].Status | Should Be Pending;$q.Paused | Should Be $true
    }
    It 'keeps interrupted work resumable when the window is closing' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {$Shared.Shutdown=$true;$Shared.Cancel=$true;throw [OperationCanceledException]::new('Closing')}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;@($q.Items | Where-Object Status -eq Pending).Count | Should Be 2
    }
    It 'records member-only skips separately from failures' {
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {[pscustomobject]@{MembersOnlySkipped=1;TranscriptsUnavailable=0;FinalState='Success'}}
        Invoke-CorpusQueue $root $shared
        @((Get-CorpusQueue $root).Items | Where-Object Status -eq Skipped).Count | Should Be 2
    }
}
Describe 'Queue isolation and real cached ingestion' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
    }
    It 'serializes simultaneous subject writers without losing edits' {
        $workers=@()
        try {
            foreach($prefix in @('A','B')){
                $ps=[powershell]::Create()
                $null=$ps.AddScript({param($root,$module,$prefix)
                    $ErrorActionPreference='Stop';Import-Module $module -Force
                    foreach($n in 1..8){$null=Set-CorpusSubject $root "$prefix$n"}
                }).AddArgument($root).AddArgument((Join-Path $project src/Corpus.Core.psm1)).AddArgument($prefix)
                $workers+=@{PS=$ps;Handle=$ps.BeginInvoke()}
            }
            foreach($worker in $workers){$null=$worker.PS.EndInvoke($worker.Handle);$worker.PS.HadErrors | Should Be $false}
            (Get-CorpusConfig $root).subjects.Count | Should Be 17
        } finally {foreach($worker in $workers){$worker.PS.Dispose()}}
    }
    It 'runs the actual operation with cached transcripts under the queue-owned writer lock' {
        # Fresh modules avoid Pester 3 mock cleanup removing global command exports.
        Import-Module (Join-Path $project src/Corpus.Operations.psm1) -Force -Global
        Import-Module (Join-Path $project src/Corpus.Queue.psm1) -Force -Global
        Mock Invoke-CorpusProcess -ModuleName Corpus.Operations {[pscustomobject]@{ExitCode=0;StdOut='fixture';StdErr=''}}
        $meta=Read-CorpusJson (Join-Path $PSScriptRoot fixtures/video.info.json)
        $v=ConvertTo-CorpusVideo $meta mo Mo
        $rows=@(ConvertFrom-CorpusVtt (Join-Path $PSScriptRoot fixtures/rolling.en.vtt) $v Manual)
        $v.TranscriptAvailable=$true;$v.TranscriptPath="data/normalized/transcripts/$($v.VideoId).json"
        Write-CorpusJson (Join-Path $root $v.TranscriptPath) $rows;Save-CorpusVideo $ctx $v
        $null=Add-CorpusQueueUrls $root $v.VideoUrl mo
        Invoke-CorpusQueue $root
        (Get-CorpusQueue $root).Items[0].Status | Should Be Completed
        @(Get-ChildItem (Join-Path $root data/normalized/runs) -Filter '*.json').Count | Should Be 1
        Test-Path (Join-Path $root output/YouTubeCorpus.xlsx) | Should Be $false
        (Read-CorpusJson (Join-Path $root "data/normalized/videos/$($v.VideoId).json")).TranscriptAvailable | Should Be $true
    }
}
