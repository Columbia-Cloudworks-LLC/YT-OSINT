[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/queue-ux-'+[guid]::NewGuid().ToString('N'))
$null=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3`nhttps://youtu.be/newDEF12_-3" mo
$adapter=@'
function script:Invoke-CorpusOperation {
    param($Root,$Operation,$Arguments,$Shared,$CorpusLock)
    [IO.File]::AppendAllText((Join-Path $Root 'order.txt'),$Arguments.Url+"`n")
    $ctx=New-CorpusContext $Root $Shared;$deadline=[datetime]::UtcNow.AddSeconds(45)
    while(-not (Test-Path (Join-Path $Root 'release.txt'))){Test-CorpusCancellation $ctx;if([datetime]::UtcNow -gt $deadline){throw 'Queue UX fixture timeout'};Start-Sleep -Milliseconds 50}
    [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
}
'@
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('UxStage')){$state.UxStage=0;$state.UxDeadline=[datetime]::UtcNow.AddSeconds(70)}
    if([datetime]::UtcNow -gt $state.UxDeadline){throw "Queue UX timeout at $($state.UxStage): $($ui.LogText.Text)"}
    if($state.Worker -or $state.QueueView.IsApplying){return}
    function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) disabled"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.UxStage){
        0 {
            $ui.QueueTab.IsSelected=$true;$window.UpdateLayout()
            if($ui.QueueFilters.IsExpanded){throw 'Filters must default to collapsed'}
            if($ui.QueueSelection.Parent -ne $ui.QueueRemove.Parent){throw 'Selection count must sit beside selected-item actions'}
            if($ui.QueueStatus.TranslatePoint([Windows.Point]::new(0,0),$window).Y -le $ui.QueueGrid.TranslatePoint([Windows.Point]::new(0,0),$window).Y){throw 'Statistics must be below the queue'}
            if(-not $ui.CompanyLogo.Source -or -not $ui.AboutVersion.Text.Contains((Get-Content (Join-Path $project VERSION) -Raw).Trim())){throw 'About branding or version missing'}
            $ui.QueueFilters.IsExpanded=$true;$window.UpdateLayout()
            if(-not $ui.QueueBefore.IsVisible){throw 'Expanded date selection is hidden'}
            $ui.QueueFilters.IsExpanded=$false
            Click $ui.QueueToggle;$state.UxStage=1
        }
        1 {
            if(-not @($ui.QueueGrid.Items | Where-Object Status -eq Running).Count){return}
            $state.UxSelected=@($ui.QueueGrid.Items | Where-Object VideoId -eq newDEF12_-3)[0]
            $ui.QueueGrid.SelectedItem=$state.UxSelected
            Click $ui.QueueUp;$state.UxStage=2
        }
        2 {
            if($state.UxSelected.QueueOrder -ne 2){return}
            if(-not [object]::ReferenceEquals($ui.QueueGrid.SelectedItem,$state.UxSelected)){throw 'Reprioritization lost selection'}
            if($ui.QueueGrid.Items[1].VideoId -ne 'newDEF12_-3'){throw 'Queue-order view did not refresh'}
            $column=@($ui.QueueGrid.Columns | Where-Object SortMemberPath -eq Status)[0]
            $ui.QueueGrid.SortColumn($column)
            if($ui.QueueGrid.Items[2].Status -ne 'Running'){throw 'Status sort failed'}
            [IO.File]::WriteAllText((Join-Path $root release.txt),'go');$state.UxStage=3
        }
        3 {
            if($state.QueueWorker -or @($ui.QueueGrid.Items | Where-Object Status -ne Completed).Count){return}
            $order=@(Get-Content (Join-Path $root order.txt))
            if($order.Count -ne 3 -or $order[0] -notmatch 'abcDEF12_-3' -or $order[1] -notmatch 'newDEF12_-3' -or $order[2] -notmatch 'xyzDEF12_-3'){throw 'Scheduler ignored pending priority'}
            if(-not [object]::ReferenceEquals($ui.QueueGrid.SelectedItem,$state.UxSelected)){throw 'Status updates lost selection'}
            if($ui.QueueUp.IsEnabled -or $ui.QueueDown.IsEnabled){throw 'Finished items allow priority edits'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueAdapter $adapter -SmokeQueueCheck $check -UserSettingsPath (Join-Path $root 'fixture-settings.json')
Write-Host 'Queue UX WPF integration passed'
