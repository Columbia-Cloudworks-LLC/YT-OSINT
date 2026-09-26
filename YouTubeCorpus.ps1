[CmdletBinding()]
param(
    [ValidateSet('Gui','SyncAll','SyncChannel','Video','Build','Search','Refresh')][string]$Action='Gui',
    [string]$Url='', [string]$SubjectId='', [string]$Text='', [string]$Root='',
    [int]$Limit=0, [switch]$SkipDependencies, [switch]$SmokeTest, [switch]$OpenDependencies, [string]$RestartSignal=''
)
$ErrorActionPreference='Stop'
if(-not $Root){ $Root=Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-StrictMode -Version 2
if($RestartSignal){
    $deadline=[datetime]::UtcNow.AddSeconds(60)
    while(-not (Test-Path -LiteralPath $RestartSignal)){
        if([datetime]::UtcNow -gt $deadline){throw 'The previous window did not finish closing; restart cancelled.'}
        Start-Sleep -Milliseconds 100
    }
    Remove-Item -LiteralPath $RestartSignal -Force
}
if(-not $env:SystemRoot){throw 'YT-OSINT requires Windows PowerShell 5.1 on Windows.'}
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
foreach($name in @('Logging','Core','Process','Dependencies','DependencyTransaction','Transcript','YouTube','Excel','Operations','Gui')){Import-Module (Join-Path $PSScriptRoot "src/Corpus.$name.psm1") -Force -Global}
$null=New-CorpusContext $Root
if($Action -eq 'Gui') {
    if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Start the GUI with powershell.exe -STA -File YouTubeCorpus.ps1 or use the batch launcher.'}
    Show-CorpusWindow $Root -SkipDependencies:$SkipDependencies -SmokeTest:$SmokeTest -OpenDependencies:$OpenDependencies
} else {
    if(-not $SkipDependencies){& (Join-Path $PSScriptRoot 'Install-Dependencies.ps1') -Root $Root}
    $map=@{}
    if($Action -eq 'SyncChannel'){$map.Url=$Url;$map.Limit=$Limit}
    if($Action -eq 'SyncAll'){$map.Limit=$Limit}
    if($Action -eq 'Video') {
        $config=Get-CorpusConfig $Root;$subject=@($config.subjects | Where-Object id -eq $SubjectId)
        if($SubjectId -and -not $subject.Count){throw 'The specified subject does not exist.'}
        $map=@{Url=$Url;SubjectId=$SubjectId;SubjectName=$(if($subject.Count){$subject[0].name}else{''})}
    }
    if($Action -eq 'Search'){$map.Text=$Text}
    Invoke-CorpusOperation $Root $Action $map
}
