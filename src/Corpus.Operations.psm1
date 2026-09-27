Set-StrictMode -Version 2
function Invoke-CorpusOperation {
    param([string]$Root,[string]$Operation,$Arguments=@{},$Shared=$null,$CorpusLock=$null)
    # Configuration has its own short lock, independent of the network/import lock.
    if($Operation -eq 'Subject'){return Set-CorpusSubject $Root $Arguments.Name $Arguments.Id}
    if($Operation -eq 'Associate'){Set-CorpusChannelAssociation $Root $Arguments.SubjectId $Arguments.Url -Remove:([bool]$Arguments.Remove);return}
    $ctx=New-CorpusContext $Root $Shared
    # A file handle lock excludes other GUI/CLI writers; crashes release it automatically.
    $lock=$null; $run=$null; $dependencyLock=$null; $dependencyCommitLock=$null
    try {
        if($Operation -in @('SyncAll','SyncChannel','Video','Build')) {
            $dependencyLock=Enter-CorpusDependencyLock
            $dependencyCommitLock=Enter-CorpusDependencyLock -Commit
            if(@(Get-CorpusDependencyRecovery).Count){throw 'An interrupted dependency update requires recovery in Settings > Dependencies.'}
        }
        if(-not $CorpusLock -and $Operation -notin @('Search','Refresh')) {
            try{$lock=[IO.File]::Open((Join-Path $Root 'data/corpus.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'Another application instance is writing this corpus. Wait for it to finish.'}
        }
        if($Operation -in @('SyncAll','SyncChannel','Video','Build')) {
            # Reconcile records interrupted by process termination; the exclusive lock proves no writer is still active.
            foreach($file in Get-ChildItem (Join-Path $Root 'data/normalized/runs') -Filter '*.json') {
                $prior=Read-CorpusJson $file.FullName
                if($prior.FinalState -in @('Running','CommittingWorkbook')){$prior.FinalState='Interrupted';$prior.EndTimestamp=[datetime]::UtcNow.ToString('o');Write-CorpusJson $file.FullName $prior}
            }
            $run=[pscustomobject][ordered]@{RunId=$ctx.RunId;StartTimestamp=[datetime]::UtcNow.ToString('o');EndTimestamp=$null;Machine=$env:COMPUTERNAME;WindowsVersion=[Environment]::OSVersion.VersionString;PowerShellVersion=$PSVersionTable.PSVersion.ToString();YtDlpVersion='Unavailable';FFmpegVersion='Unavailable';ImportExcelVersion='Unavailable';ChannelsRequested=0;VideosDiscovered=0;VideosAdded=0;VideosAlreadyKnown=0;TranscriptsAdded=0;TranscriptsUnavailable=0;MembersOnlySkipped=0;Failures=0;FinalState='Running'}
            Write-CorpusJson (Join-Path $Root "data/normalized/runs/$($ctx.RunId).json") $run
            foreach($name in @('yt-dlp','ffmpeg')) {
                try {$r=Invoke-CorpusProcess $ctx (Join-Path (Get-CorpusNativeRoot) "$name.exe") @($(if($name -eq 'yt-dlp'){'--version'}else{'-version'})) -Quiet; if($r.ExitCode -eq 0){$value=($r.StdOut -split '\r?\n')[0];if($name -eq 'yt-dlp'){$run.YtDlpVersion=$value}else{$run.FFmpegVersion=$value}}}catch{Write-CorpusLog $ctx Warning Versions $name $_.Exception.Message}
            }
            $dependencySettings=Get-CorpusDependencySettings $Root
            $im=if($dependencySettings.ImportExcelPath){Test-ModuleManifest -Path $dependencySettings.ImportExcelPath -ErrorAction Stop}else{Get-Module -ListAvailable ImportExcel | Sort-Object Version -Descending | Select-Object -First 1}
            if($im){$run.ImportExcelVersion=$im.Version.ToString()}
        }
        switch($Operation) {
            'Subject' { $null=Set-CorpusSubject $Root $Arguments.Name $Arguments.Id }
            'Associate' {Set-CorpusChannelAssociation $Root $Arguments.SubjectId $Arguments.Url -Remove:([bool]$Arguments.Remove)}
            'Search' {return @(Find-CorpusTranscript $ctx @Arguments)}
            'Refresh' {return [pscustomobject]@{Config=(Get-CorpusConfig $Root);Videos=@(Get-CorpusVideos $Root);Channels=@(Get-ChildItem (Join-Path $Root 'data/normalized/channels') -Filter '*.json' | ForEach-Object {Read-CorpusJson $_.FullName});Attempts=@(Get-ChildItem (Join-Path $Root 'data/normalized/channel-attempts') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {Read-CorpusJson $_.FullName})}}
            'Video' {
                $run.VideosDiscovered=1
                try{$null=Import-CorpusVideo $ctx $Arguments.Url $Arguments.SubjectId $Arguments.SubjectName $run -RefreshTranscript:([bool]$Arguments['RefreshTranscript'])}
                catch {
                    if($_.Exception -is [OperationCanceledException] -or (Test-CorpusRateLimitError $_.Exception)){throw}
                    $uri=[uri]$Arguments.Url; $id=''
                    if($uri.Host -eq 'youtu.be'){$id=$uri.AbsolutePath.Trim('/')}elseif($uri.Query -match '(?:\?|&)v=([A-Za-z0-9_-]{11})'){$id=$Matches[1]}elseif($uri.AbsolutePath -match '/(?:shorts|live)/([A-Za-z0-9_-]{11})'){$id=$Matches[1]}
                    Save-CorpusFailure $ctx $id $_.Exception.Message $Arguments.SubjectId $Arguments.SubjectName
                    throw
                }
            }
            {$_ -in @('SyncAll','SyncChannel')} {
                $config=Get-CorpusConfig $Root
                $sources=@(foreach($s in $config.subjects){foreach($c in $s.channels){if($Operation -eq 'SyncAll' -or $c.url -eq $Arguments.Url){[pscustomobject]@{Url=$c.url;SubjectId=$s.id;SubjectName=$s.name}}}})
                if(-not $sources.Count){throw 'No configured channels were selected.'}
                $run.ChannelsRequested=$sources.Count
                foreach($source in $sources) {
                    Test-CorpusCancellation $ctx
                    try{$limit=0;if($Arguments.ContainsKey('Limit')){$limit=[int]$Arguments.Limit};Sync-CorpusChannel $ctx $source.Url $source.SubjectId $source.SubjectName $run $limit -RefreshTranscript:([bool]$Arguments['RefreshTranscript'])}
                    catch{if($_.Exception -is [OperationCanceledException] -or (Test-CorpusRateLimitError $_.Exception)){throw};$run.Failures++;Write-CorpusLog $ctx Error Channel $source.Url $_.Exception.Message $_.ToString()}
                }
            }
            'Build' {}
            default {throw "Unknown operation: $Operation"}
        }
        if($run) {
            $finalState=if($run.Failures){'Partial'}else{'Success'}
            $run.FinalState='CommittingWorkbook';$run.EndTimestamp=[datetime]::UtcNow.ToString('o')
            Write-CorpusJson (Join-Path $Root "data/normalized/runs/$($ctx.RunId).json") $run
            # The workbook displays the intended final state; canonical state remains recoverable until commit.
            $view=$run | Select-Object *; $view.FinalState=$finalState
            if($Operation -eq 'Build' -or -not $Arguments['SkipWorkbook']){$null=Export-CorpusWorkbook $ctx -RunOverride $view}
            $run.FinalState=$finalState
            Write-CorpusLog $ctx Info Summary '' "$($run.VideosDiscovered) discovered; $($run.VideosAdded) new; $($run.VideosAlreadyKnown) known; $($run.TranscriptsAdded) transcripts added; $($run.TranscriptsUnavailable) unavailable; $($run.MembersOnlySkipped) members-only skipped; $($run.Failures) failures. $($run.FinalState)."
            return $run
        }
    } catch {
        if($run){$run.FinalState=if(($Shared -and $Shared.Cancel) -or $_.Exception -is [OperationCanceledException]){'Cancelled'}elseif(Test-CorpusRateLimitError $_.Exception){'RateLimited'}else{'Failed'};if($run.FinalState -in @('Failed','RateLimited')){$run.Failures++};$run.EndTimestamp=[datetime]::UtcNow.ToString('o')}
        Write-CorpusLog $ctx Error $Operation '' $_.Exception.Message $_.ToString()
        throw
    } finally {
        if($run){Write-CorpusJson (Join-Path $Root "data/normalized/runs/$($ctx.RunId).json") $run}
        if($lock){$lock.Dispose()}
        if($dependencyCommitLock){$dependencyCommitLock.ReleaseMutex();$dependencyCommitLock.Dispose()}
        if($dependencyLock){$dependencyLock.ReleaseMutex();$dependencyLock.Dispose()}
    }
}
Export-ModuleMember -Function Invoke-CorpusOperation
