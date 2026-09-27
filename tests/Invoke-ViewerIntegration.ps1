[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/Corpus.Core.psm1') -Force
Import-Module (Join-Path $root 'src/Corpus.Viewer.psm1') -Force
Initialize-CorpusViewer
$video=[pscustomobject]@{VideoTitle='Transcript search verification';ChannelName='Local fixture';VideoId='abcdefghijk'}
$rows=@(
 [pscustomobject]@{SegmentId='a';TranscriptText='Test a repeated TEST, with Unicode: café 日本語.';TimestampDisplay='00:00:01.000';TimestampUrl='https://www.youtube.com/watch?v=abcdefghijk&t=1s'},
 [pscustomobject]@{SegmentId='b';TranscriptText='A later test result.';TimestampDisplay='00:02:15.000';TimestampUrl='https://www.youtube.com/watch?v=abcdefghijk&t=135s'},
 [pscustomobject]@{SegmentId='c';TranscriptText='An unmatched segment stays available for context.';TimestampDisplay='00:03:00.000';TimestampUrl='https://www.youtube.com/watch?v=abcdefghijk&t=180s'}
)
if([YouTubeCorpus.HighlightTextBlock]::CountMatches('a.* A.*','a.*') -ne 2){throw 'Search must treat regex punctuation literally.'}
if([YouTubeCorpus.HighlightTextBlock]::CountMatches('Café CAFÉ','café') -ne 2){throw 'Unicode search failed.'}
if([YouTubeCorpus.HighlightTextBlock]::CountMatches('test','') -ne 0){throw 'Empty query must not match.'}
$empty=@(Get-CorpusTranscriptView @() 'test');if($empty.Count){throw 'Empty transcript failed.'}
$miss=@(Get-CorpusTranscriptView $rows 'not found' -MatchesOnly);if($miss.Count){throw 'No-match filter failed.'}
$block=New-Object YouTubeCorpus.HighlightTextBlock
$block.ContentText='test TEST';$block.Query='test'
if(@($block.Inlines | Where-Object {$_.Background -eq [Windows.Media.Brushes]::Gold}).Count -ne 2){throw 'Repeated highlight failed.'}
$block.ContentText='plain'
if(@($block.Inlines | Where-Object {$_.Background -eq [Windows.Media.Brushes]::Gold}).Count){throw 'Recycled row retained highlights.'}
$block.Query='';if((($block.Inlines | ForEach-Object Text) -join '') -ne 'plain'){throw 'Clearing query lost text.'}
$longRows=@($rows)+@(1..5000 | ForEach-Object {[pscustomobject]@{SegmentId="extra$_";TranscriptText='Long transcript context without a matching phrase.';TimestampDisplay='01:00:00.000';TimestampUrl='https://www.youtube.com/watch?v=abcdefghijk&t=3600s'}})
Show-CorpusTranscriptWindow -Video $video -Rows $longRows -SmokeTest

# Exercise the main window's real background search and selected-result viewer path.
foreach($name in @('Logging','Process','Dependencies','RateLimit','Transcript','YouTube','Excel','Operations','Gui')){Import-Module (Join-Path $root "src/Corpus.$name.psm1") -Force -Global}
$fixtureRoot=Join-Path $root ('work/viewer-integration-'+[guid]::NewGuid().ToString('N'))
$ctx=New-CorpusContext $fixtureRoot
Copy-Item (Join-Path $root config.json) (Join-Path $fixtureRoot config.json)
$video=ConvertTo-CorpusVideo ([pscustomobject]@{id='abcdefghijk';title='Test transcript';channel='Local fixture';duration=9}) mo Mo
$video.TranscriptPath='data/normalized/transcripts/abcdefghijk.json';$video.TranscriptAvailable=$true
Save-CorpusVideo $ctx $video
foreach($r in $rows){foreach($name in @('VideoId','VideoTitle','ChannelName','SubjectName','PublishedDate')){$r | Add-Member NoteProperty $name $video.$name}}
Write-CorpusJson (Join-Path $fixtureRoot $video.TranscriptPath) $rows
$other=ConvertTo-CorpusVideo ([pscustomobject]@{id='zyxwvutsrqp';title='Another video';duration=120}) mo Mo
Save-CorpusVideo $ctx $other
$checkHeaders={
    param($grid)
    function Find-Header($node,$column) {
        if($node -is [Windows.Controls.Primitives.DataGridColumnHeader] -and $node.Column -eq $column){return $node}
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node);$i++){
            $found=Find-Header ([Windows.Media.VisualTreeHelper]::GetChild($node,$i)) $column
            if($found){return $found}
        }
    }
    $grid.SelectedIndex=0
    $field=if($grid.Name -eq 'CorpusGrid'){'Duration'}else{'TimestampDisplay'}
    $column=$grid.Columns | Where-Object SortMemberPath -eq $field | Select-Object -First 1
    $grid.ScrollIntoView($grid.SelectedItem,$column);$grid.UpdateLayout()
    $header=Find-Header $grid $column
    if(-not $header){throw "Could not find $field header."}
    $onClick=[Windows.Controls.Primitives.DataGridColumnHeader].GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    $null=$onClick.Invoke($header,@())
    if($column.SortDirection -ne 'Ascending'){throw 'First header click did not sort ascending.'}
    $ascending=@($grid.Items | ForEach-Object {$_.$field})
    $null=$onClick.Invoke($header,@())
    if($column.SortDirection -ne 'Descending'){throw 'Second header click did not sort descending.'}
    $descending=@($grid.Items | ForEach-Object {$_.$field})
    if($ascending.Count -ne 2 -or $ascending[0] -ge $ascending[1] -or $descending[0] -ne $ascending[1]){throw 'Header clicks did not reorder the displayed rows correctly.'}
    if($field -eq 'Duration' -and $ascending[0] -ne 9){throw 'Numeric values were sorted as strings.'}
    $null=$onClick.Invoke($header,@()) # Restore ascending order for the selected-result viewer check.
    foreach($source in @($header,$grid)) {
        $click=[Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice,0,[Windows.Input.MouseButton]::Left)
        $click.RoutedEvent=[Windows.Controls.Control]::MouseDoubleClickEvent;$click.Source=$source
        $grid.RaiseEvent($click)
        if($click.Handled){throw 'Non-row double-click was intercepted.'}
    }
}
Show-CorpusWindow $fixtureRoot -SkipDependencies -SmokeTest -SmokeCorpus -SmokeGridCheck $checkHeaders
