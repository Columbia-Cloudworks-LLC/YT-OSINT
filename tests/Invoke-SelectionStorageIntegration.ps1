[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Settings','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/selection-storage-'+[guid]::NewGuid().ToString('N'))
$null=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$profile=Join-Path $root 'fixture-profile/settings.json'
$destination=$root+'-new'
$null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3`nhttps://youtu.be/newDEF12_-3" mo
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('SelectionStage')){$state.SelectionStage=0;$state.TestDeadline=[datetime]::UtcNow.AddSeconds(60)}
    if([datetime]::UtcNow -gt $state.TestDeadline){throw "Selection/storage test timed out at $($state.SelectionStage): $($ui.LogText.Text)"}
    if($state.Worker){return}
    function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) is disabled"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.SelectionStage){
        0 {
            if($ui.QueueGrid.SelectionMode -ne 'Extended' -or $ui.QueueGrid.SelectionUnit -ne 'FullRow'){throw 'Native extended row selection is not configured'}
            $ui.QueueTab.IsSelected=$true
            $null=$ui.QueueGrid.SelectedItems.Add($ui.QueueGrid.Items[0]);$null=$ui.QueueGrid.SelectedItems.Add($ui.QueueGrid.Items[2])
            $state.SelectedIds=@($ui.QueueGrid.SelectedItems | ForEach-Object {$_.Id})
            $ui.SubjectName.Text='Unsaved subject draft'
            $q=Get-CorpusQueue $root;$q.Items[1].Detail='Background progress update';Write-CorpusJson (Join-Path $root data/queue.json) $q
            $state.SelectionStage=1
        }
        1 {
            if($ui.QueueGrid.Items[1].Detail -ne 'Background progress update'){return}
            if($ui.QueueGrid.SelectedItems.Count -ne 2 -or @($ui.QueueGrid.SelectedItems | Where-Object {$_.Id -notin $state.SelectedIds}).Count){throw 'Background refresh lost the multi-selection'}
            if($ui.SubjectName.Text -ne 'Unsaved subject draft'){throw 'Progress refresh erased a subject-name draft'}
            if($ui.QueueSelection.Text -notmatch '2 selected.*2 pending'){throw 'Selection count is incorrect'}
            Click $ui.QueueRemove;$state.SelectionStage=2
        }
        2 {
            if($ui.QueueGrid.Items.Count -ne 1){throw 'Bulk removal did not preserve only the unselected item'}
            $ui.SettingsTab.IsSelected=$true;$ui.StorageTab.IsSelected=$true
            $ui.StaleDays.Text='12';Click $ui.SaveStorage;$state.SelectionStage=3
        }
        3 {
            if((Get-CorpusUserSettings $profile).StaleDays -ne 12){throw "Freshness was not saved to the fixture profile: $($ui.LogText.Text) $($ui.StorageNotice.Text)"}
            if($state.RestartRequired){throw 'Freshness-only changes should apply immediately'}
            $ui.StorageRoot.Text=$destination;$ui.StorageSwitch.IsChecked=$true;Click $ui.SaveStorage;$state.SelectionStage=4
        }
        4 {
            if(-not $state.RestartRequired -or $ui.StorageRestart.Visibility -ne 'Visible' -or $ui.QueueToggle.IsEnabled){throw 'Location change did not require a safe restart'}
            if((Get-CorpusUserSettings $profile).CorpusRoot -ne $destination){throw 'New location was not saved'}
            if(@((Get-CorpusConfig $destination).subjects).Count){throw 'Switch copied the old corpus unexpectedly'}
            if((Get-CorpusQueue $root).Items.Count -ne 1){throw 'Switch changed the original queue'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -UserSettingsPath $profile
'Selection and storage GUI: multi-selection retention, bulk removal, profile preferences and safe switching passed.'

$moveDestination=$root+'-moved'
$moveCheck={
    param($window,$ui,$state)
    if($state.Worker){return}
    if(-not $state.ContainsKey('MoveStarted')){
        $state.MoveStarted=$true;$state.MoveDeadline=[datetime]::UtcNow.AddSeconds(60)
        $ui.SettingsTab.IsSelected=$true;$ui.StorageTab.IsSelected=$true
        $ui.StorageRoot.Text=$moveDestination;$ui.StorageMove.IsChecked=$true
        $ui.SaveStorage.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
        return
    }
    if(-not $state.RestartRequired){throw "GUI move failed: $($ui.StorageNotice.Text)"}
    if((Get-CorpusQueue $moveDestination).Items.Count -ne 1){throw 'GUI move lost the pending queue'}
    if((Get-CorpusConfig $moveDestination).subjects[0].id -ne 'mo'){throw 'GUI move lost the subject'}
    $window.Close()
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $moveCheck -UserSettingsPath $profile
$ticket=Start-CorpusRestart $moveDestination -SmokeTest
try {
    [IO.File]::WriteAllText($ticket.SignalPath,'ready')
    if(-not $ticket.Process.WaitForExit(30000)){throw 'Restart into the moved corpus timed out'}
    if($ticket.Process.ExitCode -ne 0){throw 'Restart into the moved corpus failed'}
    if((Get-CorpusQueue $moveDestination).Items.Count -ne 1 -or -not (Get-CorpusQueue $moveDestination).Paused){throw 'Restart lost or resumed pending work'}
} finally {if(-not $ticket.Process.HasExited){$ticket.Process.Kill()};$ticket.Process.Dispose()}
'GUI move and restart: subject and pending queue preserved, startup paused.'
