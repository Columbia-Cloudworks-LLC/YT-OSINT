Set-StrictMode -Version 2
function Set-CorpusButtonIcon {
    param($Button,[ValidateSet('YouTube','Excel','Transcript','Export','Play','Pause','Clear','Broom','Remove','Retry')][string]$Icon,[string]$Label='')
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    if(-not (Get-Variable IconResources -Scope Script -ErrorAction SilentlyContinue)){
        [xml]$xaml=Get-Content (Join-Path $PSScriptRoot 'Corpus.Icons.xaml') -Raw -Encoding UTF8
        $script:IconResources=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
    }
    if(-not $Label){$Label=[Windows.Automation.AutomationProperties]::GetName($Button);if(-not $Label){$Label=[string]$Button.Content}}
    $panel=[Windows.Controls.StackPanel]::new();$panel.Orientation='Horizontal';$panel.VerticalAlignment='Center'
    $image=[Windows.Controls.Image]::new();$image.Source=$script:IconResources[$Icon];$image.Width=18;$image.Height=18
    $image.Margin=[Windows.Thickness]::new(0,0,7,0);$image.VerticalAlignment='Center';$image.IsHitTestVisible=$false
    $text=[Windows.Controls.TextBlock]::new();$text.Text=$label;$text.VerticalAlignment='Center'
    $null=$panel.Children.Add($image);$null=$panel.Children.Add($text)
    $Button.Content=$panel
    [Windows.Automation.AutomationProperties]::SetName($Button,$label)
    $style=[Windows.Style]::new([Windows.Controls.Image])
    $trigger=[Windows.DataTrigger]::new();$trigger.Value=$false
    $binding=[Windows.Data.Binding]::new('IsEnabled');$binding.RelativeSource=[Windows.Data.RelativeSource]::new([Windows.Data.RelativeSourceMode]::FindAncestor,[Windows.Controls.Button],1)
    $trigger.Binding=$binding;$trigger.Setters.Add([Windows.Setter]::new([Windows.UIElement]::OpacityProperty,0.4))
    $style.Triggers.Add($trigger);$image.Style=$style
}
Export-ModuleMember -Function Set-CorpusButtonIcon
