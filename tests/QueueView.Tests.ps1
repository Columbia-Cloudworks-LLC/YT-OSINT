$project=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if(-not ('YouTubeCorpus.QueueView' -as [type])){Add-Type -Path (Join-Path $project 'src/Corpus.QueueView.cs') -ReferencedAssemblies @('System','System.Core','System.Runtime.Serialization','System.Xml','System.Xaml','WindowsBase',[Windows.Controls.DataGrid].Assembly.Location,[Windows.Media.Brushes].Assembly.Location,[psobject].Assembly.Location)}
function New-ViewFixture($rows){[pscustomobject]@{Items=@($rows);Paused=$true;SyncJobs=@()}}
function New-ViewRow([string]$id,[string]$status='Pending') {[pscustomobject]@{Id=$id;VideoId=$id;SubjectId='subject';SubjectName='Subject';Title=$id;Url='https://youtu.be/'+$id;Detail='';Status=$status;JobIds=@('shared')}}
Describe 'Incremental queue view' {
    It 're-sorts changed statuses and numeric priorities while retaining selected row identities' {
        $a=New-ViewRow a;$b=New-ViewRow b;$c=New-ViewRow c
        $a | Add-Member NoteProperty QueueOrder 10;$b | Add-Member NoteProperty QueueOrder 2;$c | Add-Member NoteProperty QueueOrder 1
        $first=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b,$c)),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($first);while(-not $view.ApplySlice(4)){}
        $grid=[YouTubeCorpus.QueueGrid]::new();$grid.SelectionMode='Extended';$grid.AutoGenerateColumns=$false;$grid.ItemsSource=$view.Rows
        $order=[Windows.Controls.DataGridTextColumn]::new();$order.SortMemberPath='QueueOrder';$grid.Columns.Add($order)
        $status=[Windows.Controls.DataGridTextColumn]::new();$status.SortMemberPath='Status';$grid.Columns.Add($status)
        $grid.SortColumn($order);(@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'c,b,a'
        $grid.SortColumn($order);(@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'a,b,c'
        $selected=$view.Rows[2];$grid.SelectedItem=$selected
        $grid.SortColumn($status);$c.Status='Completed'
        $next=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b,$c)),[pscustomobject]@{},'2',$first)
        $view.Begin($next);while(-not $view.ApplySlice(4,$grid)){}
        (@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'c,a,b'
        [object]::ReferenceEquals($grid.SelectedItem,$selected) | Should Be $true
        $grid.SortColumn($status);$b.Status='Running'
        $view.Begin([YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b,$c)),[pscustomobject]@{},'3',$next));while(-not $view.ApplySlice(4,$grid)){}
        (@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'b,a,c'
        [object]::ReferenceEquals($grid.SelectedItem,$selected) | Should Be $true
    }
    It 'sorts dates chronologically with unknowns last and selects only pending dates strictly before the cutoff' {
        $rows=@(New-ViewRow a;New-ViewRow b;New-ViewRow c;New-ViewRow d Completed;New-ViewRow e;New-ViewRow f)
        $dates=@('2024-01-01','2022-12-31','','2021-01-01','2023-01-01','2023-99-99')
        for($i=0;$i -lt $rows.Count;$i++){$rows[$i] | Add-Member NoteProperty EstPublishedDate $dates[$i]}
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin([YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture $rows),[pscustomobject]@{},'1',$null));while(-not $view.ApplySlice(4)){}
        $grid=[YouTubeCorpus.QueueGrid]::new();$grid.SelectionMode='Extended';$grid.AutoGenerateColumns=$false;$grid.ItemsSource=$view.Rows
        $column=[Windows.Controls.DataGridTextColumn]::new();$column.SortMemberPath='EstPublishedDate';$grid.Columns.Add($column)
        $grid.SortColumn($column);(@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'd,b,e,a,c,f'
        $grid.SortColumn($column);(@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'a,e,b,d,c,f'
        $grid.SelectedItem=$view.Rows[0];$grid.SelectPendingBefore([datetime]'2023-01-01')
        $grid.SelectedItems.Count | Should Be 1;$grid.SelectedItem.Id | Should Be b
        $view.Rows[2].PublishedDateLabel | Should Be Unknown;$view.Rows[5].PublishedDateLabel | Should Be Unknown
        $row=$view.Rows[1];$rows[1].EstPublishedDate='2023-02-03'
        $view.Begin([YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture $rows),[pscustomobject]@{},'2',$null));while(-not $view.ApplySlice(4)){}
        [object]::ReferenceEquals($row,$view.Rows[1]) | Should Be $true;$row.PublishedDateLabel | Should Be '2023-02-03'
    }
    It 'sorts through the grid header handler and retains selection and row identity' {
        $rows=@(New-ViewRow z;New-ViewRow a;New-ViewRow m)
        $snapshot=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture $rows),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($snapshot);while(-not $view.ApplySlice(4)){}
        $grid=[YouTubeCorpus.QueueGrid]::new();$grid.AutoGenerateColumns=$false;$grid.ItemsSource=$view.Rows
        $column=[Windows.Controls.DataGridTextColumn]::new();$column.SortMemberPath='Title';$grid.Columns.Add($column)
        $selected=$view.Rows[1];$grid.SelectedItem=$selected
        $grid.SortColumn($column)
        (@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'a,m,z'
        $column.SortDirection | Should Be Ascending
        $grid.SortColumn($column)
        (@($grid.Items | ForEach-Object Id) -join ',') | Should Be 'z,m,a'
        $column.SortDirection | Should Be Descending
        $grid.SortCount | Should Be 1
        [object]::ReferenceEquals($grid.SelectedItem,$selected) | Should Be $true
        [object]::ReferenceEquals($grid.ItemsSource,$view.Rows) | Should Be $true
    }
    It 'updates only changed rows without replacing row or collection identity' {
        $a=New-ViewRow a;$b=New-ViewRow b
        $first=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b)),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($first);while(-not $view.ApplySlice(4)){}
        $source=$view.Rows;$row=$view.Rows[0];$unchanged=$view.Rows[1]
        $notices=[Collections.Generic.List[string]]::new()
        $row.add_PropertyChanged({param($sender,$eventArgs) $notices.Add($eventArgs.PropertyName)}.GetNewClosure())
        $a.Status='Completed';$a.Title='Updated title'
        $next=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b)),[pscustomobject]@{},'2',$first)
        $view.Begin($next);while(-not $view.ApplySlice(4)){}
        [object]::ReferenceEquals($source,$view.Rows) | Should Be $true
        [object]::ReferenceEquals($row,$view.Rows[0]) | Should Be $true
        [object]::ReferenceEquals($unchanged,$view.Rows[1]) | Should Be $true
        $view.AppliedChanges | Should Be 1
        $row.Title | Should Be 'Updated title';$row.StatusLabel | Should Be Completed
        ($notices -join ',') | Should Be 'Title,Status,StatusLabel,StatusColor,StatusGlyph'
        $next.Counts.Pending | Should Be 1;$next.Subject('subject').Finished | Should Be 1;$next.Job('shared').Pending | Should Be 1
        $next.Subject('missing').Pending | Should Be 0
        # The previous immutable row snapshot must not follow the bound row's mutation.
        $same=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b)),[pscustomobject]@{},'3',$next)
        $view.Begin($same);while(-not $view.ApplySlice(4)){};$view.AppliedChanges | Should Be 0
    }
    It 'removes nonadjacent rows and appends rows across successive snapshots' {
        $a=New-ViewRow a;$b=New-ViewRow b;$c=New-ViewRow c;$d=New-ViewRow d
        $first=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($a,$b,$c)),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($first);while(-not $view.ApplySlice(4)){}
        $middle=$view.Rows[1]
        $next=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($b,$d)),[pscustomobject]@{},'2',$first)
        $view.Begin($next);while(-not $view.ApplySlice(4)){}
        ($view.Rows.Id -join ',') | Should Be 'b,d';[object]::ReferenceEquals($middle,$view.Rows[0]) | Should Be $true
        $empty=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @()),[pscustomobject]@{},'3',$next)
        $view.Begin($empty);while(-not $view.ApplySlice(4)){};$view.Rows.Count | Should Be 0
    }
    It 'yields during large discovery batches and rejects overlapping snapshots' {
        $rows=@(for($i=0;$i -lt 1000;$i++){New-ViewRow ([string]$i)})
        $snapshot=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture $rows),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($snapshot)
        $view.ApplySlice(4) | Should Be $false
        { $view.Begin($snapshot) } | Should Throw
        while(-not $view.ApplySlice(4)){};$view.Rows.Count | Should Be 1000
    }
    It 'reads lightweight snapshots, skips unchanged files and recognizes recovery states' {
        $path=Join-Path $TestDrive queue.json
        [IO.File]::WriteAllText($path,'{"SchemaVersion":1,"Paused":true,"Items":[{"Id":"a","Status":"Pending","Title":"Unicode \u2603","ListingEntry":{"large":"raw payload"}}]}')
        $first=[YouTubeCorpus.QueueSnapshot]::Read($path,$null,$true)
        $first.Counts.Pending | Should Be 1;$first.NeedsRecovery | Should Be $false
        $first.Queue.Items[0].Title | Should Be "Unicode $([char]0x2603)"
        $first.Queue.Items[0].PSObject.Properties['ListingEntry'] | Should BeNullOrEmpty
        [YouTubeCorpus.QueueSnapshot]::Read($path,$first,$false) | Should BeNullOrEmpty
        [IO.File]::WriteAllText($path,'{"SchemaVersion":1,"Paused":true,"Items":[{"Id":"a","Status":"Running"}],"SyncJobs":[]}')
        $next=[YouTubeCorpus.QueueSnapshot]::Read($path,$first,$true)
        $next.NeedsRecovery | Should Be $true;$next.Counts.Running | Should Be 1
        [IO.File]::WriteAllText($path,'{"SchemaVersion":2,"Items":[]}')
        {[YouTubeCorpus.QueueSnapshot]::Read($path,$next,$true)} | Should Throw
        [IO.File]::WriteAllText($path,'{"SchemaVersion":1,"Items":[{"Id":"a"},{"Id":"a"}]}')
        {[YouTubeCorpus.QueueSnapshot]::Read($path,$next,$true)} | Should Throw
    }
    It 'publishes a large removal as one collection change and retains surviving row objects' {
        $rows=@(for($i=0;$i -lt 1000;$i++){New-ViewRow ([string]$i)})
        $first=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture $rows),[pscustomobject]@{},'1',$null)
        $view=[YouTubeCorpus.QueueView]::new();$view.Begin($first);while(-not $view.ApplySlice(4)){}
        $survivor=$view.Rows[0];$collection=$view.Rows
        $events=[Collections.Generic.List[string]]::new()
        $view.Rows.add_CollectionChanged({param($sender,$e) $events.Add([string]$e.Action)}.GetNewClosure())
        $next=[YouTubeCorpus.QueueSnapshot]::new((New-ViewFixture @($rows[0],$rows[999])),[pscustomobject]@{},'2',$first)
        $view.Begin($next);while(-not $view.ApplySlice(4)){}
        ($events -join ',') | Should Be 'Reset'
        [object]::ReferenceEquals($collection,$view.Rows) | Should Be $true
        [object]::ReferenceEquals($survivor,$view.Rows[0]) | Should Be $true
        ($view.Rows.Id -join ',') | Should Be '0,999'
    }
}
