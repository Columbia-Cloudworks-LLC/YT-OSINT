[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/queue-integration-'+[guid]::NewGuid().ToString('N'))
$ctx=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
# The test adapter holds a download open without contacting YouTube. All queue/storage/GUI code is real.
$adapter=@'
function script:Invoke-CorpusOperation {
    param($Root,$Operation,$Arguments,$Shared,$CorpusLock)
    $ctx=New-CorpusContext $Root $Shared
    [IO.File]::WriteAllText((Join-Path $Root 'started.txt'),'started')
    $deadline=[datetime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path (Join-Path $Root 'release.txt'))){
        Test-CorpusCancellation $ctx
        if([datetime]::UtcNow -gt $deadline){throw 'Queue test adapter timed out.'}
        Start-Sleep -Milliseconds 50
    }
    [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
}
'@
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('QueueTestStage')){$state.QueueTestStage=0;$state.QueueTestStarted=[datetime]::UtcNow}
    if(([datetime]::UtcNow-$state.QueueTestStarted).TotalSeconds -gt 40){throw "Queue GUI test timed out at stage $($state.QueueTestStage). $($ui.LogText.Text)"}
    if($state.Worker){return}
    function Click($button){if(-not $button.IsEnabled){throw "Control $($button.Name) should be enabled."};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.QueueTestStage){
        0 {
            $ui.QueueTab.IsSelected=$true
            $ui.VideoSubject.SelectedItem=$ui.VideoSubject.Items[0]
            $ui.VideoUrl.Text="https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3"
            Click $ui.ImportVideo;$state.QueueTestStage=1
        }
        1 {
            if($state.Queue.Items.Count -ne 2){throw 'Batch did not produce two visible queue items.'}
            if($ui.RenameSubject.IsEnabled){throw 'Queued subject rename was not disabled.'}
            Click $ui.QueueStart;$state.QueueTestStage=2
        }
        2 {
            if(-not (Test-Path (Join-Path $root started.txt))){return}
            if(-not $ui.CreateSubject.IsEnabled -or -not $ui.Search.IsEnabled -or $ui.Build.IsEnabled){throw 'Queue blocked browsing/subject editing or allowed a conflicting export.'}
            $ui.SubjectName.Text='Created during download';Click $ui.CreateSubject;$state.QueueTestStage=3
        }
        3 {
            $new=@($ui.SubjectPick.Items | Where-Object name -eq 'Created during download')
            if($new.Count -ne 1){throw 'Subject creation failed while downloading.'}
            $ui.SubjectPick.SelectedItem=$new[0];$ui.SubjectName.Text='Renamed during download';Click $ui.RenameSubject;$state.QueueTestStage=4
        }
        4 {
            if(-not @((Get-CorpusConfig $root).subjects | Where-Object name -eq 'Renamed during download').Count){throw 'Unrelated subject rename failed.'}
            $ui.VideoUrl.Text='https://youtu.be/newDEF12_-3';Click $ui.ImportVideo;$state.QueueTestStage=5
        }
        5 {
            if($state.Queue.Items.Count -ne 3){throw 'Could not append URLs during a download.'}
            $ui.QueueGrid.SelectedItem=@($ui.QueueGrid.Items | Where-Object VideoId -eq 'xyzDEF12_-3')[0]
            Click $ui.QueueRemove;$state.QueueTestStage=6
        }
        6 {
            if(@($state.Queue.Items | Where-Object VideoId -eq 'xyzDEF12_-3').Count){throw 'Pending item was not removed.'}
            $ui.Query.Text='anything';Click $ui.Search;$state.QueueTestStage=7
        }
        7 {
            if($ui.SearchGrid.Visibility -ne 'Visible'){throw 'Corpus search did not finish while downloading.'}
            Click $ui.QueuePause;$state.QueueTestStage=8
        }
        8 {
            if(-not (Get-CorpusQueue $root).Paused){throw 'Pause request was not persisted.'}
            [IO.File]::WriteAllText((Join-Path $root release.txt),'go');$state.QueueTestStage=9
        }
        9 {
            if($state.QueueWorker){return}
            $q=Get-CorpusQueue $root
            if($q.Items[0].Status -ne 'Completed' -or $q.Items[1].Status -ne 'Pending'){throw 'Pause did not finish exactly one item.'}
            Remove-Item (Join-Path $root release.txt);Remove-Item (Join-Path $root started.txt)
            Click $ui.QueueStart;$state.QueueTestStage=10
        }
        10 {
            if(-not (Test-Path (Join-Path $root started.txt))){return}
            $window.Close();$state.QueueTestStage=11
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeQueueAdapter $adapter
$q=Initialize-CorpusQueue $root
if(-not $q.Paused -or $q.Items[1].Status -ne 'Pending'){throw 'Closing did not preserve the interrupted item for resume.'}
'Queue GUI: batch entry, concurrent subject editing, search, append/remove, pause/resume, and close/recovery passed.'
