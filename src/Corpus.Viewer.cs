using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;

namespace YouTubeCorpus {
    // Only visible ListBox rows instantiate this control. Recycled rows re-render both bindings.
    public class HighlightTextBlock : TextBlock {
        public static readonly DependencyProperty ContentTextProperty = DependencyProperty.Register(
            "ContentText", typeof(string), typeof(HighlightTextBlock), new PropertyMetadata("", Changed));
        public static readonly DependencyProperty QueryProperty = DependencyProperty.Register(
            "Query", typeof(string), typeof(HighlightTextBlock), new PropertyMetadata("", Changed));
        public string ContentText { get { return (string)GetValue(ContentTextProperty); } set { SetValue(ContentTextProperty, value); } }
        public string Query { get { return (string)GetValue(QueryProperty); } set { SetValue(QueryProperty, value); } }
        static void Changed(DependencyObject d, DependencyPropertyChangedEventArgs e) { ((HighlightTextBlock)d).Render(); }
        void Render() {
            Inlines.Clear();
            string text = ContentText ?? "", query = Query ?? "";
            int cursor = 0, found;
            if (query.Length > 0) {
                while ((found = text.IndexOf(query, cursor, StringComparison.OrdinalIgnoreCase)) >= 0) {
                    if (found > cursor) Inlines.Add(new Run(text.Substring(cursor, found - cursor)));
                    Inlines.Add(new Run(text.Substring(found, query.Length)) { Background = Brushes.Gold, Foreground = Brushes.Black });
                    cursor = found + query.Length;
                }
            }
            if (cursor < text.Length) Inlines.Add(new Run(text.Substring(cursor)));
        }
        public static int CountMatches(string text, string query) {
            if (String.IsNullOrEmpty(text) || String.IsNullOrEmpty(query)) return 0;
            int count = 0, cursor = 0, found;
            while ((found = text.IndexOf(query, cursor, StringComparison.OrdinalIgnoreCase)) >= 0) {
                count++; cursor = found + query.Length;
            }
            return count;
        }
    }
}
