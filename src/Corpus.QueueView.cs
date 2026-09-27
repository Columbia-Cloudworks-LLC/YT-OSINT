using System;
using System.Collections;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Management.Automation;
using System.IO;
using System.Runtime.Serialization.Json;
using System.Threading.Tasks;
using System.Collections.Specialized;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Globalization;


namespace YouTubeCorpus
{
    public sealed class QueueRows : ObservableCollection<QueueRow>
    {
        internal void ReplaceAll(List<QueueRow> rows)
        {
            // WPF does not support range Remove notifications. A single Reset avoids
            // thousands of sorted-view/selection rebuilds for a bulk transaction.
            var list = (List<QueueRow>)Items; list.Clear(); list.AddRange(rows);
            OnPropertyChanged(new PropertyChangedEventArgs("Count"));
            OnPropertyChanged(new PropertyChangedEventArgs("Item[]"));
            OnCollectionChanged(new NotifyCollectionChangedEventArgs(NotifyCollectionChangedAction.Reset));
        }
    }
    public sealed class QueueGrid : DataGrid
    {
        private readonly List<SortDescription> sorts = new List<SortDescription>();
        public int SortCount { get { return sorts.Count; } }
        public QueueGrid() { Sorting += SortRows; }
        public void SortColumn(DataGridColumn column) { OnSorting(new DataGridSortingEventArgs(column)); }
        private void SortRows(object sender, DataGridSortingEventArgs args)
        {
            string property = args.Column.SortMemberPath;
            if (String.IsNullOrEmpty(property)) return;
            args.Handled = true;
            var direction = args.Column.SortDirection == ListSortDirection.Ascending ? ListSortDirection.Descending : ListSortDirection.Ascending;
            if ((Keyboard.Modifiers & ModifierKeys.Shift) == 0)
            {
                sorts.Clear(); foreach (var column in Columns) column.SortDirection = null;
            }
            sorts.RemoveAll(sort => sort.PropertyName == property);
            sorts.Add(new SortDescription(property, direction));
            args.Column.SortDirection = direction;
            ((ListCollectionView)CollectionViewSource.GetDefaultView(ItemsSource)).CustomSort = new RowComparer(sorts.ToArray());
        }
        public void RefreshSort()
        {
            if (sorts.Count == 0 || ItemsSource == null) return;
            var selected = new List<QueueRow>(); foreach (QueueRow row in SelectedItems) selected.Add(row);
            CollectionViewSource.GetDefaultView(ItemsSource).Refresh();
            SelectRows(selected.ToArray());
        }
        private sealed class RowComparer : IComparer
        {
            private readonly SortDescription[] sorts;
            private readonly CompareInfo culture = CultureInfo.CurrentCulture.CompareInfo;
            internal RowComparer(SortDescription[] sorts) { this.sorts = sorts; }
            private static string Value(QueueRow row, string property)
            {
                switch (property)
                {
                    case "Status": return row.Status;
                    case "Title": return row.Title;
                    case "EstPublishedDate": return row.EstPublishedDate;
                    case "SubjectName": return row.SubjectName;
                    case "Url": return row.Url;
                    case "Detail": return row.Detail;
                    default: return row.Id;
                }
            }
            public int Compare(object x, object y)
            {
                var a = (QueueRow)x; var b = (QueueRow)y;
                foreach (var sort in sorts)
                {
                    if (sort.PropertyName == "EstPublishedDate")
                    {
                        bool aUnknown = String.IsNullOrEmpty(a.EstPublishedDate), bUnknown = String.IsNullOrEmpty(b.EstPublishedDate);
                        if (aUnknown != bUnknown) return aUnknown ? 1 : -1;
                    }
                    int result = sort.PropertyName == "QueueOrder" ? a.QueueOrder.CompareTo(b.QueueOrder) : culture.Compare(Value(a, sort.PropertyName), Value(b, sort.PropertyName), CompareOptions.None);
                    if (result != 0) return sort.Direction == ListSortDirection.Ascending ? result : -result;
                }
                return StringComparer.Ordinal.Compare(a.Id, b.Id);
            }
        }
        public void SelectRows(QueueRow[] rows)
        {
            BeginUpdateSelectedItems();
            try { foreach (var row in rows) SelectedItems.Add(row); }
            finally { EndUpdateSelectedItems(); }
        }
        public void SelectFirstRows(int count)
        {
            UnselectAll();
            var rows = new QueueRow[Math.Min(count, Items.Count)];
            for (int i = 0; i < rows.Length; i++) rows[i] = (QueueRow)Items[i];
            SelectRows(rows);
        }
        public void SelectPendingBefore(DateTime cutoff)
        {
            string limit = cutoff.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            BeginUpdateSelectedItems();
            try
            {
                SelectedItems.Clear();
                foreach (QueueRow row in Items)
                    if (row.Status == "Pending" && !String.IsNullOrEmpty(row.EstPublishedDate) && StringComparer.Ordinal.Compare(row.EstPublishedDate, limit) < 0)
                        SelectedItems.Add(row);
            }
            finally { EndUpdateSelectedItems(); }
        }
        internal void ReplaceRows(QueueRows source, List<QueueRow> replacement)
        {
            var selected = new HashSet<QueueRow>(); foreach (QueueRow row in SelectedItems) selected.Add(row);
            var retained = new List<QueueRow>(); foreach (var row in replacement) if (selected.Contains(row)) retained.Add(row);
            var scroll = IsLoaded && Template != null ? Template.FindName("DG_ScrollViewer", this) as ScrollViewer : null;
            double offset = scroll == null ? 0 : scroll.VerticalOffset;
            double horizontal = scroll == null ? 0 : scroll.HorizontalOffset;
            var anchor = Items.Count == 0 ? null : Items[Math.Min(Items.Count - 1, (int)offset)] as QueueRow;
            source.ReplaceAll(replacement);
            SelectRows(retained.ToArray());
            if (scroll != null)
            {
                int index = anchor == null ? -1 : Items.IndexOf(anchor);
                scroll.ScrollToVerticalOffset(index < 0 ? offset : index);
                scroll.ScrollToHorizontalOffset(horizontal);
            }
        }
    }
    // Display-only DTOs deliberately omit the potentially large raw ListingEntry payload.
    // The authoritative writer continues to preserve every persisted field.
    public sealed class QueueItemData
    {
        public int QueueOrder { get; set; }
        public string EstPublishedDate { get; set; }
        public string Id { get; set; }
        public string VideoId { get; set; }
        public string SubjectId { get; set; }
        public string SubjectName { get; set; }
        public string Title { get; set; }
        public string Url { get; set; }
        public string Detail { get; set; }
        public string Status { get; set; }
        public string[] JobIds { get; set; }
    }
    public sealed class QueueJobData
    {
        public string Id { get; set; }
        public string SubjectId { get; set; }
        public string SubjectName { get; set; }
        public string Url { get; set; }
        public string ChannelId { get; set; }
        public string Detail { get; set; }
        public string Status { get; set; }
        public bool PartialImport { get; set; }
    }
    public sealed class QueueDocument
    {
        public bool AwaitingReview { get; set; }
        public int SchemaVersion { get; set; }
        public bool Paused { get; set; }
        public QueueItemData[] Items { get; set; }
        public QueueJobData[] SyncJobs { get; set; }
        public string[] DiscoveryJobIds { get; set; }
    }
    // Snapshot instances belong to the reader. Bound rows belong only to the dispatcher.
    public sealed class QueueRow : INotifyPropertyChanged
    {
        public int QueueOrder { get; internal set; }
        public string EstPublishedDate { get; private set; }
        public string PublishedDateLabel { get { return String.IsNullOrEmpty(EstPublishedDate) ? "Unknown" : EstPublishedDate; } }
        public string Id { get; private set; }
        public string VideoId { get; private set; }
        public string SubjectId { get; private set; }
        public string Title { get; private set; }
        public string SubjectName { get; private set; }
        public string Url { get; private set; }
        public string Detail { get; private set; }
        public string Status { get; private set; }
        public string StatusLabel { get { return Status == "Running" ? "Downloading" : Status; } }
        public string StatusColor
        {
            get { switch (Status) { case "Pending": return "#A96900"; case "Running": return "#176BC1"; case "Completed": return "#23844A"; case "Skipped": return "#657489"; case "Failed": return "#C52A35"; case "Cancelled": return "#A94350"; default: return "#657489"; } }
        }
        public string StatusGlyph
        {
            get { switch (Status) { case "Pending": return "\u2026"; case "Running": return "\u25b6"; case "Completed": return "\u2713"; case "Skipped": return "\u2212"; case "Failed": return "!"; case "Cancelled": return "\u00d7"; default: return "?"; } }
        }
        public event PropertyChangedEventHandler PropertyChanged;
        public QueueRow(PSObject item)
        {
            int order; QueueOrder = Int32.TryParse(Text(item, "QueueOrder"), out order) ? order : 0;
            EstPublishedDate = NormalizeDate(Text(item, "EstPublishedDate"));
            Id = Text(item, "Id"); VideoId = Text(item, "VideoId"); SubjectId = Text(item, "SubjectId");
            Title = Text(item, "Title"); SubjectName = Text(item, "SubjectName"); Url = Text(item, "Url");
            Detail = Text(item, "Detail"); Status = Text(item, "Status");
        }
        internal QueueRow(QueueItemData item)
        {
            QueueOrder = item.QueueOrder;
            EstPublishedDate = NormalizeDate(item.EstPublishedDate);
            Id = item.Id ?? ""; VideoId = item.VideoId ?? ""; SubjectId = item.SubjectId ?? "";
            Title = item.Title ?? ""; SubjectName = item.SubjectName ?? ""; Url = item.Url ?? "";
            Detail = item.Detail ?? ""; Status = item.Status ?? "";
        }
        internal QueueRow Copy() { return (QueueRow)MemberwiseClone(); }
        private static string NormalizeDate(string value)
        {
            DateTime date;
            return DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out date) ? value : "";
        }
        internal static string Text(PSObject item, string name)
        {
            var property = item.Properties[name]; return property == null ? "" : Convert.ToString(property.Value);
        }
        internal bool Same(QueueRow other)
        {
            return QueueOrder == other.QueueOrder && EstPublishedDate == other.EstPublishedDate && Title == other.Title && SubjectName == other.SubjectName && Url == other.Url &&
                Detail == other.Detail && Status == other.Status && SubjectId == other.SubjectId && VideoId == other.VideoId;
        }
        internal void Update(QueueRow other)
        {
            if (QueueOrder != other.QueueOrder) { QueueOrder = other.QueueOrder; Notify("QueueOrder"); }
            bool statusChanged = Status != other.Status;
            if (EstPublishedDate != other.EstPublishedDate) { EstPublishedDate = other.EstPublishedDate; Notify("EstPublishedDate"); Notify("PublishedDateLabel"); }
            if (Title != other.Title) { Title = other.Title; Notify("Title"); }
            if (SubjectName != other.SubjectName) { SubjectName = other.SubjectName; Notify("SubjectName"); }
            if (Url != other.Url) { Url = other.Url; Notify("Url"); }
            if (Detail != other.Detail) { Detail = other.Detail; Notify("Detail"); }
            SubjectId = other.SubjectId; VideoId = other.VideoId; Status = other.Status;
            if (statusChanged) { Notify("Status"); Notify("StatusLabel"); Notify("StatusColor"); Notify("StatusGlyph"); }
        }
        private void Notify(string name) { var handler = PropertyChanged; if (handler != null) handler(this, new PropertyChangedEventArgs(name)); }
    }

    public sealed class QueueCounts
    {
        public int Pending { get; internal set; }
        public int Running { get; internal set; }
        public int Finished { get; internal set; }
        public int Failed { get; internal set; }
        internal void Add(string status) { if (status == "Pending") Pending++; else if (status == "Running") Running++; else Finished++; if (status == "Failed") Failed++; }
    }

    public sealed class QueueSnapshot
    {
        public PSObject Queue { get; private set; }
        public PSObject Progress { get; private set; }
        public string Stamp { get; private set; }
        public QueueCounts Counts { get; private set; }
        private readonly Dictionary<string, QueueCounts> subjects = new Dictionary<string, QueueCounts>();
        private readonly Dictionary<string, QueueCounts> jobs = new Dictionary<string, QueueCounts>();
        private readonly Dictionary<string, QueueRow> byId = new Dictionary<string, QueueRow>();
        private readonly List<QueueRow> rows = new List<QueueRow>();
        internal readonly List<int> Removed = new List<int>();
        internal readonly List<QueueRow> Changed = new List<QueueRow>();
        public bool NeedsRecovery { get; private set; }
        public static QueueSnapshot Read(string path, QueueSnapshot previous, bool force)
        {
            var file = new FileInfo(path);
            string stamp = file.Exists ? file.LastWriteTimeUtc.Ticks + ":" + file.Length : "";
            if (!force && previous != null && previous.Stamp == stamp) return null;
            QueueDocument document;
            if (!file.Exists) document = new QueueDocument { SchemaVersion = 1, Paused = true };
            else using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                document = (QueueDocument)new DataContractJsonSerializer(typeof(QueueDocument), new DataContractJsonSerializerSettings { MaxItemsInObjectGraph = Int32.MaxValue }).ReadObject(stream);
            if (document == null || document.SchemaVersion != 1) throw new InvalidDataException("Unsupported queue format.");
            document.Items = document.Items ?? new QueueItemData[0]; document.SyncJobs = document.SyncJobs ?? new QueueJobData[0];
            var snapshot = new QueueSnapshot(); snapshot.Queue = PSObject.AsPSObject(document); snapshot.Stamp = stamp; snapshot.Counts = new QueueCounts();
            snapshot.NeedsRecovery = !document.Paused;
            foreach (var item in document.Items)
            {
                if (item.Status == "Running") snapshot.NeedsRecovery = true;
                var row = new QueueRow(item); snapshot.Add(row, item.JobIds ?? new string[0], previous);
            }
            foreach (var job in document.SyncJobs) if (job.Status == "Discovering") snapshot.NeedsRecovery = true;
            snapshot.FindRemoved(previous);
            return snapshot;
        }
        public void SetProgress(PSObject progress) { Progress = progress; }
        private QueueSnapshot() { }
        private void Add(QueueRow row, IEnumerable links, QueueSnapshot previous)
        {
            if (row.QueueOrder <= 0) row.QueueOrder = rows.Count + 1;
            if (byId.ContainsKey(row.Id)) throw new InvalidOperationException("Duplicate queue item ID: " + row.Id);
            byId.Add(row.Id, row); rows.Add(row); Counts.Add(row.Status); Count(subjects, row.SubjectId, row.Status);
            foreach (object job in links) Count(jobs, Convert.ToString(job), row.Status);
            QueueRow old;
            if (previous == null || !previous.byId.TryGetValue(row.Id, out old) || !old.Same(row)) Changed.Add(row);
        }
        private void FindRemoved(QueueSnapshot previous)
        {
            if (previous != null) for (int i = previous.rows.Count - 1; i >= 0; i--)
                if (!byId.ContainsKey(previous.rows[i].Id)) Removed.Add(i);
        }
        public QueueCounts Subject(string id) { QueueCounts value; return subjects.TryGetValue(id ?? "", out value) ? value : new QueueCounts(); }
        public QueueCounts Job(string id) { QueueCounts value; return jobs.TryGetValue(id ?? "", out value) ? value : new QueueCounts(); }
        private static void Count(Dictionary<string, QueueCounts> index, string id, string status)
        {
            QueueCounts counts; if (!index.TryGetValue(id, out counts)) index.Add(id, counts = new QueueCounts()); counts.Add(status);
        }
        public QueueSnapshot(PSObject queue, PSObject progress, string stamp, QueueSnapshot previous)
        {
            Queue = queue; Progress = progress; Stamp = stamp; Counts = new QueueCounts();
            var items = queue.Properties["Items"].Value as IEnumerable;
            if (items != null) foreach (object item in items)
            {
                var source = PSObject.AsPSObject(item); var row = new QueueRow(source);
                var links = source.Properties["JobIds"];
                Add(row, links != null && links.Value is IEnumerable ? (IEnumerable)links.Value : new string[0], previous);
            }
            FindRemoved(previous);
        }
    }

    // Normal progress uses individual notifications. Large removal transactions use
    // one collection reset, with the grid explicitly retaining surviving selection.
    public sealed class QueueView
    {
        public QueueRows Rows { get; private set; }
        private readonly Dictionary<string, QueueRow> byId = new Dictionary<string, QueueRow>();
        private QueueSnapshot pending;
        private int removal, change;
        private bool bulkRemoval;
        private int retainCursor;
        private List<QueueRow> retained;
        public bool IsApplying { get { return pending != null; } }
        public int AppliedChanges { get; private set; }
        public double MaxSliceMilliseconds { get; private set; }
        public QueueView() { Rows = new QueueRows(); }
        public static Task DisposeWorkerAsync(IDisposable worker)
        {
            // Closing a PowerShell runspace can release a large execution context.
            return Task.Run(() => worker.Dispose());
        }
        public static int PendingSelected(IList selection)
        {
            int count = 0; foreach (QueueRow row in selection) if (row.Status == "Pending") count++; return count;
        }
        public static string[] SelectedIds(IList selection)
        {
            var ids = new string[selection.Count]; for (int i = 0; i < ids.Length; i++) ids[i] = ((QueueRow)selection[i]).Id; return ids;
        }
        public void Begin(QueueSnapshot snapshot)
        {
            if (pending != null) throw new InvalidOperationException("A queue snapshot is already being applied.");
            pending = snapshot; removal = change = AppliedChanges = 0;
            bulkRemoval = snapshot.Removed.Count >= 256; retained = null; retainCursor = 0;
        }
        public bool ApplySlice(int milliseconds)
        {
            return ApplySlice(milliseconds, null);
        }
        public bool ApplySlice(int milliseconds, QueueGrid grid)
        {
            if (pending == null) return true;
            var clock = Stopwatch.StartNew(); int operations = 0;
            do
            {
                if (removal < pending.Removed.Count)
                {
                    int index = pending.Removed[removal++]; byId.Remove(Rows[index].Id);
                    if (!bulkRemoval) Rows.RemoveAt(index);
                }
                else if (bulkRemoval)
                {
                    if (retained == null) retained = new List<QueueRow>(byId.Count);
                    while (retainCursor < Rows.Count)
                    {
                        var row = Rows[retainCursor++]; if (byId.ContainsKey(row.Id)) retained.Add(row);
                        if (clock.ElapsedMilliseconds >= milliseconds) return false;
                    }
                    if (grid == null) Rows.ReplaceAll(retained); else grid.ReplaceRows(Rows, retained);
                    bulkRemoval = false; retained = null;
                    // Give input/rendering a turn after WPF's single reset and sort.
                    MaxSliceMilliseconds = Math.Max(MaxSliceMilliseconds, clock.Elapsed.TotalMilliseconds);
                    return false;
                }
                else if (change < pending.Changed.Count)
                {
                    var next = pending.Changed[change++]; QueueRow row;
                    if (byId.TryGetValue(next.Id, out row)) row.Update(next);
                    else { row = next.Copy(); byId.Add(row.Id, row); Rows.Add(row); }
                }
                else { if (grid != null && pending.Changed.Count > 0) grid.RefreshSort(); pending = null; break; }
                operations++; AppliedChanges++;
            } while (operations < (bulkRemoval ? 8192 : 128) && clock.ElapsedMilliseconds < milliseconds);
            MaxSliceMilliseconds = Math.Max(MaxSliceMilliseconds, clock.Elapsed.TotalMilliseconds);
            return pending == null;
        }
    }
}
