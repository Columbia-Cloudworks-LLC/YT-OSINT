[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/priority-ux-'+[guid]::NewGuid().ToString('N'))
$null=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$null=Add-CorpusQueueUrls $root "https://youtu.be/abcDEF12_-3`nhttps://youtu.be/xyzDEF12_-3`nhttps://youtu.be/newDEF12_-3`nhttps://youtu.be/endDEF12_-3" mo
$q=Get-CorpusQueue $root;$q.Items[0].Status='Completed';$q.Items[1].Status='Failed';$q.Items[3].Status='Cancelled'
Write-CorpusJson (Join-Path $root data/queue.json) $q
$script:confirmationCount=0
$confirmation={
    param($dialog)
    $script:confirmationCount++
    $message=$dialog.FindName('Message').Text
    if($message -notmatch 'captured videos and transcripts are kept'){throw 'Confirmation omits capture preservation'}
    if($script:confirmationCount -le 2){
        if($message -notmatch '2 finished rows, including 1 failed and 1 cancelled'){throw 'History counts are wrong'}
    }elseif($message -notmatch '1 pending videos and 0 history rows, and cancel 1'){throw 'Queue confirmation counts are wrong'}
    if($script:confirmationCount % 2 -eq 1){$dialog.DialogResult=$false}else{$dialog.FindName('ConfirmCleanup').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
}
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('PriorityStage')){$state.PriorityStage=0;$state.PriorityDeadline=[datetime]::UtcNow.AddSeconds(75)}
    if([datetime]::UtcNow -gt $state.PriorityDeadline){throw "Priority UX timeout at $($state.PriorityStage): $($ui.LogText.Text)"}
    if($state.Worker -or $state.QueueView.IsApplying){return}
    function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) disabled"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.PriorityStage){
        0 {
            foreach($name in @('ChannelUrl','Query','SearchSubject','SearchChannel','SearchVideo')){if(-not [Windows.Automation.AutomationProperties]::GetName($ui[$name])){throw "Missing accessible name: $name"}}
            $ui.SubjectPick.SelectedItem=@($ui.SubjectPick.Items | Where-Object id -eq mo)[0]
            $ui.VideoUrl.Text='https://youtu.be/newDEF12_-3';Click $ui.ImportVideo;$state.PriorityStage=1
        }
        1 {
            if($ui.OpenQueueFromSubjects.Visibility -ne 'Visible' -or $ui.QueueAddNotice.Text -notmatch '0 videos queued for Mo; 1 duplicates skipped'){throw 'Subject queue feedback missing'}
            Click $ui.OpenQueueFromSubjects
            if(-not $ui.QueueTab.IsSelected -or -not $state.Queue.Paused){throw 'Open queue must navigate without starting work'}
            Click $ui.QueueClear;$state.PriorityStage=2
        }
        2 {
            if($ui.QueueGrid.Items.Count -ne 3){return}
            if(@($ui.QueueGrid.Items | Where-Object Status -in @('Failed','Cancelled')).Count -ne 2){throw 'Routine cleanup removed retryable history'}
            Click $ui.QueueClearHistory
            if($state.Worker -or (Get-CorpusQueue $root).Items.Count -ne 3){throw 'Cancelling history cleanup changed the queue'}
            Click $ui.QueueClearHistory;$state.PriorityStage=3
        }
        3 {
            if($ui.QueueGrid.Items.Count -ne 1){return}
            $ui.Tabs.SelectedIndex=1;$ui.ChannelsGrid.SelectedIndex=0
            Click $ui.SyncSelected;$state.PriorityStage=4
        }
        4 {
            if($ui.OpenQueueFromChannels.Visibility -ne 'Visible' -or $ui.ChannelQueueNotice.Text -notmatch 'Channels queued'){throw 'Channel queue feedback missing'}
            Click $ui.OpenQueueFromChannels;$state.PriorityStage=5
        }
        5 {
            if([Windows.Automation.AutomationProperties]::GetName($ui.QueueToggle) -ne 'List channel videos'){return}
            if(-not $ui.QueueTab.IsSelected -or -not $state.Queue.Paused){throw 'Channel navigation started work'}
            Click $ui.QueueClearAll
            if($state.Worker -or (Get-CorpusQueue $root).Items.Count -ne 1){throw 'Cancelling clear queue changed work'}
            Click $ui.QueueClearAll;$state.PriorityStage=6
        }
        6 {
            if($ui.QueueGrid.Items.Count){return}
            if(-not $state.Queue.Paused -or $ui.QueueToggle.IsEnabled){throw 'Confirmed clear left runnable work'}
            if($script:confirmationCount -ne 4){throw 'Confirmation paths were not exercised'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeQueueConfirmation $confirmation -UserSettingsPath (Join-Path $root fixture-settings.json)
Write-Host 'Priority UX WPF integration passed: navigation, labels, retry preservation, confirmation counts, cancel and confirm.'
