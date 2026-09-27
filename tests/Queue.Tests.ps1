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

Describe 'Universal channel and batch scheduler' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        $url='https://www.youtube.com/@atmoio'
        $shared=[hashtable]::Synchronized(@{Cancel=$false;Shutdown=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {[pscustomobject]@{ChannelId='UC1234567890123456789012';Entries=@([pscustomobject]@{id='abcDEF12_-3';title='Discovered video'})}}
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {[pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}}
    }
    It 'locks subjects before discovery and suppresses duplicate channel jobs' {
        $id=Add-CorpusSyncJob $root $url mo
        (Get-CorpusQueue $root).Items.Count | Should Be 0
        {Set-CorpusSubject $root Renamed mo} | Should Throw
        {Remove-CorpusSubject $root mo} | Should Throw
        $null=Add-CorpusSyncJob $root $url mo
        (Get-CorpusQueue $root).SyncJobs.Count | Should Be 1
        Stop-CorpusSyncJob $root $id
        Set-CorpusSubject $root Renamed mo | Should Be mo
    }
    It 'discovers channel videos and completes them through the ordinary queue worker' {
        $null=Add-CorpusSyncJob $root $url mo
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status | Should Be Completed;$q.Items[0].Status | Should Be Completed
        $q.Items[0].SubjectId | Should Be mo;$q.Items[0].ListingEntry.title | Should Be 'Discovered video'
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 1 -Exactly -Scope It
    }
    It 'shares a pending batch video and preserves it when cancelling its channel sync' {
        $id=Add-CorpusSyncJob $root $url mo
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Discovering';Write-CorpusJson (Join-Path $root data/queue.json) $q
        (Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo -JobId $id).Duplicates | Should Be 1
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Downloading';Write-CorpusJson (Join-Path $root data/queue.json) $q
        Stop-CorpusSyncJob $root $id
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 1;$q.Items[0].Status | Should Be Pending
        Invoke-CorpusQueue $root $shared
        (Get-CorpusQueue $root).SyncJobs[0].Status | Should Be Cancelled
    }
    It 'cancels sync-owned pending items and preserves an active item until it finishes' {
        $id=Add-CorpusSyncJob $root $url mo
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Discovering';Write-CorpusJson (Join-Path $root data/queue.json) $q
        $null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3" mo -JobId $id
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Downloading';$q.Items[0].Status='Running';Write-CorpusJson (Join-Path $root data/queue.json) $q
        Stop-CorpusSyncJob $root $id
        $q=Get-CorpusQueue $root;$q.Items[0].Status | Should Be Running;$q.Items[1].Status | Should Be Cancelled;$q.SyncJobs[0].Status | Should Be Cancelling
        $null=Add-CorpusSyncJob $root $url mo
        (Get-CorpusQueue $root).SyncJobs.Count | Should Be 1
    }
    It 'discovers every queued channel before downloading even an older batch item' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        $null=Add-CorpusSyncJob $root $url mo
        $null=Add-CorpusSyncJob $root 'https://www.youtube.com/@lessbitter' mo
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {
            if(@((Get-CorpusQueue $Context.Root).Items | Where-Object Status -ne Pending).Count){throw 'A video ran before all discoveries'}
            [pscustomobject]@{ChannelId=$(if($Url -match 'lessbitter'){'UC2234567890123456789012'}else{'UC1234567890123456789012'});Entries=@([pscustomobject]@{id='abcDEF12_-3'})}
        }
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {
            if(@((Get-CorpusQueue $Root).SyncJobs | Where-Object Status -in @('Pending','Discovering')).Count){throw 'Discovery barrier was bypassed'}
            [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
        }
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root
        @($q.SyncJobs | Where-Object Status -eq Completed).Count | Should Be 2
        $q.Items.Count | Should Be 1;$q.Items[0].Status | Should Be Completed
        Assert-MockCalled Sync-CorpusChannel -ModuleName Corpus.Queue -Times 2 -Exactly -Scope It
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 1 -Exactly -Scope It
    }
    It 'discovers a channel added during a download before claiming the next video' {
        $null=Add-CorpusSyncJob $root $url mo
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {
            $entries=if($Url -match 'lessbitter'){@([pscustomobject]@{id='newDEF12_-3'})}else{@([pscustomobject]@{id='abcDEF12_-3'},[pscustomobject]@{id='xyzDEF12_-3'})}
            [pscustomobject]@{ChannelId=$(if($Url -match 'lessbitter'){'UC2234567890123456789012'}else{'UC1234567890123456789012'});Entries=$entries}
        }
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {
            if($Arguments.Url -match 'abcDEF12_-3'){$null=Add-CorpusSyncJob $Root 'https://www.youtube.com/@lessbitter' mo}
            else{if(@((Get-CorpusQueue $Root).SyncJobs | Where-Object Status -in @('Pending','Discovering')).Count){throw 'New channel was left behind downloads'}}
            [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
        }
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;@($q.Items | Where-Object Status -eq Completed).Count | Should Be 3
        @($q.SyncJobs | Where-Object Status -eq Completed).Count | Should Be 2
    }
    It 'pauses safely between discoveries and resumes discovery before downloading' {
        $null=Add-CorpusSyncJob $root $url mo
        $null=Add-CorpusSyncJob $root 'https://www.youtube.com/@lessbitter' mo
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {
            if($Url -match 'atmoio'){Update-CorpusQueue $Context.Root Pause}
            [pscustomobject]@{ChannelId='UC1234567890123456789012';Entries=@([pscustomobject]@{id='abcDEF12_-3'})}
        }
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Paused | Should Be $true;$q.SyncJobs[1].Status | Should Be Pending;$q.Items[0].Status | Should Be Pending
        Assert-MockCalled Invoke-CorpusOperation -ModuleName Corpus.Queue -Times 0 -Exactly -Scope It
        Invoke-CorpusQueue $root $shared
        (Get-CorpusQueue $root).Items[0].Status | Should Be Completed
    }
    It 'continues past failed discovery and unlocks the failed channel' {
        $null=Add-CorpusSyncJob $root $url mo
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {throw 'Discovery fixture failure'}
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status | Should Be Failed;$q.Items[0].Status | Should Be Completed
        $null=Add-CorpusSyncJob $root $url mo
        (Get-CorpusQueue $root).SyncJobs.Count | Should Be 2
    }
    It 'pauses exhausted discovery throttling and retains the job for resume' {
        $null=Add-CorpusSyncJob $root $url mo
        Mock Sync-CorpusChannel -ModuleName Corpus.Queue {Stop-CorpusRateLimit}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.Paused | Should Be $true;$q.SyncJobs[0].Status | Should Be Pending
    }
    It 'recovers interrupted discovery paused and upgrades legacy queues without losing items' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        $q=Get-CorpusQueue $root;$q.PSObject.Properties.Remove('SyncJobs');$q.Items[0].PSObject.Properties.Remove('JobIds');$q.Items[0].PSObject.Properties.Remove('Batch');Write-CorpusJson (Join-Path $root data/queue.json) $q
        (Initialize-CorpusQueue $root).Items[0].Batch | Should Be $true
        $null=Add-CorpusSyncJob $root $url mo
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Discovering';Write-CorpusJson (Join-Path $root data/queue.json) $q
        (Initialize-CorpusQueue $root).SyncJobs[0].Status | Should Be Pending
    }
    It 'retains a failed child for sync accounting when it is retried before other children finish' {
        $id=Add-CorpusSyncJob $root $url mo
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Discovering';Write-CorpusJson (Join-Path $root data/queue.json) $q
        $null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3" mo -JobId $id
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Downloading';$q.Items[0].Status='Failed';Write-CorpusJson (Join-Path $root data/queue.json) $q
        Update-CorpusQueue $root Retry $q.Items[0].Id
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 3;$q.Items[0].Status | Should Be Failed;$q.Items[2].Status | Should Be Pending
        Invoke-CorpusQueue $root $shared
        (Get-CorpusQueue $root).SyncJobs[0].Status | Should Be Partial
    }
    It 'keeps failures retryable without keeping a finished channel locked' {
        $null=Add-CorpusSyncJob $root $url mo
        Mock Invoke-CorpusOperation -ModuleName Corpus.Queue {throw 'Video failed'}
        Invoke-CorpusQueue $root $shared
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status | Should Be Partial
        Update-CorpusQueue $root Retry $q.Items[0].Id
        $q=Get-CorpusQueue $root;$q.Items[0].Status | Should Be Pending;$q.Items[0].JobIds.Count | Should Be 0
    }
}

