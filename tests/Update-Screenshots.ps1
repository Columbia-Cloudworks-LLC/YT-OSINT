[CmdletBinding()]
param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $project 'docs'}
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$fixtureRoot=Join-Path $project ('work/documentation-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-CorpusContext $fixtureRoot
$config=[pscustomobject]@{schemaVersion=1;subjects=@(
    [pscustomobject]@{id='space';name='Space research';channels=@()},
    [pscustomobject]@{id='technology';name='Technology research';channels=@([pscustomobject]@{url='https://www.youtube.com/@samplecomputing'},[pscustomobject]@{url='https://www.youtube.com/@sampleengineering'})}
);archivedSubjects=@()}
Write-CorpusJson (Join-Path $fixtureRoot config.json) $config
$now=[datetime]::UtcNow
foreach($entry in @(@('UC1234567890123456789012','Sample Computing','https://www.youtube.com/@samplecomputing',-2),@('UC2234567890123456789012','Sample Engineering','https://www.youtube.com/@sampleengineering',-12))){
    $channel=[pscustomobject]@{SubjectId='technology';Subject='Technology research';ChannelId=$entry[0];ChannelName=$entry[1];Url=$entry[2];Urls=@($entry[2]);VideosDiscovered=8;TranscriptCount=3;WithoutTranscripts=1;LastSync=$now.AddDays($entry[3]).ToString('o');LastAttempt=$now.ToString('o');Status='Downloading';Failures=1;MembersOnlySkipped=0}
    Write-CorpusJson (Join-Path $fixtureRoot "data/normalized/channels/$($entry[0]).json") $channel
}
$jobA=Add-CorpusSyncJob $fixtureRoot $config.subjects[1].channels[0].url technology
$jobB=Add-CorpusSyncJob $fixtureRoot $config.subjects[1].channels[1].url technology
$ids=@('abcDEF12_-3','xyzDEF12_-3','newDEF12_-3','vidDEF12_-3','endDEF12_-3','sixDEF12_-3','sevDEF12_-3','eigDEF12_-3')
$null=Add-CorpusQueueUrls $fixtureRoot (($ids | ForEach-Object {"https://youtu.be/$_"}) -join "`n") technology
$titles=@('How language models process text','Building reliable distributed systems','Understanding database indexes','A tour of modern CPU design','Practical network troubleshooting','Designing a resilient message queue','Storage formats and compression','Measuring application performance')
$statuses=@('Completed','Completed','Skipped','Failed','Cancelled','Pending','Pending','Pending')
$q=Get-CorpusQueue $fixtureRoot
for($i=0;$i -lt $q.Items.Count;$i++){$q.Items[$i].Title=$titles[$i];$q.Items[$i].Status=$statuses[$i];$q.Items[$i].JobIds=@($(if($i % 2 -eq 0){$jobA}else{$jobB}));$q.Items[$i].Detail=switch($statuses[$i]){'Completed' {'Metadata and English transcript saved'}'Skipped' {'No original English transcript available'}'Failed' {'Sample request failed; select this row to retry'}'Cancelled' {'Removed before download; partial channel import'}default {'Waiting for its turn'}}}
foreach($job in $q.SyncJobs){$job.Status='Downloading'}
$dates=@('2026-09-12','2026-08-04','2025-07-19','2024-03-01','2022-11-05','2023-02-01','2026-09-01','')
for($i=0;$i -lt $q.Items.Count;$i++){$q.Items[$i].EstPublishedDate=$dates[$i]}
$q.SyncJobs[0] | Add-Member NoteProperty PartialImport $true
Write-CorpusJson (Join-Path $fixtureRoot data/queue.json) $q
$null=[IO.Directory]::CreateDirectory((Join-Path $OutputDirectory screenshots))
function Save-DocumentationScreenshot($Window,[string]$RelativePath){
    $Window.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]($Window.Content.ActualWidth+$Window.Content.Margin.Left+$Window.Content.Margin.Right),[int]($Window.Content.ActualHeight+$Window.Content.Margin.Top+$Window.Content.Margin.Bottom),96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($Window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $path=Join-Path $OutputDirectory $RelativePath;$stream=[IO.File]::Create($path)
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
    Write-Host "Updated $RelativePath"
}
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('ScreenshotStage')){$state.ScreenshotStage=0;$state.ScreenshotDeadline=[datetime]::UtcNow.AddSeconds(60)}
    if([datetime]::UtcNow -gt $state.ScreenshotDeadline){throw "Screenshot generation timed out: $($ui.LogText.Text)"}
    if($state.Worker){return}
    switch($state.ScreenshotStage){
        0 {
            $window.Height=920
            $ui.QueueBefore.SelectedDate=[datetime]'2024-01-01'
            $ui.SubjectPick.SelectedItem=@($ui.SubjectPick.Items | Where-Object id -eq technology)[0]
            $ui.Tabs.SelectedIndex=0;$state.ScreenshotStage=1
        }
        1 {Save-DocumentationScreenshot $window 'screenshots/subjects.png';$ui.Tabs.SelectedIndex=1;$ui.ChannelsGrid.SelectedIndex=0;$state.ScreenshotStage=2}
        2 {
            Save-DocumentationScreenshot $window 'screenshots/channels.png'
            $window.Height=1000 # Keep every sample date, including Unknown, visible in queue screenshots.
            $q=Get-CorpusQueue $fixtureRoot;$q.Paused=$false;$q.Items[5].Status='Running';$q.Items[5].Detail='Downloading metadata and English transcript'
            Write-CorpusJson (Join-Path $fixtureRoot data/queue.json) $q
            $ui.QueueTab.IsSelected=$true;$state.ScreenshotStage=3
        }
        3 {
            if(-not @($ui.QueueGrid.Items | Where-Object Status -eq Running).Count){return}
            foreach($row in @($ui.QueueGrid.Items | Where-Object Status -eq Pending)){$null=$ui.QueueGrid.SelectedItems.Add($row)}
            Save-DocumentationScreenshot $window 'screenshots/queue.png';Save-DocumentationScreenshot $window 'screenshot.png'
            $q=Get-CorpusQueue $fixtureRoot;$q.SyncJobs[1].Status='Discovering';$q.Items[5].Status='Pending';$q.Items[5].Detail='Waiting for channel discovery';Write-CorpusJson (Join-Path $fixtureRoot data/queue.json) $q
            $state.ScreenshotStage=4
        }
        4 {
            if($ui.QueueStatus.Text -notmatch 'Discovering channels'){return}
            Save-DocumentationScreenshot $window 'screenshots/discovery.png'
            $window.Height=980;$ui.SettingsTab.IsSelected=$true;$ui.StorageTab.IsSelected=$true;$state.ScreenshotStage=5
        }
        5 {
            Save-DocumentationScreenshot $window 'screenshots/storage.png'
            $window.Height=920;$ui.StorageTab.IsSelected=$false
            $ui.SettingsTab.Content.SelectedIndex=0
            $ui.DependenciesGrid.ItemsSource=@(foreach($name in @('yt-dlp','FFmpeg','Deno','ImportExcel')){[pscustomobject]@{Selected=$false;CanUpdate=$false;Name=$name;InstalledVersion='Not checked';AvailableVersion='Unknown';Status='Not checked';InstalledChannel='';Provider=$(if($name -eq 'ImportExcel'){'PowerShell Gallery'}else{'Upstream release'});Channel='';Path='';LastCheck='';Detail='No network check in this fixture session.'}})
            $ui.DependencyNotice.Text='No update check has been run in this sample session. Check now loads installed and available versions.'
            $state.ScreenshotStage=6
        }
        6 {Save-DocumentationScreenshot $window 'dependencies.png';$ui.AboutTab.IsSelected=$true;$state.ScreenshotStage=7}
        7 {Save-DocumentationScreenshot $window 'screenshots/about.png';$ui.QueueTab.IsSelected=$true;$ui.QueueFilters.IsExpanded=$true;$state.ScreenshotStage=8}
        8 {Save-DocumentationScreenshot $window 'screenshots/queue-filters.png';$window.Close()}
    }
}
Show-CorpusWindow $fixtureRoot -SkipDependencies -SmokeTest -SmokeQueueCheck $check -UserSettingsPath (Join-Path $fixtureRoot 'fixture-settings.json')
