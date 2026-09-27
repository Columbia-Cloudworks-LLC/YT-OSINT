Set-StrictMode -Version 2
Import-Module (Join-Path $PSScriptRoot 'Corpus.Icons.psm1') -Force -Global
function Initialize-CorpusViewer {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    if(-not ('YouTubeCorpus.HighlightTextBlock' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'Corpus.Viewer.cs') -ReferencedAssemblies @('System', 'WindowsBase', [Windows.Controls.TextBlock].Assembly.Location, [Windows.Media.Brushes].Assembly.Location, [Windows.Markup.XamlReader].Assembly.Location, 'System.Xaml')
    }
}
function Get-CorpusTranscriptView {
    param([object[]]$Rows,[string]$Query='',[switch]$MatchesOnly)
    foreach($row in $Rows) {
        $count=[YouTubeCorpus.HighlightTextBlock]::CountMatches($row.TranscriptText,$Query)
        if($MatchesOnly -and $Query -and $count -eq 0){continue}
        [pscustomobject]@{TimestampDisplay=$row.TimestampDisplay;TranscriptText=$row.TranscriptText;TimestampUrl=$row.TimestampUrl;SegmentId=$row.SegmentId;Query=$Query;MatchCount=$count}
    }
}
function Show-CorpusTranscriptWindow {
    param($Owner,$Video,[object[]]$Rows,[string]$Query='',[string]$SegmentId='',[switch]$SmokeTest,[string]$ScreenshotPath='')
    Initialize-CorpusViewer
    $assembly=[YouTubeCorpus.HighlightTextBlock].Assembly.GetName().Name
    [xml]$layout=@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:v="clr-namespace:YouTubeCorpus;assembly=$assembly" Title="Transcript" Width="1020" Height="760" MinWidth="700" MinHeight="480" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="14" Background="#F3F5F8">
<Window.Resources><Style TargetType="Button"><Setter Property="Padding" Value="12,7"/><Setter Property="Margin" Value="4"/></Style></Window.Resources>
<DockPanel Margin="20">
<StackPanel DockPanel.Dock="Top">
<TextBlock x:Name="VideoTitle" FontSize="22" FontWeight="SemiBold" TextWrapping="Wrap"/>
<TextBlock x:Name="VideoDetail" Foreground="#526075" Margin="0,6,0,18" TextWrapping="Wrap"/>
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBox x:Name="FindText" Padding="9" VerticalContentAlignment="Center" ToolTip="Find literal text within each timestamped segment (case insensitive)"/><Button x:Name="Previous" Grid.Column="1" Content="Previous match"/><Button x:Name="Next" Grid.Column="2" Content="Next match"/></Grid>
<WrapPanel Margin="0,8,0,12"><CheckBox x:Name="OnlyMatches" Content="Show matching segments only" VerticalAlignment="Center" Margin="0,0,18,0"/><TextBlock x:Name="Count" VerticalAlignment="Center"/></WrapPanel>
</StackPanel>
<DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0"><Button x:Name="OpenSource" DockPanel.Dock="Right" Content="Open selected timestamp"/><TextBlock Text="Select a segment to open its source. Double-click also opens YouTube." TextWrapping="Wrap" VerticalAlignment="Center"/></DockPanel>
<ListBox x:Name="Segments" ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" HorizontalContentAlignment="Stretch" Background="White" BorderBrush="#CFD8E5">
<ListBox.ItemContainerStyle><Style TargetType="ListBoxItem"><Setter Property="Padding" Value="10"/><Setter Property="HorizontalContentAlignment" Value="Stretch"/></Style></ListBox.ItemContainerStyle>
<ListBox.ItemTemplate><DataTemplate><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="115"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock Text="{Binding TimestampDisplay}" Foreground="#245BA5" FontFamily="Consolas" Margin="0,2,12,0"/><v:HighlightTextBlock Grid.Column="1" ContentText="{Binding TranscriptText}" Query="{Binding Query}" TextWrapping="Wrap"/></Grid></DataTemplate></ListBox.ItemTemplate>
</ListBox>
</DockPanel></Window>
"@
    $window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
    if($Owner){$window.Owner=$Owner}
    $ui=@{};foreach($name in @('VideoTitle','VideoDetail','FindText','Previous','Next','OnlyMatches','Count','Segments','OpenSource')){$ui[$name]=$window.FindName($name)}
    Set-CorpusButtonIcon $ui.OpenSource YouTube
    $ui.VideoTitle.Text=$Video.VideoTitle
    $window.Title='Transcript | '+$Video.VideoTitle
    $ui.VideoDetail.Text="$($Video.ChannelName) | $($Video.VideoId) | $($Rows.Count) timestamped segments"
    $state=@{Matches=@();View=@();Total=0;Error=$null;Ticks=0}
    function Update-TranscriptView {
        $selected=if($ui.Segments.SelectedItem){$ui.Segments.SelectedItem.SegmentId}else{$SegmentId}
        $state.View=@(Get-CorpusTranscriptView $Rows $ui.FindText.Text -MatchesOnly:([bool]$ui.OnlyMatches.IsChecked))
        $state.Matches=@($state.View | Where-Object MatchCount -gt 0)
        $state.Total=0;foreach($r in $state.Matches){$state.Total+=$r.MatchCount}
        $ui.Segments.ItemsSource=$state.View
        $ui.Count.Text=if(-not $Rows.Count){'No saved transcript for this video.'}elseif($ui.FindText.Text){"$($state.Total) matches in $($state.Matches.Count) segments"}else{"$($Rows.Count) segments | Enter text to highlight matches"}
        $ui.Previous.IsEnabled=$state.Matches.Count -gt 0;$ui.Next.IsEnabled=$state.Matches.Count -gt 0
        $keep=@($state.View | Where-Object SegmentId -eq $selected | Select-Object -First 1)
        if($keep.Count){$ui.Segments.SelectedItem=$keep[0]}elseif($state.Matches.Count){$ui.Segments.SelectedItem=$state.Matches[0]}
        if($ui.Segments.SelectedItem){$ui.Segments.ScrollIntoView($ui.Segments.SelectedItem)}
    }
    function Move-TranscriptMatch([int]$Direction) {
        if(-not $state.Matches.Count){return}
        $current=[array]::IndexOf($state.View,$ui.Segments.SelectedItem)
        $candidates=@($state.Matches | Where-Object {($Direction -gt 0 -and [array]::IndexOf($state.View,$_) -gt $current) -or ($Direction -lt 0 -and [array]::IndexOf($state.View,$_) -lt $current)})
        $next=if($candidates.Count){if($Direction -gt 0){$candidates[0]}else{$candidates[-1]}}else{if($Direction -gt 0){$state.Matches[0]}else{$state.Matches[-1]}}
        $ui.Segments.SelectedItem=$next;$ui.Segments.ScrollIntoView($next)
    }
    $debounce=[Windows.Threading.DispatcherTimer]::new();$debounce.Interval=[timespan]::FromMilliseconds(250)
    $debounce.Add_Tick({$debounce.Stop();Update-TranscriptView})
    $ui.FindText.Add_TextChanged({$debounce.Stop();$debounce.Start()})
    $ui.OnlyMatches.Add_Click({$debounce.Stop();Update-TranscriptView})
    $ui.Previous.Add_Click({Move-TranscriptMatch -1});$ui.Next.Add_Click({Move-TranscriptMatch 1})
    $open={try{if($ui.Segments.SelectedItem){Start-Process (Assert-CorpusYouTubeUrl $ui.Segments.SelectedItem.TimestampUrl)}}catch{[void][Windows.MessageBox]::Show($window,$_.Exception.Message,'Cannot open source')}}
    $ui.OpenSource.Add_Click($open);$ui.Segments.Add_MouseDoubleClick($open)
    $ui.FindText.Text=$Query;Update-TranscriptView
    $window.Add_ContentRendered({$null=$ui.FindText.Focus()})
    $smoke=[Windows.Threading.DispatcherTimer]::new();$smoke.Interval=[timespan]::FromMilliseconds(300)
    if($SmokeTest){$smoke.Add_Tick({
        try {
            $state.Ticks++
            if($state.Ticks -eq 1){
                if($state.View.Count -ne $Rows.Count){throw 'Initial transcript row count changed.'}
                if($Rows.Count -gt 100 -and $null -ne $ui.Segments.ItemContainerGenerator.ContainerFromIndex($Rows.Count-1)){throw 'Offscreen transcript rows were not virtualized.'}
                $ui.FindText.Text='test';return
            }
            if($state.Ticks -lt 3){return}
            if($state.Total -ne 3 -or $state.Matches.Count -ne 2){throw 'Debounced literal search returned incorrect counts.'}
            $ui.Next.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($ui.Segments.SelectedItem.SegmentId -ne 'b'){throw 'Next match navigation failed.'}
            $ui.Previous.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($ui.Segments.SelectedItem.SegmentId -ne 'a'){throw 'Previous match navigation failed.'}
            $ui.OnlyMatches.IsChecked=$true;$ui.OnlyMatches.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            if($ui.Segments.Items.Count -ne 2){throw 'Match filter failed.'}
            $ui.Segments.UpdateLayout()
            $container=$ui.Segments.ItemContainerGenerator.ContainerFromIndex(0)
            function Find-Highlight($node){if($node -is [YouTubeCorpus.HighlightTextBlock]){return $node};for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){$found=Find-Highlight ([Windows.Media.VisualTreeHelper]::GetChild($node,$i));if($found){return $found}}}
            $highlight=Find-Highlight $container
            if(-not $highlight -or @($highlight.Inlines | Where-Object {$_.Background -eq [Windows.Media.Brushes]::Gold}).Count -ne 2){throw 'Visible repeated matches were not highlighted.'}
            if($ScreenshotPath){$bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$window.ActualWidth,[int]$window.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bitmap.Render($window);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap));$stream=[IO.File]::Create($ScreenshotPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}}
        } catch {$state.Error=$_.Exception.Message} finally {if($state.Ticks -ge 3 -or $state.Error){$window.Close()}}
    });$smoke.Start()}
    try{$null=$window.ShowDialog();if($SmokeTest){if($state.Error){throw $state.Error};[pscustomobject]@{Matches=$state.Total;MatchingSegments=$state.Matches.Count;Highlighting=$true;Navigation=$true;Filter=$true}}}
    finally{$debounce.Stop();$smoke.Stop();$ui.Segments.ItemsSource=$null}
}
Export-ModuleMember -Function Initialize-CorpusViewer,Get-CorpusTranscriptView,Show-CorpusTranscriptWindow