Describe 'Channel discovery without inline downloads' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$ctx=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        Mock Invoke-CorpusYouTubeProcess -ModuleName Corpus.YouTube {[pscustomobject]@{ExitCode=0;StdErr='';StdOut='{"id":"UC1234567890123456789012","channel":"Discovered name","entries":[{"id":"abcDEF12_-3","title":"Members video","availability":"subscriber_only"},{"entries":[{"id":"xyzDEF12_-3","title":"Public video"}]}]}'}}
        Mock Import-CorpusVideo -ModuleName Corpus.YouTube {throw 'Discovery should not download'}
    }
    It 'persists the resolved name and returns nested listing entries for later queue imports' {
        $run=[pscustomobject]@{VideosDiscovered=0;Failures=0;MembersOnlySkipped=0}
        $result=Sync-CorpusChannel $ctx 'https://www.youtube.com/@atmoio' mo Mo $run -DiscoverOnly
        $result.Entries.Count | Should Be 2;$result.Entries[0].availability | Should Be subscriber_only
        $result.Entries[0].channel_id | Should Be UC1234567890123456789012;$result.Entries[0].channel | Should Be 'Discovered name'
        $channel=Read-CorpusJson (Join-Path $root data/normalized/channels/UC1234567890123456789012.json)
        $channel.ChannelName | Should Be 'Discovered name';$channel.Status | Should Be Queued
        Assert-MockCalled Import-CorpusVideo -ModuleName Corpus.YouTube -Times 0 -Exactly -Scope It
    }
}

