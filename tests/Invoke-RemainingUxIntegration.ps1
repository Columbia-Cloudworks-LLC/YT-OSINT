[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$root=Join-Path $project ('work/remaining-ux-'+[guid]::NewGuid().ToString('N'))
$ctx=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$video=ConvertTo-CorpusVideo ([pscustomobject]@{id='abcdefghijk';title='Metadata target';channel='Fixture channel';duration=9}) mo Mo
$video.TranscriptPath='data/normalized/transcripts/abcdefghijk.json';$video.TranscriptAvailable=$true
Save-CorpusVideo $ctx $video
$row=[pscustomobject]@{SegmentId='a';TranscriptText='A unique caption phrase.';TimestampDisplay='00:00:01.000';TimestampUrl='https://www.youtube.com/watch?v=abcdefghijk&t=1s'}
foreach($name in @('VideoId','VideoTitle','ChannelName','SubjectName','PublishedDate')){$row | Add-Member NoteProperty $name $video.$name}
Write-CorpusJson (Join-Path $root $video.TranscriptPath) @($row)
$null=Add-CorpusQueueUrls $root 'https://youtu.be/newDEF12_-3' mo
$check={
 param($window,$ui,$state)
 if(-not $state.ContainsKey('RemainingStage')){$state.RemainingStage=0;$state.RemainingDeadline=[datetime]::UtcNow.AddSeconds(80)}
 if([datetime]::UtcNow -gt $state.RemainingDeadline){throw "Remaining UX timed out at $($state.RemainingStage): $($ui.LogText.Text)"}
 if($state.Worker -or $state.QueueView.IsApplying){return}
 function Click($button){$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
 switch($state.RemainingStage){
  0 {
   $ui.QueueTab.IsSelected=$true;$window.UpdateLayout()
   if($ui.QueueCleanup.IsExpanded -or $ui.QueueSelectedActions.Visibility -ne 'Collapsed'){throw 'Queue secondary controls compete without a selection'}
   $ui.QueueGrid.SelectedIndex=0
   if($ui.QueueSelectedActions.Visibility -ne 'Visible'){throw 'Selected-row controls did not appear'}
   $ui.QueueGrid.SelectedIndex=-1
   if($ui.QueueSelectedActions.Visibility -ne 'Collapsed'){throw 'Selection controls remained after clearing selection'}
   if($ui.QueueToggle.Background.Color.ToString() -ne '#FF145DA0'){throw 'Primary queue action lost emphasis'}
   $ui.Tabs.SelectedIndex=1;$ui.ChannelsGrid.SelectedIndex=0
   if($ui.ChannelSyncStatus.Text -notmatch '^Queue activity:' -or $ui.ChannelLastResult.Text -notmatch '^Latest sync:' -or $ui.ChannelFreshness.Text -notmatch '^Freshness:'){throw 'Channel status dimensions are not separated'}
   if($ui.GlobalQueueStatus.Text -notmatch '^Queue:'){throw 'Global queue status is missing'}
   $ui.CorpusTab.IsSelected=$true;$ui.Query.Text='Metadata';$ui.SearchMode.SelectedIndex=0
   $null=$ui.Query.Focus()
   $key=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($window),0,[Windows.Input.Key]::Return)
   $key.RoutedEvent=[Windows.Input.Keyboard]::KeyDownEvent;$ui.Query.RaiseEvent($key)
   if(-not $key.Handled){throw 'Enter did not submit search'}
   $state.RemainingStage=1
  }
  1 {
   if($ui.CorpusGrid.Items.Count -ne 1 -or $ui.AppliedSearch.Text -notmatch 'Video details containing Metadata'){throw 'Metadata mode search failed'}
   $ui.SearchMode.SelectedIndex=1;$ui.Query.Text='unique caption';$ui.SearchChannel.Text='Missing channel';$ui.CorpusFilters.IsExpanded=$false
   if($ui.ActiveFilters.Text -notmatch 'Missing channel' -or $ui.AppliedSearch.Text -notmatch 'Metadata'){throw 'Draft filters are hidden or misrepresented as applied'}
   Click $ui.Search;$state.RemainingStage=2
  }
  2 {
   if($ui.SearchGrid.Visibility -ne 'Visible' -or $ui.SearchGrid.Items.Count -ne 0){throw 'Transcript channel filter was ignored'}
   Click $ui.ClearFilters;$state.RemainingStage=3
  }
  3 {
   if($ui.SearchGrid.Items.Count -ne 1 -or $ui.Query.Text -ne 'unique caption' -or $ui.ActiveFilters.Text -notmatch 'none'){throw 'Clear filters lost query or did not rerun search'}
   $ui.DateFrom.SelectedDate=[datetime]'2026-09-27';$ui.DateTo.SelectedDate=[datetime]'2026-01-01';Click $ui.Search
   if($state.Worker -or $ui.CorpusNotice.Text -notmatch 'start date'){throw 'Invalid date range was submitted'}
   $ui.DateFrom.SelectedDate=$null;$ui.DateTo.SelectedDate=$null
   $window.Width=760;$window.Height=560;$state.RemainingStage=4
  }
  4 {
   $ui.QueueTab.IsSelected=$true;$window.UpdateLayout()
   if($ui.BrandHeader.ActualHeight -ne 64 -or $ui.QueueGrid.ActualHeight -lt 60){throw "Compact queue leaves no useful content space: header=$($ui.BrandHeader.ActualHeight), grid=$($ui.QueueGrid.ActualHeight), window=$($window.ActualHeight)"}
   $point=$ui.QueueToggle.TranslatePoint([Windows.Point]::new(0,0),$window)
   if($point.X -lt 0 -or $point.X+$ui.QueueToggle.ActualWidth -gt $window.ActualWidth -or $point.Y+$ui.QueueToggle.ActualHeight -gt $window.ActualHeight){throw 'Compact primary action is clipped'}
   $ui.CorpusTab.IsSelected=$true;$ui.CorpusFilters.IsExpanded=$true;$window.UpdateLayout()
   if($ui.SearchGrid.ActualHeight -lt 60 -or $ui.CorpusControlsScroll.ScrollableHeight -le 0){throw 'Compact search cannot scroll controls while retaining results'}
   foreach($scale in @(1.5,2.0)){
    $window.Content.LayoutTransform=[Windows.Media.ScaleTransform]::new($scale,$scale);$window.Width=760*$scale;$window.Height=560*$scale;$window.UpdateLayout()
    if($ui.SearchGrid.ActualHeight -le 0){throw "Scaled layout lost results at $scale"}
   }
   $window.Content.LayoutTransform=[Windows.Media.Transform]::Identity
   $window.Close()
  }
 }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -UserSettingsPath (Join-Path $root fixture-settings.json)
Write-Host 'Remaining UX WPF integration passed: search modes, Enter, filter visibility/reset, status separation, contextual controls, compact and simulated scaled layout.'
