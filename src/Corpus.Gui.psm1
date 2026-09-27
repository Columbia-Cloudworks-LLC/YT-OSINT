Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'Corpus.Viewer.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'Corpus.Queue.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'Corpus.Icons.psm1') -Force -Global
Import-Module (Join-Path $PSScriptRoot 'Corpus.Settings.psm1') -Force -Global
function Start-CorpusRestart {
    param([string]$Root,[switch]$SmokeTest)
    $signal=Join-Path $Root ('logs/restart-'+[guid]::NewGuid().ToString('N')+'.ready')
    $arguments=@('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',(Join-Path (Split-Path $PSScriptRoot -Parent) 'YouTubeCorpus.ps1'),'-Root',$Root,'-OpenDependencies','-RestartSignal',$signal)
    if($SmokeTest){$arguments+=@('-SmokeTest','-SkipDependencies')}
    $quoted=($arguments | ForEach-Object {[YouTubeCorpus.ProcessRunner]::Quote($_)}) -join ' '
    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput ($signal+'.out.log') -RedirectStandardError ($signal+'.error.log') -ErrorAction Stop
    $null=$process.Handle
    if($process.WaitForExit(300)){$process.Dispose();throw 'Could not restart YT-OSINT. Close and reopen the application.'}
    return [pscustomobject]@{Process=$process;SignalPath=$signal}
}
function Show-CorpusSubjectPrompt {
    param($Owner,[string]$SmokeName='',[switch]$SmokeCancel)
    [xml]$layout=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Add subject" Width="420" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="14">
<StackPanel Margin="20"><TextBlock Text="Subject name"/><TextBox x:Name="NameInput" Margin="0,10" Padding="8"/><TextBlock x:Name="ErrorText" Foreground="#A02020" TextWrapping="Wrap"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right"><Button x:Name="SaveName" Content="Add subject" IsDefault="True" Padding="14,7" Margin="4"/><Button Content="Cancel" IsCancel="True" Padding="14,7" Margin="4"/></StackPanel></StackPanel></Window>
'@
    $dialog=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout));if($Owner){$dialog.Owner=$Owner}
    $nameBox=$dialog.FindName('NameInput');$save=$dialog.FindName('SaveName');$errorText=$dialog.FindName('ErrorText')
    $save.Add_Click({if([string]::IsNullOrWhiteSpace($nameBox.Text)){$errorText.Text='Enter a subject name.';return};$dialog.DialogResult=$true})
    $dialog.Add_ContentRendered({$null=$nameBox.Focus();if($SmokeCancel){$dialog.DialogResult=$false}elseif($SmokeName){$nameBox.Text=$SmokeName;$save.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}})
    if($dialog.ShowDialog() -eq $true){return $nameBox.Text.Trim()}
    return $null
}
function Show-CorpusWindow {
    param([string]$Root,[switch]$SkipDependencies,[switch]$SmokeTest,[string]$ScreenshotPath='',[switch]$SmokeCheckDependencies,[switch]$OpenDependencies,[switch]$SmokeCorpus,[scriptblock]$SmokeGridCheck,[scriptblock]$SmokeQueueCheck,[string]$SmokeQueueAdapter='',[scriptblock]$SmokeSubjectPrompt,[switch]$SmokeConfirmRemoval,[string]$UserSettingsPath=(Get-CorpusUserSettingsPath))
    $appRoot=Split-Path $PSScriptRoot -Parent
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml=Get-Content (Join-Path $PSScriptRoot 'Corpus.Gui.xaml') -Raw -Encoding UTF8
    $reader=[Xml.XmlNodeReader]::new($xaml);$window=[Windows.Markup.XamlReader]::Load($reader)
    $ns=[Xml.XmlNamespaceManager]::new($xaml.NameTable)
    $ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml')
    $ui=@{}
    foreach($node in $xaml.SelectNodes('//*[@x:Name]',$ns)) {
        $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        $ui[$name]=$window.FindName($name)
    }
    foreach($entry in @{OpenTranscript='Transcript';OpenResult='YouTube';OpenWorkbook='Excel';Build='Export'}.GetEnumerator()){Set-CorpusButtonIcon $ui[$entry.Key] $entry.Value}
    $state=@{Worker=$null;Handle=$null;Shared=$null;Operation='';Snapshot=$null;Ready=[bool]$SkipDependencies;Closing=$false;PendingSubject='';SmokeTicks=0;LastOutcome='Ready';CheckedStartup=(([bool]$SkipDependencies -or [bool]$SmokeTest) -and -not $SmokeCheckDependencies);RestartRequired=$false;RestartTicket=$null;DependencyRows=@();SmokeStage=0;ViewerVerified=$false;SmokeError='';QueueWorker=$null;QueueHandle=$null;QueueShared=$null;Queue=(Initialize-CorpusQueue $Root);QueueStamp='';SelectCreatedSubject=$false;QueueTicks=0;NeedsRefresh=$false}
    $mutators=@('CreateSubject','RemoveSubject','RenameSubject','AddChannel','RemoveChannel','SyncSelected','SyncAll','Refresh','CancelSync','ImportVideo','Build','Search','FilterCorpus','RefreshChannelTranscripts','RefreshVideoTranscript','OpenTranscript','AutoExport','QueueStart','QueuePause','QueueRemove','QueueRetry','QueueClear')
    $ui.Paths.Text="Current corpus folder: $Root`nWorkbook: $(Join-Path $Root 'output/YouTubeCorpus.xlsx')`nSource configuration: $(Join-Path $Root 'config.json')`nNative dependencies: $(Get-CorpusNativeRoot)"
    $state.Preferences=Get-CorpusUserSettings $UserSettingsPath
    $state.RestartRoot=$Root
    $ui.StorageRoot.Text=$Root;$ui.StaleDays.Text=[string]$state.Preferences.StaleDays
    function Update-StoragePreview {
        $ui.StoragePreview.Text="Proposed paths:`nConfiguration: $($ui.StorageRoot.Text)\config.json`nCaptures and queue: $($ui.StorageRoot.Text)\data`nWorkbook: $($ui.StorageRoot.Text)\output\YouTubeCorpus.xlsx`nLogs: $($ui.StorageRoot.Text)\logs"
    }
    $ui.StorageRoot.Add_TextChanged({Update-StoragePreview});Update-StoragePreview
    $ui.BrowseStorage.Add_Click({
        Add-Type -AssemblyName System.Windows.Forms
        $dialog=[Windows.Forms.FolderBrowserDialog]::new();$dialog.Description='Select a corpus folder';$dialog.SelectedPath=$ui.StorageRoot.Text
        try{if($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK){$ui.StorageRoot.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}
    })
    $ui.CancelStorage.Add_Click({$ui.StorageRoot.Text=$state.RestartRoot;$ui.StaleDays.Text=[string]$state.Preferences.StaleDays;$ui.StorageSwitch.IsChecked=$true})
    $ui.SaveStorage.Add_Click({
        $days=0
        if(-not [int]::TryParse($ui.StaleDays.Text,[ref]$days) -or $days -lt 1 -or $days -gt 3650){Show-UiError 'Enter a whole number of days between 1 and 3650.';return}
        Start-Work 'Storage' @{Destination=$ui.StorageRoot.Text;Mode=$(if($ui.StorageMove.IsChecked){'Move'}else{'Switch'});StaleDays=$days;SettingsPath=$UserSettingsPath}
    })
    $ui.StorageRestart.Add_Click({Restart-Application})
    $dependencySettings=Get-CorpusDependencySettings $Root
    $ui.DependencyChannel.SelectedIndex=if($dependencySettings.YtDlpChannel -eq 'nightly'){1}else{0}
    function Get-SelectedSyncJob {
        $c=$ui.ChannelsGrid.SelectedItem
        if($c){return ($state.Queue.SyncJobs | Where-Object {$_.Url -eq $c.Url -or ($c.ChannelId -and $_.ChannelId -eq $c.ChannelId)} | Select-Object -Last 1)}
    }
    function Show-ChannelDetails {
        $c=$ui.ChannelsGrid.SelectedItem;$job=Get-SelectedSyncJob
        $active=$job -and $job.Status -in @('Pending','Discovering','Downloading','Cancelling')
        $available=(-not $state.Worker -and $state.Ready -and -not $state.RestartRequired -and -not $state.Closing)
        $ui.SyncSelected.IsEnabled=($available -and [bool]$c -and -not $active)
        $ui.CancelSync.IsEnabled=($available -and $active -and $job.Status -ne 'Cancelling')
        $ui.ChannelHeading.Text=if($c){$c.DisplayName}else{'Select a channel'}
        $ui.ChannelSyncStatus.Text=if($job){"$(if(Get-CorpusProperty $job PartialImport $false){'Partial channel import · '})$(if($job.Status -eq 'Pending'){'Queued'}else{$job.Status}) — $(if($job.Status -eq 'Downloading'){$children=@($state.Queue.Items | Where-Object {$job.Id -in $_.JobIds});"$(@($children | Where-Object Status -eq Pending).Count) pending; $(@($children | Where-Object Status -eq Running).Count) active"}else{$job.Detail})"}else{'Queue a sync to discover videos and download their transcripts.'}
        $ui.ChannelDetails.ItemsSource=@(if($c){foreach($field in @('Subject','ChannelName','ChannelId','Url','VideosDiscovered','WithTranscripts','WithoutTranscripts','LastSuccessfulSync','LastAttempt','Status')){[pscustomobject]@{Field=($field -creplace '([a-z])([A-Z])','$1 $2');Value=$c.$field}}})
    }
    function Update-SubjectLock {
        $selected=$ui.SubjectPick.SelectedItem
        $locked=$selected -and (Test-CorpusSubjectQueued $Root $selected.id)
        $canEdit=(-not $state.Worker -and $state.Ready -and -not $state.RestartRequired -and [bool]$selected)
        $ui.RenameSubject.IsEnabled=($canEdit -and -not $locked);$ui.RemoveSubject.IsEnabled=($canEdit -and -not $locked -and -not $state.QueueWorker)
        $ui.ImportVideo.IsEnabled=$canEdit;$ui.AddChannel.IsEnabled=$canEdit;$ui.RemoveChannel.IsEnabled=$canEdit;$ui.SubjectName.IsEnabled=$canEdit;$ui.ChannelUrl.IsEnabled=$canEdit
        if($selected -and $ui.SubjectChannels.SelectedItem){$url=$ui.SubjectChannels.SelectedItem.Url;$channelLocked=@($state.Queue.SyncJobs | Where-Object {$_.SubjectId -eq $selected.id -and $_.Url -eq $url -and $_.Status -in @('Pending','Discovering','Downloading','Cancelling')}).Count -gt 0;$ui.RemoveChannel.IsEnabled=($canEdit -and -not $channelLocked)}
        $ui.SubjectLockNotice.Text=if($locked){'🔒 This subject has queued work. Renaming and removal are locked until those items finish or are removed.'}elseif($state.QueueWorker){'Pause the queue and let the current item finish before removing subjects.'}else{''}
    }
    function Update-QueueButtons {
        $available=(-not $state.Worker -and -not $state.Closing -and $state.Ready -and -not $state.RestartRequired)
        $selected=$ui.QueueGrid.SelectedItem
        $pendingSelected=@($ui.QueueGrid.SelectedItems | Where-Object Status -eq Pending).Count
        $ui.QueueSelection.Text="$($ui.QueueGrid.SelectedItems.Count) selected · $pendingSelected pending"
        $ui.QueueRemove.IsEnabled=($available -and $pendingSelected -gt 0)
        $ui.QueueRetry.IsEnabled=($available -and $ui.QueueGrid.SelectedItems.Count -eq 1 -and $selected -and $selected.Status -in @('Failed','Cancelled'))
        $ui.QueueClear.IsEnabled=($available -and @($state.Queue.Items | Where-Object {$_.Status -notin @('Pending','Running')}).Count -gt 0)
        $ui.QueueStart.IsEnabled=($available -and -not $state.QueueWorker -and (@($state.Queue.Items | Where-Object Status -eq Pending).Count + @($state.Queue.SyncJobs | Where-Object Status -eq Pending).Count) -gt 0)
        $ui.QueuePause.IsEnabled=($available -and [bool]$state.QueueWorker -and -not $state.Queue.Paused)
        $ui.QueueCancel.IsEnabled=([bool]$state.QueueWorker -and -not $state.QueueShared.Cancel)
    }
    function Refresh-QueueView {
        $selected=@{};foreach($item in $ui.QueueGrid.SelectedItems){$selected[$item.Id]=$true}
        $queueFile=Get-Item (Join-Path $Root 'data/queue.json') -ErrorAction SilentlyContinue
        $state.QueueStamp=if($queueFile){$queueFile.LastWriteTimeUtc.Ticks.ToString()}else{''}
        $state.Queue=Get-CorpusQueue $Root
        $ui.QueueGrid.ItemsSource=@($state.Queue.Items)
        foreach($item in $state.Queue.Items){if($selected.ContainsKey($item.Id)){$null=$ui.QueueGrid.SelectedItems.Add($item)}}
        $pending=@($state.Queue.Items | Where-Object Status -eq Pending).Count
        $active=@($state.Queue.Items | Where-Object Status -eq Running).Count
        $ui.QueueStatus.Text="$(if($state.Queue.Paused){'Paused'}else{'Running'}) | $pending pending | $active active | $(@($state.Queue.SyncJobs | Where-Object Status -in @('Pending','Discovering','Downloading','Cancelling')).Count) channel syncs"
        Update-StatusIndicators;Update-SubjectLock;Update-QueueButtons;Show-ChannelDetails
    }
    function Set-Busy([bool]$Busy) {
        foreach($name in $mutators){$ui[$name].IsEnabled=(-not $Busy -and $state.Ready -and -not $state.RestartRequired)}
        foreach($name in @('CheckDependencies','UpdateDependencies','RecoverDependencies','DependencyChannel','DependenciesGrid')){$ui[$name].IsEnabled=(-not $Busy)}
        $ui.RestartApplication.IsEnabled=(-not $Busy);$ui.RestartApplication.Visibility=if($state.RestartRequired){'Visible'}else{'Collapsed'}
        if($state.QueueWorker){foreach($name in @('Build','CheckDependencies','UpdateDependencies','RecoverDependencies','DependencyChannel','DependenciesGrid','RestartApplication','QueueStart')){$ui[$name].IsEnabled=$false}}
        foreach($name in @('SaveStorage','BrowseStorage','StorageRoot','StorageMove','StorageSwitch','StaleDays','CancelStorage')){$ui[$name].IsEnabled=(-not $Busy -and -not $state.QueueWorker -and -not $state.RestartRequired)}
        $ui.StorageRestart.IsEnabled=(-not $Busy -and -not $state.QueueWorker)
        $ui.QueuePause.IsEnabled=(-not $Busy -and [bool]$state.QueueWorker)
        $ui.QueueCancel.IsEnabled=([bool]$state.QueueWorker -and -not $state.QueueShared.Cancel)
        $ui.Cancel.IsEnabled=$Busy -and $state.Operation -notin @('Bootstrap','RecoverDependencies','Storage')
        Update-SubjectLock;Update-QueueButtons;Show-ChannelDetails
    }
    function Get-DependencyChannel {return [string]$ui.DependencyChannel.SelectedItem.Content}
    function Set-DependencyRows($Rows) {
        $state.DependencyRows=@($Rows)
        foreach($row in $state.DependencyRows){$row | Add-Member NoteProperty Selected $false -Force}
        $ui.DependenciesGrid.ItemsSource=$state.DependencyRows
        $available=@($Rows | Where-Object CanUpdate).Count
        $ui.DependencyNotice.Text=if($state.RestartRequired){"Maintenance finished. Restart YT-OSINT before resuming imports or workbook builds. $available install/update options remain."}else{"$available dependencies have install/update options. Select the checkboxes and review the changes before installation."}
    }
    function Start-Work([string]$Operation,$Arguments=@{}) {
        if($state.Worker){return}
        if($Operation -in @('SyncAll','SyncChannel','Video')){$Arguments.SkipWorkbook=(-not [bool]$ui.AutoExport.IsChecked)}
        if($Operation -eq 'Search'){$state.SearchText=$Arguments.Text}
        if($Operation -eq 'Subject'){$state.SelectCreatedSubject=(-not $Arguments.Id)}
        if($Operation -eq 'QueueAdd'){$state.QueuedInput=$Arguments.Text}
        $state.Operation=$Operation;$state.Shared=[hashtable]::Synchronized(@{Cancel=$false;CommitInProgress=$false;DependenciesChanged=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
        $ps=[powershell]::Create()
        $null=$ps.AddScript({param($root,$op,$argsMap,$shared,$codeRoot)
            $ErrorActionPreference='Stop'
            foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Settings')){Import-Module (Join-Path $codeRoot "src/Corpus.$name.psm1") -Force -Global}
            if($op -eq 'Bootstrap') {
                & (Join-Path $codeRoot 'Install-Dependencies.ps1') -Root $root -ProgressPath (Join-Path $root 'logs/bootstrap-progress.txt')
                return 'Dependencies ready'
            }
            if($op -in @('CheckDependencies','UpdateDependencies','RecoverDependencies')) {
                $ctx=New-CorpusContext $root $shared
                switch($op){
                    'CheckDependencies' {return @(Get-CorpusDependencyStatus $ctx $argsMap.Channel -Force:([bool]$argsMap.Force))}
                    'UpdateDependencies' {return @(Invoke-CorpusDependencyUpdate $ctx $argsMap.Selection $argsMap.Channel)}
                    'RecoverDependencies' {return Repair-CorpusDependencies $ctx}
                }
            }
            if($op -eq 'Storage'){return Save-CorpusStorageSettings $root $argsMap.Destination $argsMap.Mode $argsMap.StaleDays -SettingsPath $argsMap.SettingsPath -Shared $shared}
            if($op -eq 'QueueRemove'){return Remove-CorpusQueueItems $root $argsMap.Ids}
            if($op -eq 'SyncAdd'){foreach($source in $argsMap.Sources){$null=Add-CorpusSyncJob $root $source.Url $source.SubjectId -RefreshTranscript:([bool]$argsMap.RefreshTranscript) -ExportWorkbook:([bool]$argsMap.ExportWorkbook)};return}
            if($op -eq 'SyncCancel'){Stop-CorpusSyncJob $root $argsMap.Id;return}
            if($op -eq 'QueueAdd'){return Add-CorpusQueueUrls $root $argsMap.Text $argsMap.SubjectId -RefreshTranscript:([bool]$argsMap.RefreshTranscript) -ExportWorkbook:([bool]$argsMap.ExportWorkbook)}
            if($op -eq 'QueueAction'){Update-CorpusQueue $root $argsMap.Action $argsMap.Id;return}
            if($op -eq 'Transcript') {
                if($argsMap.VideoId -notmatch '^[A-Za-z0-9_-]{11}$'){throw 'Invalid video ID.'}
                $video=Read-CorpusJson (Join-Path $root "data/normalized/videos/$($argsMap.VideoId).json")
                if(-not $video){throw 'Video record is no longer available. Refresh the corpus.'}
                [pscustomobject]@{Video=$video;Rows=@(Get-CorpusTranscript $root $video);Query=$argsMap.Query;SegmentId=$argsMap.SegmentId}
            } elseif($op -eq 'Filter') {
                @(Get-CorpusVideos $root | Where-Object {
                    ($_.SubjectName+' '+$_.ChannelName+' '+$_.VideoTitle+' '+$_.VideoId+' '+$_.LastSyncStatus).IndexOf($argsMap.Text,[StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                    (-not $argsMap.Subject -or $_.SubjectId -eq $argsMap.Subject) -and
                    (-not $argsMap.Channel -or ($_.ChannelName+' '+$_.ChannelId).IndexOf($argsMap.Channel,[StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                    (-not $argsMap.Video -or ($_.VideoTitle+' '+$_.VideoId).IndexOf($argsMap.Video,[StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                    (-not $argsMap.From -or ($_.PublishedDate -and [datetime]$_.PublishedDate -ge [datetime]$argsMap.From)) -and
                    (-not $argsMap.To -or ($_.PublishedDate -and [datetime]$_.PublishedDate -lt ([datetime]$argsMap.To).AddDays(1)))
                } | Select-Object SubjectName,ChannelName,VideoTitle,VideoId,PublishedDate,Duration,TranscriptAvailable,SubtitleSource,LastSyncStatus,VideoUrl)
            } else {Invoke-CorpusOperation $root $op $argsMap $shared}
        }).AddArgument($Root).AddArgument($Operation).AddArgument($Arguments).AddArgument($state.Shared).AddArgument($appRoot)
        $state.Worker=$ps;$state.Handle=$ps.BeginInvoke();Set-Busy $true
        $ui.Status.Text=$Operation;$ui.Progress.IsIndeterminate=$true
    }
    function Show-SubjectChannels {
        $previousUrl=if($ui.SubjectChannels.SelectedItem){$ui.SubjectChannels.SelectedItem.Url}else{''}
        $selected=$ui.SubjectPick.SelectedItem
        if($selected){$ui.SubjectName.Text=$selected.name;$ui.SubjectHeading.Text=$selected.name;$ui.SubjectChannels.ItemsSource=@($ui.ChannelsGrid.Items | Where-Object SubjectId -eq $selected.id | Select-Object Url,StatusLabel,LastSuccessfulSync)}else{$ui.SubjectName.Clear();$ui.SubjectHeading.Text='Select or add a subject';$ui.SubjectChannels.ItemsSource=@()}
        foreach($row in $ui.SubjectChannels.Items){if($row.Url -eq $previousUrl){$ui.SubjectChannels.SelectedItem=$row;break}}
        Update-SubjectLock
    }
    function Update-StatusIndicators {
        $draft=$ui.SubjectName.Text;$draftSubject=if($ui.SubjectPick.SelectedItem){$ui.SubjectPick.SelectedItem.id}else{''}
        foreach($row in $ui.ChannelsGrid.Items){
            $job=$state.Queue.SyncJobs | Where-Object {$_.Url -eq $row.Url -or ($row.ChannelId -and $_.ChannelId -eq $row.ChannelId)} | Select-Object -Last 1
            $indicator=Get-CorpusChannelIndicator $row $job $state.Queue $state.Preferences.StaleDays
            $row | Add-Member NoteProperty StatusLabel $indicator.Label -Force
            $row | Add-Member NoteProperty StatusHint $indicator.Hint -Force
            $row | Add-Member NoteProperty Freshness $indicator.Freshness -Force
        }
        $ui.ChannelsGrid.Items.Refresh()
        foreach($subject in $ui.SubjectPick.Items){
            $jobs=@($state.Queue.SyncJobs | Where-Object {$_.SubjectId -eq $subject.id -and $_.Status -in @('Pending','Discovering','Downloading','Cancelling')})
            $videos=@($state.Queue.Items | Where-Object {$_.SubjectId -eq $subject.id -and $_.Status -in @('Pending','Running')})
            $channels=@($ui.ChannelsGrid.Items | Where-Object SubjectId -eq $subject.id)
            $stale=@($channels | Where-Object Freshness -eq Stale).Count
            $fresh=@($channels | Where-Object Freshness -eq 'Up to date').Count
            $label="✓ $fresh up to date · ◷ $stale stale"
            if($jobs.Count -or $videos.Count){$activeCount=@($videos | Where-Object Status -eq Running).Count+@($jobs | Where-Object Status -eq Discovering).Count;$label="🔒 ↻ $activeCount active · $($jobs.Count) channel jobs · $($videos.Count) queued videos · $label"}
            $subject | Add-Member NoteProperty StatusLabel $label -Force
        }
        $ui.SubjectPick.Items.Refresh()
        Show-SubjectChannels
        if($ui.SubjectPick.SelectedItem -and $ui.SubjectPick.SelectedItem.id -eq $draftSubject){$ui.SubjectName.Text=$draft}
    }
    function Set-Snapshot($Snapshot) {
        $subjectDraft=$ui.SubjectName.Text
        $oldSubjectName=if($ui.SubjectPick.SelectedItem){$ui.SubjectPick.SelectedItem.name}else{''}
        $state.Snapshot=$Snapshot
        $subjectId=if($state.ContainsKey('PendingSubjectId') -and $state.PendingSubjectId){$state.PendingSubjectId}elseif($ui.SubjectPick.SelectedItem){$ui.SubjectPick.SelectedItem.id}else{''}
        $searchId=if($ui.SearchSubject.SelectedItem){$ui.SearchSubject.SelectedItem.id}else{''}
        $ui.SubjectPick.ItemsSource=@($Snapshot.Config.subjects | Sort-Object name -Descending:($ui.SubjectSort.SelectedIndex -eq 1))
        $ui.SearchSubject.ItemsSource=@(foreach($s in $Snapshot.Config.subjects){[pscustomobject]@{id=$s.id;DisplayName=$s.name}};foreach($s in $Snapshot.Config.archivedSubjects){[pscustomobject]@{id=$s.id;DisplayName=($s.name+' (archived)')}})
        foreach($s in $Snapshot.Config.subjects){if($s.id -eq $subjectId){$ui.SubjectPick.SelectedItem=$s};if($s.id -eq $searchId){$ui.SearchSubject.SelectedItem=@($ui.SearchSubject.Items | Where-Object id -eq $searchId)[0]}}
        foreach($s in $Snapshot.Config.archivedSubjects){if($s.id -eq $searchId){$ui.SearchSubject.SelectedItem=@($ui.SearchSubject.Items | Where-Object id -eq $searchId)[0]}}
        $state.PendingSubject='';$state.PendingSubjectId=''
        if(-not $ui.SubjectPick.SelectedItem -and $Snapshot.Config.subjects.Count){$ui.SubjectPick.SelectedIndex=0}
        $channelRows=@(foreach($s in $Snapshot.Config.subjects){foreach($c in $s.channels){
            $known=@($Snapshot.Channels | Where-Object {$c.url -in $_.Urls});$attempt=@($Snapshot.Attempts | Where-Object Url -eq $c.url)
            if($known.Count){$k=$known[0];[pscustomobject]@{Subject=$s.name;ChannelName=$k.ChannelName;ChannelId=$k.ChannelId;Url=$c.url;VideosDiscovered=$k.VideosDiscovered;WithTranscripts=$k.TranscriptCount;WithoutTranscripts=$k.WithoutTranscripts;LastSuccessfulSync=$k.LastSync;LastAttempt=$(if($attempt.Count){$attempt[0].LastAttempt}else{$k.LastAttempt});Status=$(if($attempt.Count){$attempt[0].Status}else{$k.Status})}}
            else{[pscustomobject]@{Subject=$s.name;ChannelName='';ChannelId='';Url=$c.url;VideosDiscovered=0;WithTranscripts=0;WithoutTranscripts=0;LastSuccessfulSync='';LastAttempt=$(if($attempt.Count){$attempt[0].LastAttempt}else{''});Status=$(if($attempt.Count){$attempt[0].Status}else{'Not imported'})}}
        }})
        $selectedUrl=if($ui.ChannelsGrid.SelectedItem){$ui.ChannelsGrid.SelectedItem.Url}else{''}
        foreach($row in $channelRows){
            $owner=@($Snapshot.Config.subjects | Where-Object name -eq $row.Subject)[0]
            $row | Add-Member NoteProperty SubjectId $owner.id
            $label=if($row.ChannelName){$row.ChannelName}else{([uri]::UnescapeDataString(([uri]$row.Url).AbsolutePath.Trim('/')))+" ($($row.Subject))"}
            $row | Add-Member NoteProperty DisplayName $label
        }
        $ui.ChannelsGrid.ItemsSource=@($channelRows | Sort-Object DisplayName)
        foreach($row in $ui.ChannelsGrid.Items){if($row.Url -eq $selectedUrl){$ui.ChannelsGrid.SelectedItem=$row;break}}
        if(-not $ui.ChannelsGrid.SelectedItem -and $channelRows.Count){$ui.ChannelsGrid.SelectedIndex=0}
        Update-StatusIndicators;Show-ChannelDetails
        $ui.CorpusGrid.ItemsSource=@($Snapshot.Videos | Select-Object SubjectName,ChannelName,VideoTitle,VideoId,PublishedDate,Duration,TranscriptAvailable,SubtitleSource,LastSyncStatus,VideoUrl)
        Show-SubjectChannels
        if($ui.SubjectPick.SelectedItem -and $ui.SubjectPick.SelectedItem.id -eq $subjectId -and -not $state.SelectCreatedSubject -and $subjectDraft -ne $oldSubjectName){$ui.SubjectName.Text=$subjectDraft}
        $state.SelectCreatedSubject=$false
    }
    function Show-UiError($Message){$ui.Status.Text=$Message;$ui.LogText.AppendText("ERROR: $Message`r`n");[Windows.MessageBox]::Show($window,$Message,'YT-OSINT','OK','Warning') | Out-Null}
    function Get-SelectedSubject {if(-not $ui.SubjectPick.SelectedItem){throw 'Select a subject first.'};return $ui.SubjectPick.SelectedItem}
    $ui.CheckDependencies.Add_Click({Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$true}})
    $ui.DependencyChannel.Add_SelectionChanged({
        $state.DependencyRows=@();$ui.DependenciesGrid.ItemsSource=@()
        $ui.DependencyNotice.Text='Channel changed. Press Check now to review available releases.'
    })
    $ui.UpdateDependencies.Add_Click({
        $null=$ui.DependenciesGrid.CommitEdit()
        $selection=@($state.DependencyRows | Where-Object {$_.Selected -and $_.CanUpdate})
        if(-not $selection.Count){Show-UiError 'Select at least one available update.';return}
        $label=if($selection.Count -eq 1){'dependency'}else{'dependencies'}
        $review="Update $($selection.Count) ${label}?`r`n`r`nYT-OSINT will restart when the updates are complete."
        if([Windows.MessageBox]::Show($window,$review,'Update dependencies','YesNo','Question') -eq 'Yes'){
            Start-Work 'UpdateDependencies' @{Selection=$selection;Channel=(Get-DependencyChannel)}
        }
    })
    function Restart-Application {
        try {$state.RestartTicket=Start-CorpusRestart $state.RestartRoot;$window.Close()}
        catch {Show-UiError $_.Exception.Message}
    }
    $ui.RestartApplication.Add_Click({Restart-Application})
    $ui.RecoverDependencies.Add_Click({Start-Work 'RecoverDependencies'})
    $ui.SubjectChannels.Add_SelectionChanged({Update-SubjectLock})
    $ui.SubjectPick.Add_SelectionChanged({Show-SubjectChannels})
    $ui.CreateSubject.Add_Click({
        $name=if($SmokeTest -and $SmokeSubjectPrompt){& $SmokeSubjectPrompt $window}else{Show-CorpusSubjectPrompt $window}
        if($name){Start-Work 'Subject' @{Name=$name;Id=''}}
    })
    $ui.RemoveSubject.Add_Click({try{
        $s=Get-SelectedSubject
        if(($SmokeTest -and $SmokeConfirmRemoval) -or [Windows.MessageBox]::Show($window,"Remove '$($s.name)' from subjects?`n`nCaptured videos and transcripts will be preserved.",'Remove subject','YesNo','Question') -eq 'Yes'){Start-Work 'RemoveSubject' @{Id=$s.id}}
    }catch{Show-UiError $_.Exception.Message}})
    $ui.RenameSubject.Add_Click({try{$s=Get-SelectedSubject;Start-Work 'Subject' @{Name=$ui.SubjectName.Text;Id=$s.id}}catch{Show-UiError $_.Exception.Message}})
    $ui.AddChannel.Add_Click({try{$s=Get-SelectedSubject;Start-Work 'Associate' @{SubjectId=$s.id;Url=$ui.ChannelUrl.Text.Trim();Remove=$false}}catch{Show-UiError $_.Exception.Message}})
    $ui.RemoveChannel.Add_Click({try{$s=Get-SelectedSubject;if(-not $ui.SubjectChannels.SelectedItem){throw 'Select a channel association to remove.'};Start-Work 'Associate' @{SubjectId=$s.id;Url=$ui.SubjectChannels.SelectedItem.url;Remove=$true}}catch{Show-UiError $_.Exception.Message}})
    $ui.SubjectSort.Add_SelectionChanged({if($state.Snapshot){$id=if($ui.SubjectPick.SelectedItem){$ui.SubjectPick.SelectedItem.id}else{''};$ui.SubjectPick.ItemsSource=@($state.Snapshot.Config.subjects | Sort-Object name -Descending:($ui.SubjectSort.SelectedIndex -eq 1));foreach($subject in $ui.SubjectPick.Items){if($subject.id -eq $id){$ui.SubjectPick.SelectedItem=$subject;break}}}})
    $ui.ChannelsGrid.Add_SelectionChanged({Show-ChannelDetails})
    $ui.SyncSelected.Add_Click({if($ui.ChannelsGrid.SelectedItem){$c=$ui.ChannelsGrid.SelectedItem;Start-Work 'SyncAdd' @{Sources=@(@{Url=$c.Url;SubjectId=$c.SubjectId});RefreshTranscript=[bool]$ui.RefreshChannelTranscripts.IsChecked;ExportWorkbook=[bool]$ui.AutoExport.IsChecked}}})
    $ui.SyncAll.Add_Click({$sources=@(foreach($s in $state.Snapshot.Config.subjects){foreach($c in $s.channels){@{Url=$c.url;SubjectId=$s.id}}});Start-Work 'SyncAdd' @{Sources=$sources;RefreshTranscript=[bool]$ui.RefreshChannelTranscripts.IsChecked;ExportWorkbook=[bool]$ui.AutoExport.IsChecked}})
    $ui.CancelSync.Add_Click({$job=Get-SelectedSyncJob;if($job){if($state.QueueShared){$state.QueueShared.CancelSyncId=$job.Id};Start-Work 'SyncCancel' @{Id=$job.Id}}})
    $ui.Refresh.Add_Click({Start-Work 'Refresh'})
    $ui.ImportVideo.Add_Click({try{$s=Get-SelectedSubject;Start-Work 'QueueAdd' @{Text=$ui.VideoUrl.Text;SubjectId=$s.id;RefreshTranscript=[bool]$ui.RefreshVideoTranscript.IsChecked;ExportWorkbook=[bool]$ui.AutoExport.IsChecked}}catch{Show-UiError $_.Exception.Message}})
    function Start-QueueWork {
        if($state.QueueWorker -or $state.Worker -or $state.Closing -or -not $state.Ready -or $state.RestartRequired){return}
        $state.QueueShared=[hashtable]::Synchronized(@{Cancel=$false;Shutdown=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
        $ps=[powershell]::Create()
        $null=$ps.AddScript({param($root,$shared,$codeRoot,$testAdapter)
            $ErrorActionPreference='Stop'
            foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Settings')){Import-Module (Join-Path $codeRoot "src/Corpus.$name.psm1") -Force -Global}
            if($testAdapter){& (Get-Module Corpus.Queue) ([scriptblock]::Create($testAdapter))}
            Invoke-CorpusQueue $root $shared
        }).AddArgument($Root).AddArgument($state.QueueShared).AddArgument($appRoot).AddArgument($(if($SmokeTest){$SmokeQueueAdapter}else{''}))
        $state.QueueWorker=$ps;$state.QueueHandle=$ps.BeginInvoke();Set-Busy $false
    }
    $ui.QueueGrid.Add_SelectionChanged({Update-QueueButtons})
    $ui.QueueStart.Add_Click({Start-QueueWork})
    $ui.QueuePause.Add_Click({Start-Work 'QueueAction' @{Action='Pause';Id=''}})
    $ui.QueueCancel.Add_Click({if($state.QueueShared){$state.QueueShared.Cancel=$true;$ui.QueueCancel.IsEnabled=$false}})
    $ui.QueueRemove.Add_Click({$ids=@($ui.QueueGrid.SelectedItems | ForEach-Object {$_.Id});if($ids.Count){Start-Work 'QueueRemove' @{Ids=$ids}}})
    $ui.QueueRetry.Add_Click({if($ui.QueueGrid.SelectedItem){Start-Work 'QueueAction' @{Action='Retry';Id=$ui.QueueGrid.SelectedItem.Id}}})
    $ui.QueueClear.Add_Click({Start-Work 'QueueAction' @{Action='ClearFinished';Id=''}})
    $ui.Build.Add_Click({Start-Work 'Build'})
    function Get-CorpusFilters {
        $s=$ui.SearchSubject.SelectedItem
        return @{Text=$ui.Query.Text;Subject=$(if($s){$s.id}else{''});Channel=$ui.SearchChannel.Text;Video=$ui.SearchVideo.Text;From=$(if($ui.DateFrom.SelectedDate){$ui.DateFrom.SelectedDate.ToString('yyyy-MM-dd')}else{''});To=$(if($ui.DateTo.SelectedDate){$ui.DateTo.SelectedDate.ToString('yyyy-MM-dd')}else{''})}
    }
    $ui.FilterCorpus.Add_Click({Start-Work 'Filter' (Get-CorpusFilters)})
    $ui.ClearSearchSubject.Add_Click({$ui.SearchSubject.SelectedIndex=-1})
    $ui.Search.Add_Click({if([string]::IsNullOrWhiteSpace($ui.Query.Text)){Show-UiError 'Enter text to search the transcripts.';return};Start-Work 'Search' (Get-CorpusFilters)})
    $readTranscript={
        $isSearch=$ui.SearchGrid.Visibility -eq 'Visible'
        $row=if($isSearch){$ui.SearchGrid.SelectedItem}else{$ui.CorpusGrid.SelectedItem}
        if(-not $row){Show-UiError 'Select a video or transcript result first.';return}
        Start-Work 'Transcript' @{VideoId=$row.VideoId;Query=$(if($isSearch){$state.SearchText}else{''});SegmentId=$(if($isSearch){$row.SegmentId}else{''})}
    }
    # WPF disables auto-generated columns for PowerShell's dynamic property types.
    $ui.CorpusGrid.Add_AutoGeneratingColumn({param($sender,$eventArgs) $eventArgs.Column.CanUserSort=$true})
    $ui.OpenTranscript.Add_Click($readTranscript)
    $openTranscriptRow={
        param($sender,$eventArgs)
        # The grid also receives double-clicks from column headers, scrollbars and empty space.
        $row=[Windows.Controls.ItemsControl]::ContainerFromElement($sender,$eventArgs.OriginalSource)
        if($row -isnot [Windows.Controls.DataGridRow]){return}
        $sender.SelectedItem=$row.Item
        $eventArgs.Handled=$true
        & $readTranscript
    }
    $ui.CorpusGrid.Add_MouseDoubleClick($openTranscriptRow);$ui.SearchGrid.Add_MouseDoubleClick($openTranscriptRow)
    $ui.OpenResult.Add_Click({try{if($ui.SearchGrid.Visibility -eq 'Visible' -and $ui.SearchGrid.SelectedItem){Start-Process (Assert-CorpusYouTubeUrl $ui.SearchGrid.SelectedItem.TimestampUrl)}elseif($ui.CorpusGrid.SelectedItem){Start-Process (Assert-CorpusYouTubeUrl $ui.CorpusGrid.SelectedItem.VideoUrl)}}catch{Show-UiError $_.Exception.Message}})
    $ui.OpenWorkbook.Add_Click({try{$path=Join-Path $Root 'output/YouTubeCorpus.xlsx';if(-not (Test-Path $path)){throw 'Build the workbook first.'};Start-Process $path}catch{Show-UiError $_.Exception.Message}})
    $ui.OpenLogs.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $Root 'logs')+'"')})
    $ui.OpenData.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $Root 'data')+'"')})
    $ui.OpenConfig.Add_Click({Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $Root 'config.json')+'"')})
    $ui.Cancel.Add_Click({if($state.Shared){$state.Shared.Cancel=$true;$ui.Cancel.IsEnabled=$false;$ui.Status.Text='Cancelling safely…'}})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(200)
    $timer.Add_Tick({
        $state.QueueTicks++
        if($state.QueueTicks % 300 -eq 0){Update-StatusIndicators}
        if($state.QueueTicks % 5 -eq 0){
            try{$file=Get-Item (Join-Path $Root 'data/queue.json') -ErrorAction SilentlyContinue;$stamp=if($file){$file.LastWriteTimeUtc.Ticks.ToString()}else{''};if($stamp -ne $state.QueueStamp){$state.QueueStamp=$stamp;Refresh-QueueView;$state.NeedsRefresh=$true}}catch{$ui.QueueStatus.Text=$_.Exception.Message}
        }
        if($state.QueueWorker){
            $queueMessage='';$queueCount=0
            while($queueCount -lt 50 -and $state.QueueShared.Messages.TryDequeue([ref]$queueMessage)){$ui.LogText.AppendText($queueMessage+"`r`n");$queueCount++}
            if($ui.LogText.Text.Length -gt 80000){$ui.LogText.Text=$ui.LogText.Text.Substring($ui.LogText.Text.Length-50000)}
            $qp=$state.QueueShared.Progress
            if($qp){$ui.QueueStatus.Text="$(if($state.Queue.Paused){'Pausing after current'}else{'Running'}) | $($qp.Stage) | $($qp.Item)"}
            if($state.QueueHandle.IsCompleted){
                try{$null=$state.QueueWorker.EndInvoke($state.QueueHandle);if($state.QueueWorker.HadErrors){throw $state.QueueWorker.Streams.Error[0].Exception.Message}}
                catch{$ui.LogText.AppendText("Queue: $($_.Exception.Message)`r`n");$ui.Status.Text=$_.Exception.Message}
                finally{$state.QueueWorker.Dispose();$state.QueueWorker=$null;$state.QueueHandle=$null;Refresh-QueueView;Set-Busy ([bool]$state.Worker);$state.NeedsRefresh=$true}
            }
        }
        if($state.Closing -and -not $state.Worker -and -not $state.QueueWorker){$window.Close();return}
        if($state.NeedsRefresh -and -not $state.Worker -and -not $state.Closing){$state.NeedsRefresh=$false;Start-Work 'Refresh'}

        if($SmokeTest -and $SmokeQueueCheck -and $state.Snapshot -and -not $state.Closing){
            try{& $SmokeQueueCheck $window $ui $state}catch{$state.SmokeError=$_.Exception.Message;$window.Close()}
        }
        if($SmokeCorpus -and -not $state.Worker -and $state.Snapshot -and $state.SmokeStage -lt 3){
            try {
                switch($state.SmokeStage){
                    0 {if($SmokeGridCheck){$ui.Tabs.SelectedIndex=3;$window.UpdateLayout();& $SmokeGridCheck $ui.CorpusGrid;if($state.Worker){throw 'A non-row double-click opened a transcript.'}};$ui.Query.Text='test';$ui.FilterCorpus.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$state.SmokeStage=1}
                    1 {if($ui.CorpusGrid.Items.Count -ne 1){throw 'Corpus metadata filter failed.'};$ui.Search.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$state.SmokeStage=2}
                    2 {if($ui.SearchGrid.Items.Count -ne 2 -or $ui.SearchGrid.Visibility -ne 'Visible'){throw 'Integrated transcript search failed.'};if($SmokeGridCheck){$window.UpdateLayout();& $SmokeGridCheck $ui.SearchGrid;if($state.Worker){throw 'A search header opened a transcript.'}}
                        $ui.SearchGrid.SelectedIndex=0;$ui.SearchGrid.UpdateLayout()
                        $row=$ui.SearchGrid.ItemContainerGenerator.ContainerFromIndex(0)
                        $click=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
                        $click.RoutedEvent=[Windows.Controls.Control]::MouseDoubleClickEvent;$click.Source=$row
                        $ui.SearchGrid.RaiseEvent($click)
                        if(-not $state.Worker -or $state.Operation -ne 'Transcript'){throw 'Row double-click did not open its transcript.'}
                        $state.SmokeStage=3}
                }
            }catch{$state.SmokeError=$_.Exception.Message;$window.Close()}
        }
        if($SmokeTest){$state.SmokeTicks++;if($state.SmokeTicks -gt 15 -and -not $state.Worker -and -not $state.QueueWorker -and -not $SmokeQueueCheck){
            if($ScreenshotPath){
                $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream=[IO.File]::Create($ScreenshotPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
            }
            $window.Close();return
        }}
        if(-not $state.Worker){return}
        $message='';$count=0
        while($count -lt 50 -and $state.Shared.Messages.TryDequeue([ref]$message)){$ui.LogText.AppendText($message+"`r`n");$count++}
        if($ui.LogText.Text.Length -gt 80000){$ui.LogText.Text=$ui.LogText.Text.Substring($ui.LogText.Text.Length-50000)}
        if($count){$ui.LogText.ScrollToEnd()}
        if($state.Operation -eq 'UpdateDependencies' -and $state.Shared.ContainsKey('CommitInProgress')){$ui.Cancel.IsEnabled=(-not $state.Shared.CommitInProgress -and -not $state.Shared.Cancel)}
        $p=$state.Shared.Progress
        if($p){$ui.Status.Text="$($p.Stage) | $($p.Item)";$ui.Progress.IsIndeterminate=($p.Total -le 0);if($p.Total -gt 0){$ui.Progress.Maximum=$p.Total;$ui.Progress.Value=$p.Current;$ui.Status.Text+=" | $($p.Current) of $($p.Total)"}}
        if($state.Operation -eq 'Bootstrap'){$path=Join-Path $Root 'logs/bootstrap-progress.txt';if(Test-Path $path){try{$ui.Status.Text=[IO.File]::ReadAllText($path)}catch{}}}
        if($state.Handle.IsCompleted){
            $op=$state.Operation;$failed=$false;$viewerData=$null
            try{$result=@($state.Worker.EndInvoke($state.Handle));if($state.Worker.HadErrors){throw $state.Worker.Streams.Error[0].Exception.Message}
                switch($op){
                    'Bootstrap' {$state.Ready=$true;$ui.Status.Text='Ready'}
                    'CheckDependencies' {Set-DependencyRows $result;$ui.Status.Text=if($state.RestartRequired){'Restart YT-OSINT before resuming work.'}else{'Dependency check complete'}}
                    'UpdateDependencies' {$ui.Status.Text='Updates complete. Restarting YT-OSINT…'}
                    'RecoverDependencies' {$ui.Status.Text='Recovery complete. Restarting YT-OSINT…'}
                    'Refresh' {if($result.Count){Set-Snapshot $result[-1]}}
                    'Search' {$ui.SearchGrid.ItemsSource=$result;$ui.CorpusGrid.Visibility='Collapsed';$ui.SearchGrid.Visibility='Visible';$ui.CorpusNotice.Text="$($result.Count) matching segments. Double-click a result to read its transcript.";$ui.Status.Text="$($result.Count) matches"}
                    'Transcript' {if($result.Count){$viewerData=$result[-1]}}
                    'Subject' {if($state.SelectCreatedSubject -and $result.Count){$state.PendingSubjectId=[string]$result[-1]}}
                    'QueueAdd' {if($result.Count){$ui.QueueAddNotice.Text="$($result[-1].Added) added; $($result[-1].Duplicates) duplicates skipped";if($ui.VideoUrl.Text -eq $state.QueuedInput){$ui.VideoUrl.Clear()}};Refresh-QueueView}
                    'QueueAction' {Refresh-QueueView}
                    'QueueRemove' {Refresh-QueueView;if($result.Count){$ui.Status.Text="$($result[-1].Removed) pending items removed; $($result[-1].Skipped) skipped. Captured files preserved."}}
                    'Storage' {
                        $state.Preferences=Get-CorpusUserSettings $UserSettingsPath;$state.RestartRoot=$result[-1].Root
                        if($result[-1].Changed){$state.RestartRequired=$true;$ui.StorageRestart.Visibility='Visible';$ui.StorageNotice.Text='Saved. Restart to apply the new corpus folder. The original corpus remains intact.'}
                        else{$ui.StorageNotice.Text='Settings saved to your Windows profile.'}
                        $ui.Status.Text=$ui.StorageNotice.Text;Update-StatusIndicators
                    }
                    'SyncAdd' {Refresh-QueueView;$ui.Status.Text='Channel sync queued. Use Video Queue to start or resume.'}
                    'SyncCancel' {Refresh-QueueView}
                    'Filter' {$ui.CorpusGrid.ItemsSource=$result;$ui.CorpusGrid.Visibility='Visible';$ui.SearchGrid.Visibility='Collapsed';$ui.CorpusNotice.Text="$($result.Count) videos. Double-click a row to read its transcript."}
                    default {if($result.Count -and $result[-1].PSObject.Properties['FinalState']){$ui.Status.Text="$($result[-1].FinalState): $($result[-1].VideosDiscovered) discovered; $($result[-1].TranscriptsAdded) transcripts added; $($result[-1].TranscriptsUnavailable) unavailable; $($result[-1].Failures) failures; $(Get-CorpusProperty $result[-1] MembersOnlySkipped 0) members-only skipped"}}
                }
            }catch{$failed=$true;$state.WorkerError=$_.Exception.GetBaseException().Message;$ui.Status.Text=if($state.Shared.Cancel){'Cancelled; completed work preserved.'}elseif(Test-CorpusRateLimitError $_.Exception){'YouTube rate limit - sync stopped. Wait at least 8 minutes before retrying.'}else{'Operation failed; see Logs / Status.'};$ui.LogText.AppendText($_.Exception.GetBaseException().Message+"`r`n");if($op -eq 'Storage'){$ui.StorageNotice.Text='Settings were not saved: '+$_.Exception.GetBaseException().Message};if($op -eq 'QueueAdd'){$ui.QueueAddNotice.Text=$_.Exception.GetBaseException().Message}}
            finally{if($op -in @('UpdateDependencies','RecoverDependencies')){$state.RestartRequired=(-not $failed -or [bool]$state.Shared.DependenciesChanged);$ui.DependencyNotice.Text=if($failed){'Update did not complete. See Logs / Status for details.'}else{'Updates complete. Restarting YT-OSINT…'}};if($op -ne 'Refresh'){$state.LastOutcome=$ui.Status.Text};$state.Worker.Dispose();$state.Worker=$null;$state.Handle=$null;$ui.Progress.IsIndeterminate=$false;$ui.Progress.Value=0;Set-Busy $false}
            if($state.Closing){$window.Close();return}
            if($viewerData){try{Show-CorpusTranscriptWindow -Owner $window -Video $viewerData.Video -Rows $viewerData.Rows -Query $viewerData.Query -SegmentId $viewerData.SegmentId -SmokeTest:$SmokeCorpus | Out-Null;if($SmokeCorpus){$state.ViewerVerified=$true}}catch{if($SmokeCorpus){$state.SmokeError=$_.Exception.Message;$window.Close()}else{Show-UiError $_.Exception.Message}}}
            if($op -eq 'Bootstrap' -and $failed){$ui.LogText.AppendText("Use Settings > Dependencies to check or recover dependencies, then restart.`r`n");Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$false}}
            elseif($op -in @('UpdateDependencies','RecoverDependencies')){if(-not $failed){Restart-Application}else{Show-UiError $state.WorkerError}}
            elseif($op -notin @('Refresh','Search','Filter','Transcript','CheckDependencies')){Start-Work 'Refresh'}
            elseif($op -eq 'Refresh'){$ui.Status.Text=$state.LastOutcome;if(-not $state.CheckedStartup){$state.CheckedStartup=$true;Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$false}}}
        }
    })
    $window.Add_Closing({param($sender,$e) if($state.QueueWorker){$e.Cancel=$true;$state.Closing=$true;$state.QueueShared.Shutdown=$true;$state.QueueShared.Cancel=$true};if($state.Worker){$e.Cancel=$true;$state.Closing=$true;if($state.Operation -ne 'Bootstrap'){$state.Shared.Cancel=$true};$ui.Status.Text='Finishing safely before closing…'}})
    $window.Add_ContentRendered({if($SmokeCheckDependencies -or $OpenDependencies){$ui.SettingsTab.IsSelected=$true};if($SkipDependencies){Start-Work 'Refresh'}else{Start-Work 'Bootstrap'};$timer.Start()})
    Refresh-QueueView
    Set-Busy $true
    try{
        $null=$window.ShowDialog()
        if($SmokeTest){
            if($state.SmokeError){throw $state.SmokeError}
            if($SmokeCorpus -and (-not $state.ViewerVerified -or $state.SmokeError)){throw "Corpus workflow verification failed: $($state.SmokeError)"}
            if(-not $state.Ready -or -not $state.Snapshot){throw 'GUI smoke test failed: background initialization did not complete.'}
            if($SmokeCheckDependencies -and $state.DependencyRows.Count -ne 4){throw 'Dependency page did not receive all four background check results.'}
            [pscustomobject]@{Ready=$state.Ready;Subjects=$state.Snapshot.Config.subjects.Count;DispatcherTicks=$state.SmokeTicks;WorkerIdle=($null -eq $state.Worker);Dependencies=$state.DependencyRows.Count}
        }
    }finally{$timer.Stop();if($state.QueueWorker){$state.QueueShared.Shutdown=$true;$state.QueueShared.Cancel=$true;$state.QueueWorker.Dispose()};if($state.Worker){$state.Shared.Cancel=$true;$state.Worker.Dispose()};if($state.RestartTicket){[IO.File]::WriteAllText($state.RestartTicket.SignalPath,'ready');$state.RestartTicket.Process.Dispose()}}
}
Export-ModuleMember -Function Show-CorpusWindow,Start-CorpusRestart,Show-CorpusSubjectPrompt
