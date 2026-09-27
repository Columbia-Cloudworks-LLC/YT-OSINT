[CmdletBinding()]
param([string]$ScreenshotDirectory='')
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/unified-integration-'+[guid]::NewGuid().ToString('N'))
$ctx=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$null=Set-CorpusSubject $root 'Astronomy';$null=Set-CorpusSubject $root 'Technology'
$known=[pscustomobject]@{ChannelId='UC1234567890123456789012';ChannelName='Sample captured channel';Urls=@('https://www.youtube.com/@atmoio');VideosDiscovered=12;TranscriptCount=10;WithoutTranscripts=2;LastSync='2026-09-27T12:00:00Z';LastAttempt='2026-09-27T12:00:00Z';Status='Completed';Failures=0;MembersOnlySkipped=0}
Write-CorpusJson (Join-Path $root "data/normalized/channels/$($known.ChannelId).json") $known
$adapter=@'
function script:Sync-CorpusChannel {
    param($Context,$Url,$SubjectId,$SubjectName,$Run,[switch]$DiscoverOnly)
    if($Url -match 'lessbitter'){
        if((Get-CorpusQueue $Context.Root).SyncJobs[0].Status -notin @('Completed','Cancelled','Partial')){throw 'Second channel started before the first finished.'}
        return [pscustomobject]@{ChannelId='UC2234567890123456789012';Entries=@()}
    }
    [pscustomobject]@{ChannelId='UC1234567890123456789012';Entries=@([pscustomobject]@{id='abcDEF12_-3';title='A shared video'},[pscustomobject]@{id='xyzDEF12_-3';title='A pending video'})}
}
function script:Invoke-CorpusOperation {
    param($Root,$Operation,$Arguments,$Shared,$CorpusLock)
    $ctx=New-CorpusContext $Root $Shared
    [IO.File]::WriteAllText((Join-Path $Root 'started.txt'),'started')
    $deadline=[datetime]::UtcNow.AddSeconds(60)
    while(-not (Test-Path (Join-Path $Root 'release.txt'))){Test-CorpusCancellation $ctx;if([datetime]::UtcNow -gt $deadline){throw 'Timed out'};Start-Sleep -Milliseconds 50}
    [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
}
'@
function Save-UiScreenshot($window,[string]$Name){
    if(-not $ScreenshotDirectory){return}
    $null=[IO.Directory]::CreateDirectory($ScreenshotDirectory);$window.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($window.Content.ActualWidth+$window.Content.Margin.Left+$window.Content.Margin.Right),[int]($window.Content.ActualHeight+$window.Content.Margin.Top+$window.Content.Margin.Bottom),96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create((Join-Path $ScreenshotDirectory "$Name.png"));try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('UnifiedStage')){$state.UnifiedStage=0;$state.UnifiedStart=[datetime]::UtcNow}
    if(([datetime]::UtcNow-$state.UnifiedStart).TotalSeconds -gt 75){throw "Unified GUI timed out at $($state.UnifiedStage): $($ui.LogText.Text)"}
    if($state.Worker){return}
    function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) should be enabled"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.UnifiedStage){
        0 {
            if($ui.SubjectPick.Items[0].name -ne 'Astronomy'){throw 'Default subject sort is not alphabetical'}
            $ui.SubjectPick.SelectedItem=@($ui.SubjectPick.Items | Where-Object id -eq mo)[0]
            $ui.SubjectSort.SelectedIndex=1
            if($ui.SubjectPick.Items[0].name -ne 'Technology' -or $ui.SubjectPick.SelectedItem.id -ne 'mo'){throw 'Reverse sort lost selection'}
            $ui.SubjectSort.SelectedIndex=0
            $ui.VideoUrl.Text="https://youtu.be/abcDEF12_-3`nhttps://youtu.be/newDEF12_-3"
            $state.UnifiedStage=1
        }
        1 {
            Save-UiScreenshot $window subjects
            $ui.Tabs.SelectedIndex=1
            $ui.ChannelsGrid.SelectedItem=@($ui.ChannelsGrid.Items | Where-Object Url -match atmoio)[0]
            if($ui.ChannelsGrid.SelectedItem.DisplayName -ne 'Sample captured channel'){throw 'Captured channel name was not retained'}
            if(-not @($ui.ChannelsGrid.Items | Where-Object DisplayName -eq '@lessbitter (Mo)').Count){throw 'Temporary channel label missing'}
            Click $ui.SyncSelected;$state.UnifiedStage=2
        }
        2 {
            if($ui.SyncSelected.IsEnabled -or $ui.RenameSubject.IsEnabled){throw 'Queued discovery did not lock channel or subject'}
            if($ui.QueueGrid.Items.Count){throw 'Discovery job leaked into video queue'}
            Save-UiScreenshot $window channels
            Click $ui.QueueStart;$state.UnifiedStage=3
        }
        3 {
            if(-not (Test-Path (Join-Path $root started.txt))){return}
            $ui.ChannelsGrid.SelectedItem=@($ui.ChannelsGrid.Items | Where-Object Url -match lessbitter)[0]
            Click $ui.SyncSelected;$state.UnifiedStage=4
        }
        4 {
            if($state.Queue.SyncJobs.Count -ne 2){throw 'Second channel did not queue during active download'}
            if($ui.SyncSelected.IsEnabled){throw 'Queued second channel sync button stayed enabled'}
            $ui.Tabs.SelectedIndex=0;Click $ui.ImportVideo;$state.UnifiedStage=5
        }
        5 {
            if($state.Queue.Items.Count -ne 3){throw 'Batch/channel deduplication failed'}
            if(@($state.Queue.Items | Where-Object SubjectId -ne mo).Count){throw 'Subject changed with channel selection'}
            $ui.Tabs.SelectedIndex=2;$state.UnifiedStage=6
        }
        6 {
            Save-UiScreenshot $window queue
            $ui.Tabs.SelectedIndex=1;$ui.ChannelsGrid.SelectedItem=@($ui.ChannelsGrid.Items | Where-Object Url -match atmoio)[0]
            Click $ui.CancelSync;$state.UnifiedStage=7
        }
        7 {
            $q=Get-CorpusQueue $root
            if($q.Items[0].Status -ne 'Running' -or $q.Items[1].Status -ne 'Cancelled'){throw 'Sync cancellation lost active work or retained a waiting download'}
            if($ui.SyncSelected.IsEnabled){throw 'Channel unlocked before active download finished'}
            [IO.File]::WriteAllText((Join-Path $root release.txt),'go');$state.UnifiedStage=8
        }
        8 {
            if($state.QueueWorker){return}
            $q=Get-CorpusQueue $root
            if($q.SyncJobs[0].Status -ne 'Cancelled' -or $q.SyncJobs[1].Status -ne 'Completed' -or $q.Items[2].Status -ne 'Completed'){throw 'Job completion or batch preservation failed'}
            if(-not $ui.SyncSelected.IsEnabled){throw 'Channel did not unlock on completion'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeQueueAdapter $adapter
'Unified GUI: subject sorting, channel selection, discovery queueing, shared batch downloads, cancellation and unlock passed.'
