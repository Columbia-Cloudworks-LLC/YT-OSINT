[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Gui')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
if($null -ne (Show-CorpusSubjectPrompt -SmokeCancel)){throw 'Cancelled name prompt returned a name.'}
$root=Join-Path $project ('work/subjects-integration-'+[guid]::NewGuid().ToString('N'))
$ctx=New-CorpusContext $root
Copy-Item (Join-Path $PSScriptRoot fixtures/config.json) (Join-Path $root config.json)
$check={
    param($window,$ui,$state)
    if(-not $state.ContainsKey('SubjectsStage')){$state.SubjectsStage=0;$state.SubjectsStarted=[datetime]::UtcNow}
    if(([datetime]::UtcNow-$state.SubjectsStarted).TotalSeconds -gt 30){throw "Subject GUI check timed out: $($ui.LogText.Text)"}
    if($state.Worker){return}
    function Click($button){if(-not $button.IsEnabled){throw "Disabled button: $($button.Name)"};$button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
    switch($state.SubjectsStage){
        0 {
            if($ui.SubjectPick -isnot [Windows.Controls.ListBox]){throw 'Subjects are not shown in a list pane.'}
            if($ui.SubjectChannels.Items.Count -ne 2){throw 'Initial subject channels are missing.'}
            Click $ui.CreateSubject;$state.SubjectsStage=1
        }
        1 {
            if($ui.SubjectPick.SelectedItem.name -ne 'New subject' -or $ui.SubjectChannels.Items.Count -ne 0){throw 'New subject was not selected with an empty channel pane.'}
            $state.CreatedId=$ui.SubjectPick.SelectedItem.id
            $ui.ChannelUrl.Text='https://youtube.com/@newsource';Click $ui.AddChannel;$state.SubjectsStage=2
        }
        2 {
            if($ui.SubjectChannels.Items.Count -ne 1){throw 'Added channel did not appear on the right.'}
            $video=ConvertTo-CorpusVideo ([pscustomobject]@{id='abcDEF12_-3';title='Preserved capture'}) $state.CreatedId 'New subject'
            Save-CorpusVideo $ctx $video
            $state.CaptureText=[IO.File]::ReadAllText((Join-Path $root data/normalized/videos/abcDEF12_-3.json))
            Click $ui.RemoveSubject;$state.SubjectsStage=3
        }
        3 {
            if($ui.SubjectPick.Items.Count -ne 1 -or $ui.SubjectPick.SelectedItem.id -ne 'mo' -or $ui.SubjectChannels.Items.Count -ne 2){throw 'Removal did not refresh the subject and channel panes.'}
            if([IO.File]::ReadAllText((Join-Path $root data/normalized/videos/abcDEF12_-3.json)) -ne $state.CaptureText){throw 'Removal changed captured data.'}
            if(-not @($ui.SearchSubject.Items | Where-Object {$_.id -eq $state.CreatedId -and $_.DisplayName -match '\(archived\)'}).Count){throw 'Archived subject is unavailable in corpus search.'}
            Click $ui.CreateSubject;$state.SubjectsStage=4
        }
        4 {
            if($ui.SubjectPick.SelectedItem.id -eq $state.CreatedId -or $ui.SubjectPick.SelectedItem.name -ne 'New subject'){throw 'Same-name subject reused an archived identity.'}
            if($ui.SubjectChannels.Items.Count -ne 0){throw 'New subject inherited old channel associations.'}
            $window.Close()
        }
    }
}
Show-CorpusWindow $root -SkipDependencies -SmokeTest -SmokeQueueCheck $check -SmokeSubjectPrompt {param($owner) Show-CorpusSubjectPrompt $owner -SmokeName 'New subject'} -SmokeConfirmRemoval
'Subject GUI: prompt, automatic selection, right-side channels, safe removal, and same-name recreation passed.'
