[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/discovery-queue-'+[guid]::NewGuid().ToString('N'))
$null=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
$null=Add-CorpusSyncJob $root 'https://www.youtube.com/@atmoio' mo
$null=Add-CorpusSyncJob $root 'https://www.youtube.com/@lessbitter' mo
$adapter=@'
function script:Sync-CorpusChannel {
    param($Context,$Url,$SubjectId,$SubjectName,$Run,[switch]$DiscoverOnly)
    if(Test-Path (Join-Path $Context.Root 'started.txt')){throw 'Download started before all channels were discovered'}
    if($Url -match 'atmoio'){
        [IO.File]::WriteAllText((Join-Path $Context.Root 'discovering.txt'),'ready')
        $deadline=[datetime]::UtcNow.AddSeconds(45)
        while(-not (Test-Path (Join-Path $Context.Root 'release-discovery.txt'))){Test-CorpusCancellation $Context;if([datetime]::UtcNow -gt $deadline){throw 'Discovery fixture timeout'};Start-Sleep -Milliseconds 50}
        return [pscustomobject]@{ChannelId='UC1234567890123456789012';Entries=@([pscustomobject]@{id='abcDEF12_-3';title='Shared video'},[pscustomobject]@{id='xyzDEF12_-3';title='First channel video'})}
    }
    [pscustomobject]@{ChannelId='UC2234567890123456789012';Entries=@([pscustomobject]@{id='abcDEF12_-3';title='Shared video'},[pscustomobject]@{id='newDEF12_-3';title='Second channel video'})}
}
function script:Invoke-CorpusOperation {
    param($Root,$Operation,$Arguments,$Shared,$CorpusLock)
    if(@((Get-CorpusQueue $Root).SyncJobs | Where-Object Status -in @('Pending','Discovering')).Count){throw 'An undiscovered channel was left behind downloads'}
    [IO.File]::WriteAllText((Join-Path $Root 'started.txt'),'ready')
    $ctx=New-CorpusContext $Root $Shared;$deadline=[datetime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path (Join-Path $Root 'release-download.txt'))){Test-CorpusCancellation $ctx;if([datetime]::UtcNow -gt $deadline){throw 'Download fixture timeout'};Start-Sleep -Milliseconds 50}
    [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
}
'@
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('DiscoveryTestStage')){$state.DiscoveryTestStage=0;$state.DiscoveryDeadline=[datetime]::UtcNow.AddSeconds(75)}
    if([datetime]::UtcNow -gt $state.DiscoveryDeadline){throw "Discovery GUI timeout at $($state.DiscoveryTestStage): $($ui.LogText.Text)"}
    if($state.Worker){return}
    function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) is disabled"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    function Label { [Windows.Automation.AutomationProperties]::GetName($ui.QueueToggle) }
    switch($state.DiscoveryTestStage){
        0 {
            $ui.QueueTab.IsSelected=$true
            if((Label) -ne 'Start' -or $ui.ContainsKey('QueuePause') -or $ui.ContainsKey('QueueCancel')){throw 'Expected one Start/Pause control'}
            if([Windows.Controls.Grid]::GetColumn($ui.QueueToggle) -ne 1){throw 'Queue control is not on the footer right'}
            if($ui.QueueToggle.Content.Children[0] -isnot [Windows.Controls.Image] -or $ui.QueueClear.Content.Children[0] -isnot [Windows.Controls.Image]){throw 'Queue action icons are missing'}
            Click $ui.QueueToggle;$state.DiscoveryTestStage=1
        }
        1 {
            if(-not (Test-Path (Join-Path $root discovering.txt)) -or $ui.QueueStatus.Text -notmatch 'Discovering channels'){return}
            if(Test-Path (Join-Path $root started.txt)){throw 'Batch download bypassed discovery'}
            if((Label) -ne 'Pause' -or $ui.QueueProgress.Maximum -ne 2 -or $ui.QueueProgress.Value -ne 0){throw 'Discovery progress or Pause state is incorrect'}
            Click $ui.QueueToggle;$state.DiscoveryTestStage=2
        }
        2 {
            if((Label) -ne 'Pausing…' -or $ui.QueueToggle.IsEnabled){throw 'Pause must finish active discovery safely'}
            [IO.File]::WriteAllText((Join-Path $root release-discovery.txt),'go');$state.DiscoveryTestStage=3
        }
        3 {
            if($state.QueueWorker){return}
            if((Label) -ne 'Start' -or $state.Queue.SyncJobs[1].Status -ne 'Pending' -or $ui.QueueProgress.Value -ne 1){throw 'Paused discovery lost its progress'}
            Click $ui.QueueToggle;$state.DiscoveryTestStage=4
        }
        4 {
            if(-not (Test-Path (Join-Path $root started.txt)) -or $ui.QueueGrid.Items.Count -ne 3){return}
            $running=@($ui.QueueGrid.Items | Where-Object Status -eq Running)
            if(-not $running.Count){return}
            if($running[0].StatusLabel -ne 'Downloading' -or $running[0].StatusColor -ne '#176BC1'){throw 'Running status badge is missing'}
            if($ui.QueueStatus.Text -notmatch 'Downloading videos'){throw 'Discovery never changed to download progress'}
            $q=Get-CorpusQueue $root
            foreach($status in @('Completed','Skipped','Cancelled','Failed')){$row=$q.Items[0] | Select-Object *;$row.Id='history-'+$status;$row.Status=$status;$q.Items=@($q.Items)+$row}
            Write-CorpusJson (Join-Path $root data/queue.json) $q;$state.DiscoveryTestStage=5
        }
        5 {
            if($ui.QueueGrid.Items.Count -ne 7){return}
            if(@($ui.QueueGrid.Items | Where-Object {-not $_.StatusGlyph -or -not $_.StatusColor}).Count){throw 'A queue status has no badge'}
            Click $ui.QueueClear;$state.DiscoveryTestStage=6
        }
        6 {
            if($ui.QueueGrid.Items.Count -ne 3 -or @($ui.QueueGrid.Items | Where-Object Status -notin @('Pending','Running')).Count){throw 'Clear finished retained terminal rows'}
            foreach($job in (Get-CorpusQueue $root).SyncJobs){if($job.ClearedResults.Failed -ne 1){throw 'Clear lost shared failure accounting'}}
            Click $ui.QueueToggle;$state.DiscoveryTestStage=7
        }
        7 {
            if((Label) -ne 'Pausing…'){throw 'Download pause did not show Pausing'}
            [IO.File]::WriteAllText((Join-Path $root release-download.txt),'go');$state.DiscoveryTestStage=8
        }
        8 {
            if($state.QueueWorker){return}
            if((Label) -ne 'Start' -or @($state.Queue.Items | Where-Object Status -eq Pending).Count -ne 2){throw 'Pause started another item'}
            Click $ui.QueueToggle;$state.DiscoveryTestStage=9
        }
        9 {
            if($state.QueueWorker){return}
            if(@($state.Queue.SyncJobs | Where-Object Status -ne Partial).Count){throw 'Cleared failures turned into successful syncs'}
            Click $ui.QueueClear;$state.DiscoveryTestStage=10
        }
        10 {
            if($ui.QueueGrid.Items.Count -or $ui.QueueToggle.IsEnabled -or @($state.Queue.SyncJobs | Where-Object Status -in @('Pending','Discovering','Downloading')).Count){throw 'Clear left visible or hidden pending work'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeQueueAdapter $adapter
'Discovery queue GUI: discovery barrier, two-phase progress, Start/Pause/Pausing, colored badges, clear all terminal states and preserved sync outcomes passed.'
