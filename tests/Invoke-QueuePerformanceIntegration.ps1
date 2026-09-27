[CmdletBinding()]
param([int[]]$Sizes=@(12000,50000,100000))
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if($env:COMPlus_gcConcurrent -ne '1'){
    . (Join-Path $project 'src/Corpus.GuiHost.ps1')
    exit (Invoke-CorpusGuiHost -ScriptPath $PSCommandPath -Parameters $PSBoundParameters)
}
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Settings','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -ReferencedAssemblies @('System','System.Core','WindowsBase','System.Xaml',[Windows.Controls.TextBox].Assembly.Location,[Windows.Media.Brushes].Assembly.Location) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows.Controls;
using System.Windows.Threading;
public sealed class QueueInputProbe : IDisposable {
    readonly DispatcherTimer timer;
    readonly Stopwatch clock = Stopwatch.StartNew();
    readonly List<double> delays = new List<double>();
    readonly TextBox input;
    readonly DataGrid grid;
    double previous;
    public int Edits { get; private set; }
    public int Scrolls { get; private set; }
    public string Phase { get; set; }
    public string WorstPhase { get; private set; }
    double maximum;
    public QueueInputProbe(TextBox input, DataGrid grid) {
        this.input=input; this.grid=grid;
        timer=new DispatcherTimer(DispatcherPriority.Input);timer.Interval=TimeSpan.FromMilliseconds(20);
        previous=clock.Elapsed.TotalMilliseconds;
        timer.Tick += Tick;timer.Start();
    }
    void Tick(object sender, EventArgs args) {
        double now=clock.Elapsed.TotalMilliseconds;double delay=Math.Max(0,now-previous-20);delays.Add(delay);previous=now;
        if(delay>maximum){maximum=delay;WorstPhase=Phase;}
        if(delays.Count % 20 == 0) { input.Text="responsive "+(++Edits); if(grid.Items.Count>0){grid.ScrollIntoView(grid.Items[(Scrolls++ % 2 == 0) ? grid.Items.Count-1 : 0]);} }
    }
    public double Percentile(double percentile) { var copy=delays.ToArray();Array.Sort(copy);return copy.Length==0 ? 0 : copy[Math.Min(copy.Length-1,(int)(copy.Length*percentile))]; }
    public int Samples { get { return delays.Count; } }
    public void Dispose() { timer.Stop();timer.Tick-=Tick; }
}
'@
$reports=@()
foreach($size in $Sizes){
    $root=Join-Path $project ('work/queue-performance-'+$size+'-'+[guid]::NewGuid().ToString('N'))
    $null=New-CorpusContext $root
    Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
    # Write synthetic rows directly so fixture creation itself does not perform N filesystem lookups.
    $writer=[IO.StreamWriter]::new((Join-Path $root data/queue.json),$false,[Text.UTF8Encoding]::new($false))
    try {
        $writer.Write('{"SchemaVersion":1,"Paused":true,"SyncJobs":[],"DiscoveryJobIds":[],"Items":[')
        for($i=0;$i -lt $size;$i++){
            if($i){$writer.Write(',')};$id='v'+$i.ToString('0000000000');$status=if($i % 10 -eq 0){'Completed'}else{'Pending'}
            $writer.Write(('{{"Id":"{0}","VideoId":"{0}","Title":"Fixture {0}","Url":"https://youtu.be/{0}","SubjectId":"mo","SubjectName":"Mo","Status":"{1}","Detail":"","JobIds":[],"Batch":true,"ListingEntry":null,"RefreshTranscript":false,"ExportWorkbook":false,"StartedAt":null,"FinishedAt":null,"AddedAt":"2026-01-01T00:00:00Z"}}' -f $id,$status))
        }
        $writer.Write(']}')
    }finally{$writer.Dispose()}
    $adapter=@'
function script:Invoke-CorpusOperation {
    param($Root,$Operation,$Arguments,$Shared,$CorpusLock)
    [IO.File]::WriteAllText((Join-Path $Root 'active.txt'),'active')
    $deadline=[datetime]::UtcNow.AddMinutes(5)
    while(-not (Test-Path (Join-Path $Root 'release.txt'))){if($Shared.Cancel -or [datetime]::UtcNow -gt $deadline){throw [OperationCanceledException]::new()};Start-Sleep -Milliseconds 50}
    [pscustomobject]@{MembersOnlySkipped=0;TranscriptsUnavailable=0;FinalState='Success'}
}
'@
    $test=@{Stage=0;Deadline=[datetime]::UtcNow.AddMinutes(10);Producer=$null;Handle=$null;Probe=$null;Row=$null;Source=$null;Corpus=$null;SortMs=0;Report=$null;RemovedCount=[math]::Min(5000,[int]($size/4))}
    $ready={param($window,$ui,$state) $ui.QueueTab.IsSelected=$true;$test.Probe=[QueueInputProbe]::new($ui.Query,$ui.QueueGrid);$test.Probe.Phase='Loading';if([Runtime.GCSettings]::LatencyMode -eq [Runtime.GCLatencyMode]::Batch){throw 'UI retained batch garbage collection'}}
    $check={
        param($window,$ui,$state)
        if([datetime]::UtcNow -gt $test.Deadline){throw "Large queue timeout at stage $($test.Stage): $($ui.LogText.Text)"}
        if($state.Worker){return}
        function Click($button){if(-not $button.IsEnabled){throw "$($button.Name) disabled at stage $($test.Stage)"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
        switch($test.Stage){
            0 {
                $test.Probe.Phase='Sort and background update'
                if($ui.QueueGrid.Items.Count -ne $size){throw 'Initial queue lost rows'}
                $test.Source=$ui.QueueGrid.ItemsSource;$test.Row=$state.QueueView.Rows[1];$test.Corpus=$state.Snapshot
                $null=$ui.QueueGrid.SelectedItems.Add($test.Row)
                $watch=[Diagnostics.Stopwatch]::StartNew()
                $column=@($ui.QueueGrid.Columns | Where-Object SortMemberPath -eq Title)[0];$column.SortDirection=[ComponentModel.ListSortDirection]::Ascending
                $ui.QueueGrid.SortColumn($column)
                $test.SortMs=$watch.Elapsed.TotalMilliseconds
                if($ui.QueueGrid.Items[0].Id -ne ('v'+($size-1).ToString('0000000000'))){throw 'Queue sort failed'}
                $ui.QueueGrid.SelectRows([YouTubeCorpus.QueueRow[]]@($ui.QueueGrid.Items | Where-Object Status -eq Pending | Select-Object -First 1000))
                if($ui.QueueGrid.SelectedItems.Count -ne 1001){throw 'Pending multi-selection failed'}
                $ui.QueueGrid.ScrollIntoView($test.Row);$ui.QueueGrid.UpdateLayout()
                # Only visible containers should exist, even with 100,000 source rows.
                if($ui.QueueGrid.ItemContainerGenerator.ContainerFromItem($state.QueueView.Rows[[int]($size/2)]) -ne $null){throw 'Queue rows are not virtualized'}
                $test.Producer=[powershell]::Create()
                $null=$test.Producer.AddScript({param($project,$root)
                    Import-Module (Join-Path $project src/Corpus.Core.psm1) -Force;Import-Module (Join-Path $project src/Corpus.Queue.psm1) -Force
                    $q=Get-CorpusQueue $root;$q.Items[1].Detail='Changed in background'
                    Write-CorpusJson (Join-Path $root data/queue.json) $q
                }).AddArgument($project).AddArgument($root)
                $test.Handle=$test.Producer.BeginInvoke();$test.Stage=1
            }
            1 {
                if($test.Row.Detail -ne 'Changed in background'){return}
                $null=$test.Producer.EndInvoke($test.Handle);if($test.Producer.HadErrors){throw $test.Producer.Streams.Error[0]};$test.Producer.Dispose();$test.Producer=$null
                if(-not [object]::ReferenceEquals($test.Source,$ui.QueueGrid.ItemsSource) -or -not [object]::ReferenceEquals($test.Row,$state.QueueView.Rows[1])){throw 'Refresh replaced the collection or row'}
                if($ui.QueueGrid.SelectedItems.Count -ne 1001 -or -not $ui.QueueGrid.SelectedItems.Contains($test.Row) -or $ui.QueueGrid.SortCount -ne 1){throw 'Refresh lost selection or sort'}
                if(-not [object]::ReferenceEquals($test.Corpus,$state.Snapshot)){throw 'Queue progress triggered a corpus refresh'}
                if($state.QueueView.AppliedChanges -ne 1){throw 'Single-row progress rebuilt unrelated rows'}
                Click $ui.QueueClear;$test.Stage=2
                $test.Probe.Phase='Clear finished'
            }
            2 {
                if($ui.QueueGrid.Items.Count -ne ($size-[math]::Ceiling($size/10))){throw 'Bulk clear lost pending work or retained history'}
                if($ui.QueueGrid.SelectedItems.Count -ne 1001 -or -not $ui.QueueGrid.SelectedItems.Contains($test.Row)){throw 'Bulk clear lost retained selections'}
                $test.Probe.Phase='Batch selection and removal'
                $ui.QueueGrid.SelectFirstRows($test.RemovedCount)
                if($ui.QueueGrid.SelectedItems.Count -ne $test.RemovedCount){throw 'Bulk selection did not select every requested row'}
                Click $ui.QueueRemove;$test.Stage=3
                $test.Probe.Phase='Remove pending'
            }
            3 {
                if($ui.QueueGrid.Items.Count -ne ($size-[math]::Ceiling($size/10)-$test.RemovedCount)){throw 'Selected pending batch removal failed'}
                if($ui.QueueGrid.SelectedItems.Count -or -not $ui.QueueGrid.Items.Contains($test.Row)){throw 'Bulk removal lost an unselected row or retained removed selections'}
                Click $ui.QueueToggle;$test.Stage=4
                $test.Probe.Phase='Start download'
            }
            4 {
                if(-not (Test-Path (Join-Path $root active.txt))){return}
                if(-not $state.QueueWorker){throw 'Fixture download is not active'}
                Click $ui.QueueClearAll;$test.Stage=5
                $test.Probe.Phase='Clear queue during download'
            }
            5 {
                if(-not $state.Queue.Paused){return}
                if($ui.QueueGrid.Items.Count -ne 1 -or $ui.QueueGrid.Items[0].Status -ne 'Running' -or -not $state.QueueWorker){throw 'Clear queue did not retain exactly the uninterrupted active download'}
                if($ui.QueueClearAll.IsEnabled){throw 'Clear queue should disable when only the active download remains'}
                [IO.File]::WriteAllText((Join-Path $root release.txt),'go');$test.Stage=6
            }
            6 {
                if($state.QueueWorker){return}
                if($state.QueueSnapshot.Counts.Finished -ne 1 -or $ui.QueueGrid.Items.Count -ne 1 -or $ui.QueueGrid.Items[0].Status -ne 'Completed' -or -not $state.Queue.Paused){throw 'Clear queue did not let exactly one active download finish'}
                $test.Probe.Dispose()
                $test.Report=[pscustomobject]@{Rows=$size;BatchRemoved=$test.RemovedCount;Samples=$test.Probe.Samples;InputEdits=$test.Probe.Edits;Scrolls=$test.Probe.Scrolls;P95DelayMs=[math]::Round($test.Probe.Percentile(.95),1);MaxDelayMs=[math]::Round($test.Probe.Percentile(1),1);WorstPhase=$test.Probe.WorstPhase;SortMs=[math]::Round($test.SortMs,1);MaxApplySliceMs=[math]::Round($state.QueueView.MaxSliceMilliseconds,1)}
                if($test.Probe.Samples -lt 50 -or $test.Probe.Edits -lt 5){throw 'UI probe did not run during queue operations'}
                if($test.Report.P95DelayMs -gt 100 -or $test.Report.MaxDelayMs -gt 1000){throw "Dispatcher responsiveness budget exceeded: $($test.Report | ConvertTo-Json -Compress)"}
                $window.Close()
            }
        }
    }
    $gcMode=[Runtime.GCSettings]::LatencyMode
    try {Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeQueueAdapter $adapter -SmokeWindowReady $ready -UserSettingsPath (Join-Path $root fixture-settings.json) | Out-Null}
    finally {if($test.Probe){$test.Probe.Dispose()};if($test.Producer){$test.Producer.Dispose()}}
    if([Runtime.GCSettings]::LatencyMode -ne $gcMode){throw 'Window did not restore the host garbage-collection policy'}
    $reports+=$test.Report;$test.Report | Format-List
}
$reports | ConvertTo-Json | Set-Content (Join-Path $project work/queue-performance-results.json) -Encoding UTF8
'Large-queue WPF integration passed: asynchronous load, virtualized scrolling, edits, sorting, stable selection, one-row update, history cleanup, removal and clearing thousands of queued videos while the current download finishes.'