Describe 'Atomic multi-item removal' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        $null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3`nhttps://youtu.be/newDEF12_-3" mo
    }
    It 'removes pending selections and skips items claimed by the worker or already missing' {
        $q=Get-CorpusQueue $root;$q.Items[1].Status='Running';Write-CorpusJson (Join-Path $root data/queue.json) $q
        $result=Remove-CorpusQueueItems $root @($q.Items[0].Id,$q.Items[1].Id,$q.Items[2].Id,'missing',$q.Items[0].Id)
        $result.Removed | Should Be 2;$result.Skipped | Should Be 2
        $remaining=Get-CorpusQueue $root;$remaining.Items.Count | Should Be 1;$remaining.Items[0].Status | Should Be Running
    }
    It 'marks all shared jobs partial and never advances the previous full-sync timestamp' {
        $q=Get-CorpusQueue $root;$q.Items[0].JobIds=@('a','b');$q.Items[1].Status='Completed';$q.Items[1].JobIds=@('a','b')
        $q.SyncJobs=@(foreach($id in @('a','b')){[pscustomobject]@{Id=$id;Status='Downloading';ChannelId=$id;Url="https://youtube.com/@$id";AddedAt='2026-09-27T00:00:00Z';FinishedAt=$null;Detail=''}})
        foreach($id in @('a','b')){Write-CorpusJson (Join-Path $root "data/normalized/channels/$id.json") ([pscustomobject]@{ChannelId=$id;LastSync='2026-09-01T00:00:00Z';Status='Downloading';TranscriptCount=0;WithoutTranscripts=0;Failures=0;MembersOnlySkipped=0})}
        Write-CorpusJson (Join-Path $root data/queue.json) $q
        $result=Remove-CorpusQueueItems $root @($q.Items[0].Id)
        $result.Removed | Should Be 1
        foreach($job in (Get-CorpusQueue $root).SyncJobs){$job.Status | Should Be Partial;$job.PartialImport | Should Be $true;(Read-CorpusJson (Join-Path $root "data/normalized/channels/$($job.Id).json")).LastSync | Should Be '2026-09-01T00:00:00Z'}
        Update-CorpusQueue $root Retry $q.Items[0].Id
        foreach($job in (Get-CorpusQueue $root).SyncJobs){$job.Status | Should Be Partial}
    }
}

Describe 'Clear finished history without losing sync results' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
        $q=Get-CorpusQueue $root
        $q.SyncJobs=@(foreach($id in @('a','b')){[pscustomobject]@{Id=$id;Status='Downloading';ChannelId=$id;Url="https://youtube.com/@$id";AddedAt='2026-09-27T00:00:00Z';FinishedAt=$null;Detail=''}})
        $q.Items=@(foreach($status in @('Pending','Running','Completed','Skipped','Failed','Cancelled')){[pscustomobject]@{Id=$status;VideoId=$status;Status=$status;JobIds=@('a','b');Batch=$false;ListingEntry=$null}})
        foreach($id in @('a','b')){Write-CorpusJson (Join-Path $root "data/normalized/channels/$id.json") ([pscustomobject]@{ChannelId=$id;LastSync='2026-09-01T00:00:00Z';Status='Downloading';TranscriptCount=0;WithoutTranscripts=0;Failures=0;MembersOnlySkipped=0})}
        Write-CorpusJson (Join-Path $root data/queue.json) $q
    }
    It 'clears every terminal state immediately even when referenced by active jobs' {
        Update-CorpusQueue $root ClearFinished
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 2
        ($q.Items.Status -join ',') | Should Be 'Pending,Running'
        foreach($job in $q.SyncJobs){$job.ClearedResults.Completed | Should Be 1;$job.ClearedResults.Skipped | Should Be 1;$job.ClearedResults.Failed | Should Be 1;$job.ClearedResults.Cancelled | Should Be 1}
        Update-CorpusQueue $root ClearFinished
        (Get-CorpusQueue $root).SyncJobs[0].ClearedResults.Failed | Should Be 1
    }
    It 'retains partial outcome and failure totals after reload and later completion' {
        Update-CorpusQueue $root ClearFinished
        $q=Get-CorpusQueue $root;foreach($item in $q.Items){$item.Status='Completed'}
        Write-CorpusJson (Join-Path $root data/queue.json) $q
        Update-CorpusQueue $root ClearFinished
        $q=Get-CorpusQueue $root;$q.Items.Count | Should Be 0
        foreach($job in $q.SyncJobs){$job.Status | Should Be Partial;$job.Detail | Should Match '6 videos; 1 failed; 1 cancelled';(Read-CorpusJson (Join-Path $root "data/normalized/channels/$($job.Id).json")).LastSync | Should Be '2026-09-01T00:00:00Z'}
    }
    It 'still completes a successful full sync when its successful rows were cleared' {
        $q=Get-CorpusQueue $root;$q.Items=@($q.Items | Where-Object Status -in @('Pending','Completed','Skipped'))
        Write-CorpusJson (Join-Path $root data/queue.json) $q
        Update-CorpusQueue $root ClearFinished
        $q=Get-CorpusQueue $root;$q.Items[0].Status='Completed';Write-CorpusJson (Join-Path $root data/queue.json) $q
        Update-CorpusQueue $root ClearFinished
        foreach($job in (Get-CorpusQueue $root).SyncJobs){$job.Status | Should Be Completed;$job.Detail | Should Match '3 videos; 0 failed; 0 cancelled'}
    }
    It 'exposes separate discovery and visible-video progress without inventing an ETA' {
        $q=Get-CorpusQueue $root;$q.SyncJobs[0].Status='Discovering';$q.SyncJobs[1].Status='Pending';$q.Paused=$false
        $progress=Get-CorpusQueueProgress $q;$progress.WaitingChannels | Should Be 2;$progress.Value | Should Be 0;$progress.Maximum | Should Be 2
        $q.SyncJobs[0].Status='Downloading';$progress=Get-CorpusQueueProgress $q;$progress.DiscoveryFinished | Should Be 1
        $q.SyncJobs[1].Status='Downloading';$progress=Get-CorpusQueueProgress $q;$progress.Phase | Should Be 'Downloading videos';$progress.Finished | Should Be 4;$progress.Maximum | Should Be 6
    }
}
