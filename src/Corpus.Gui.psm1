Set-StrictMode -Version 2
function Show-CorpusWindow {
    param([string]$Root,[switch]$SkipDependencies,[switch]$SmokeTest,[string]$ScreenshotPath='')
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
    $state=@{Worker=$null;Handle=$null;Shared=$null;Operation='';Snapshot=$null;Ready=[bool]$SkipDependencies;Closing=$false;PendingSubject='';SmokeTicks=0;LastOutcome='Ready';CheckedStartup=([bool]$SkipDependencies -or [bool]$SmokeTest);RestartRequired=$false;DependencyRows=@()}
    $mutators=@('CreateSubject','RenameSubject','AddChannel','RemoveChannel','SyncSelected','SyncAll','Refresh','CreateVideoSubject','ImportVideo','Build','Search','FilterCorpus')
    $ui.Paths.Text="Application and corpus root: $Root`nWorkbook: $(Join-Path $Root 'output/YouTubeCorpus.xlsx')`nSource configuration: $(Join-Path $Root 'config.json')`nNative dependencies: $env:SystemRoot"
    $dependencySettings=Get-CorpusDependencySettings $Root
    $ui.DependencyChannel.SelectedIndex=if($dependencySettings.YtDlpChannel -eq 'nightly'){1}else{0}
    function Set-Busy([bool]$Busy) {
        foreach($name in $mutators){$ui[$name].IsEnabled=(-not $Busy -and $state.Ready -and -not $state.RestartRequired)}
        foreach($name in @('CheckDependencies','UpdateDependencies','RecoverDependencies','DependencyChannel','DependenciesGrid')){$ui[$name].IsEnabled=(-not $Busy)}
        $ui.Cancel.IsEnabled=$Busy -and $state.Operation -notin @('Bootstrap','RecoverDependencies')
    }
    function Get-DependencyChannel {return [string]$ui.DependencyChannel.SelectedItem.Content}
    function Set-DependencyRows($Rows) {
        $state.DependencyRows=@($Rows)
        foreach($row in $state.DependencyRows){$row | Add-Member NoteProperty Selected $false -Force}
        $ui.DependenciesGrid.ItemsSource=$state.DependencyRows
        $available=@($Rows | Where-Object CanUpdate).Count
        $ui.DependencyNotice.Text="$available dependencies have install/update options. Select the checkboxes and review the changes before installation."
    }
    function Start-Work([string]$Operation,$Arguments=@{}) {
        if($state.Worker){return}
        $state.Operation=$Operation;$state.Shared=[hashtable]::Synchronized(@{Cancel=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
        $ps=[powershell]::Create()
        $null=$ps.AddScript({param($root,$op,$argsMap,$shared,$codeRoot)
            $ErrorActionPreference='Stop'
            foreach($name in @('Logging','Core','Process','Dependencies','Transcript','YouTube','Excel','Operations')){Import-Module (Join-Path $codeRoot "src/Corpus.$name.psm1") -Force -Global}
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
            if($op -eq 'Filter') {
                @(Get-CorpusVideos $root | Where-Object { ($_.SubjectName+' '+$_.ChannelName+' '+$_.VideoTitle+' '+$_.VideoId+' '+$_.LastSyncStatus).IndexOf($argsMap.Text,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object SubjectName,ChannelName,VideoTitle,VideoId,PublishedDate,Duration,TranscriptAvailable,SubtitleSource,MetadataCapturedAt,VideoUrl)
            } else {Invoke-CorpusOperation $root $op $argsMap $shared}
        }).AddArgument($Root).AddArgument($Operation).AddArgument($Arguments).AddArgument($state.Shared).AddArgument($appRoot)
        $state.Worker=$ps;$state.Handle=$ps.BeginInvoke();Set-Busy $true
        $ui.Status.Text=$Operation;$ui.Progress.IsIndeterminate=$true
    }
    function Show-SubjectChannels {
        $selected=$ui.SubjectPick.SelectedItem
        if($selected){$ui.SubjectName.Text=$selected.name;$ui.SubjectChannels.ItemsSource=@($selected.channels)}else{$ui.SubjectChannels.ItemsSource=@()}
    }
    function Set-Snapshot($Snapshot) {
        $state.Snapshot=$Snapshot
        $subjectId=if($ui.SubjectPick.SelectedItem){$ui.SubjectPick.SelectedItem.id}else{''}
        $videoId=if($ui.VideoSubject.SelectedItem){$ui.VideoSubject.SelectedItem.id}else{''}
        $searchId=if($ui.SearchSubject.SelectedItem){$ui.SearchSubject.SelectedItem.id}else{''}
        foreach($name in @('SubjectPick','VideoSubject','SearchSubject')){$ui[$name].ItemsSource=@($Snapshot.Config.subjects)}
        foreach($s in $Snapshot.Config.subjects){if($s.id -eq $subjectId){$ui.SubjectPick.SelectedItem=$s};if($s.id -eq $videoId -or $s.name -eq $state.PendingSubject){$ui.VideoSubject.SelectedItem=$s};if($s.id -eq $searchId){$ui.SearchSubject.SelectedItem=$s}}
        $state.PendingSubject=''
        if(-not $ui.SubjectPick.SelectedItem -and $Snapshot.Config.subjects.Count){$ui.SubjectPick.SelectedIndex=0}
        $channelRows=@(foreach($s in $Snapshot.Config.subjects){foreach($c in $s.channels){
            $known=@($Snapshot.Channels | Where-Object {$c.url -in $_.Urls});$attempt=@($Snapshot.Attempts | Where-Object Url -eq $c.url)
            if($known.Count){$k=$known[0];[pscustomobject]@{Subject=$s.name;ChannelName=$k.ChannelName;ChannelId=$k.ChannelId;Url=$c.url;VideosDiscovered=$k.VideosDiscovered;WithTranscripts=$k.TranscriptCount;WithoutTranscripts=$k.WithoutTranscripts;LastSuccessfulSync=$k.LastSync;LastAttempt=$(if($attempt.Count){$attempt[0].LastAttempt}else{$k.LastAttempt});Status=$(if($attempt.Count){$attempt[0].Status}else{$k.Status})}}
            else{[pscustomobject]@{Subject=$s.name;ChannelName='';ChannelId='';Url=$c.url;VideosDiscovered=0;WithTranscripts=0;WithoutTranscripts=0;LastSuccessfulSync='';LastAttempt=$(if($attempt.Count){$attempt[0].LastAttempt}else{''});Status=$(if($attempt.Count){$attempt[0].Status}else{'Not imported'})}}
        }})
        $ui.ChannelsGrid.ItemsSource=$channelRows
        $ui.CorpusGrid.ItemsSource=@($Snapshot.Videos | Select-Object SubjectName,ChannelName,VideoTitle,VideoId,PublishedDate,Duration,TranscriptAvailable,SubtitleSource,MetadataCapturedAt,VideoUrl)
        Show-SubjectChannels
    }
    function Show-UiError($Message){$ui.Status.Text=$Message;$ui.LogText.AppendText("ERROR: $Message`r`n");[Windows.MessageBox]::Show($window,$Message,'YT-OSINT','OK','Warning') | Out-Null}
    function Get-SelectedSubject {if(-not $ui.SubjectPick.SelectedItem){throw 'Select a subject first.'};return $ui.SubjectPick.SelectedItem}
    $ui.CheckDependencies.Add_Click({Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$true}})
    $ui.DependencyChannel.Add_SelectionChanged({
        $state.DependencyRows=@();$ui.DependenciesGrid.ItemsSource=@()
        $ui.DependencyNotice.Text='Channel changed. Press Check now to review available releases.'
    })
    $ui.UpdateDependencies.Add_Click({
        $ui.DependenciesGrid.CommitEdit()
        $selection=@($state.DependencyRows | Where-Object {$_.Selected -and $_.CanUpdate})
        if(-not $selection.Count){Show-UiError 'Select at least one available update.';return}
        $review=($selection | ForEach-Object {"$($_.Name): $($_.InstalledVersion) -> $($_.AvailableVersion) [$($_.Provider)]"}) -join "`r`n"
        $review+="`r`n`r`nNative updates replace the displayed SystemRoot binaries. FFmpeg/ffprobe switch to the gyan.dev essentials release pair. Backups are retained and failed verification triggers rollback. Restart YT-OSINT afterward. Continue?"
        if([Windows.MessageBox]::Show($window,$review,'Review dependency updates','YesNo','Question') -eq 'Yes'){
            Start-Work 'UpdateDependencies' @{Selection=$selection;Channel=(Get-DependencyChannel)}
        }
    })
    $ui.RecoverDependencies.Add_Click({Start-Work 'RecoverDependencies'})
    $ui.SubjectPick.Add_SelectionChanged({Show-SubjectChannels})
    $ui.CreateSubject.Add_Click({Start-Work 'Subject' @{Name=$ui.SubjectName.Text;Id=''}})
    $ui.RenameSubject.Add_Click({try{$s=Get-SelectedSubject;Start-Work 'Subject' @{Name=$ui.SubjectName.Text;Id=$s.id}}catch{Show-UiError $_.Exception.Message}})
    $ui.AddChannel.Add_Click({try{$s=Get-SelectedSubject;Start-Work 'Associate' @{SubjectId=$s.id;Url=$ui.ChannelUrl.Text.Trim();Remove=$false}}catch{Show-UiError $_.Exception.Message}})
    $ui.RemoveChannel.Add_Click({try{$s=Get-SelectedSubject;if(-not $ui.SubjectChannels.SelectedItem){throw 'Select a channel association to remove.'};Start-Work 'Associate' @{SubjectId=$s.id;Url=$ui.SubjectChannels.SelectedItem.url;Remove=$true}}catch{Show-UiError $_.Exception.Message}})
    $ui.SyncSelected.Add_Click({if($ui.ChannelsGrid.SelectedItem){Start-Work 'SyncChannel' @{Url=$ui.ChannelsGrid.SelectedItem.Url}}else{Show-UiError 'Select a channel first.'}})
    $ui.SyncAll.Add_Click({Start-Work 'SyncAll'})
    $ui.Refresh.Add_Click({Start-Work 'Refresh'})
    $ui.ClearVideoSubject.Add_Click({$ui.VideoSubject.SelectedIndex=-1})
    $ui.CreateVideoSubject.Add_Click({$state.PendingSubject=$ui.NewVideoSubject.Text.Trim();Start-Work 'Subject' @{Name=$state.PendingSubject;Id=''}})
    $ui.ImportVideo.Add_Click({try{$url=Assert-CorpusYouTubeUrl $ui.VideoUrl.Text.Trim();$s=$ui.VideoSubject.SelectedItem;Start-Work 'Video' @{Url=$url;SubjectId=$(if($s){$s.id}else{''});SubjectName=$(if($s){$s.name}else{''})}}catch{Show-UiError $_.Exception.Message}})
    $ui.Build.Add_Click({Start-Work 'Build'})
    $ui.FilterCorpus.Add_Click({Start-Work 'Filter' @{Text=$ui.CorpusFilter.Text}})
    $ui.ClearSearchSubject.Add_Click({$ui.SearchSubject.SelectedIndex=-1})
    $ui.Search.Add_Click({$s=$ui.SearchSubject.SelectedItem;Start-Work 'Search' @{Text=$ui.Query.Text;Subject=$(if($s){$s.id}else{''});Channel=$ui.SearchChannel.Text;Video=$ui.SearchVideo.Text;From=$(if($ui.DateFrom.SelectedDate){$ui.DateFrom.SelectedDate.ToString('yyyy-MM-dd')}else{''});To=$(if($ui.DateTo.SelectedDate){$ui.DateTo.SelectedDate.ToString('yyyy-MM-dd')}else{''})}})
    $ui.SearchGrid.Add_SelectionChanged({if($ui.SearchGrid.SelectedItem){$ui.ContextText.Text=$ui.SearchGrid.SelectedItem.Context}})
    $openResult={if($ui.SearchGrid.SelectedItem){Start-Process (Assert-CorpusYouTubeUrl $ui.SearchGrid.SelectedItem.TimestampUrl)}}
    $ui.OpenResult.Add_Click($openResult);$ui.SearchGrid.Add_MouseDoubleClick($openResult)
    $ui.OpenWorkbook.Add_Click({try{$path=Join-Path $Root 'output/YouTubeCorpus.xlsx';if(-not (Test-Path $path)){throw 'Build the workbook first.'};Start-Process $path}catch{Show-UiError $_.Exception.Message}})
    $ui.OpenLogs.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $Root 'logs')+'"')})
    $ui.OpenData.Add_Click({Start-Process explorer.exe -ArgumentList ('"'+(Join-Path $Root 'data')+'"')})
    $ui.OpenConfig.Add_Click({Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $Root 'config.json')+'"')})
    $ui.Cancel.Add_Click({if($state.Shared){$state.Shared.Cancel=$true;$ui.Cancel.IsEnabled=$false;$ui.Status.Text='Cancelling safely…'}})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if($SmokeTest){$state.SmokeTicks++;if($state.SmokeTicks -gt 15 -and -not $state.Worker){
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
            $op=$state.Operation;$failed=$false
            try{$result=@($state.Worker.EndInvoke($state.Handle));if($state.Worker.HadErrors){throw $state.Worker.Streams.Error[0].Exception.Message}
                switch($op){
                    'Bootstrap' {$state.Ready=$true;$ui.Status.Text='Ready'}
                    'CheckDependencies' {Set-DependencyRows $result;$ui.Status.Text='Dependency check complete'}
                    'UpdateDependencies' {$ui.Status.Text='Updates installed. Restart YT-OSINT before resuming work.'}
                    'RecoverDependencies' {$ui.Status.Text='Recovery completed. Restart YT-OSINT.'}
                    'Refresh' {if($result.Count){Set-Snapshot $result[-1]}}
                    'Search' {$ui.SearchGrid.ItemsSource=@($result | Select-Object SubjectName,ChannelName,VideoTitle,PublishedDate,TranscriptText,TimestampDisplay,Context,TimestampUrl);$ui.Status.Text="$($result.Count) matches"}
                    'Filter' {$ui.CorpusGrid.ItemsSource=$result}
                    default {if($result.Count -and $result[-1].PSObject.Properties['FinalState']){$ui.Status.Text="$($result[-1].FinalState): $($result[-1].VideosDiscovered) discovered; $($result[-1].TranscriptsAdded) transcripts added; $($result[-1].TranscriptsUnavailable) unavailable; $($result[-1].Failures) failures"}}
                }
            }catch{$failed=$true;$ui.Status.Text=if($state.Shared.Cancel){'Cancelled; completed work preserved.'}else{'Operation failed; see Logs / Status.'};$ui.LogText.AppendText($_.Exception.GetBaseException().Message+"`r`n")}
            finally{if($op -in @('UpdateDependencies','RecoverDependencies')){$state.RestartRequired=$true;$ui.DependencyNotice.Text='Maintenance finished. Restart YT-OSINT before running imports or workbook builds.'};if($op -ne 'Refresh'){$state.LastOutcome=$ui.Status.Text};$state.Worker.Dispose();$state.Worker=$null;$state.Handle=$null;$ui.Progress.IsIndeterminate=$false;$ui.Progress.Value=0;Set-Busy $false}
            if($state.Closing){$window.Close();return}
            if($op -eq 'Bootstrap' -and $failed){$ui.LogText.AppendText("Use Settings > Dependencies to check or recover dependencies, then restart.`r`n");Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$false}}
            elseif($op -in @('UpdateDependencies','RecoverDependencies')){Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$true}}
            elseif($op -notin @('Refresh','Search','Filter','CheckDependencies')){Start-Work 'Refresh'}
            elseif($op -eq 'Refresh'){$ui.Status.Text=$state.LastOutcome;if(-not $state.CheckedStartup){$state.CheckedStartup=$true;Start-Work 'CheckDependencies' @{Channel=(Get-DependencyChannel);Force=$false}}}
        }
    })
    $window.Add_Closing({param($sender,$e) if($state.Worker){$e.Cancel=$true;$state.Closing=$true;if($state.Operation -ne 'Bootstrap'){$state.Shared.Cancel=$true};$ui.Status.Text='Finishing safely before closing…'}})
    $window.Add_ContentRendered({if($SkipDependencies){Start-Work 'Refresh'}else{Start-Work 'Bootstrap'};$timer.Start()})
    Set-Busy $true
    try{
        $null=$window.ShowDialog()
        if($SmokeTest){
            if(-not $state.Ready -or -not $state.Snapshot){throw 'GUI smoke test failed: background initialization did not complete.'}
            [pscustomobject]@{Ready=$state.Ready;Subjects=$state.Snapshot.Config.subjects.Count;DispatcherTicks=$state.SmokeTicks;WorkerIdle=($null -eq $state.Worker)}
        }
    }finally{$timer.Stop();if($state.Worker){$state.Shared.Cancel=$true;$state.Worker.Dispose()}}
}
Export-ModuleMember -Function Show-CorpusWindow
