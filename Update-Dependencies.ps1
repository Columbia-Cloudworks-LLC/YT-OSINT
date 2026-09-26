[CmdletBinding()]
param(
    [ValidateSet('Check','Update','Recover')][string]$Action='Check',
    [ValidateSet('yt-dlp','FFmpeg','Deno','ImportExcel')][string[]]$Name=@(),
    [ValidateSet('stable','nightly')][string]$Channel='stable',
    [string]$Root='', [switch]$Force
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $Root){$Root=Split-Path -Parent $MyInvocation.MyCommand.Path}
foreach($module in @('Logging','Core','Process','Dependencies','DependencyTransaction')){
    Import-Module (Join-Path $PSScriptRoot "src/Corpus.$module.psm1") -Force -Global
}
$ctx=New-CorpusContext ([IO.Path]::GetFullPath($Root))
if(-not $PSBoundParameters.ContainsKey('Channel')){$Channel=(Get-CorpusDependencySettings $ctx.Root).YtDlpChannel}
switch($Action){
    'Check' {Get-CorpusDependencyStatus $ctx $Channel -Force:$Force}
    'Update' {
        if(-not $Name.Count){throw 'Specify -Name with the dependencies to update.'}
        $rows=@(Get-CorpusDependencyStatus $ctx $Channel -Force)
        $selection=@($rows | Where-Object {$_.Name -in $Name})
        if(@($selection | Where-Object {-not $_.CanUpdate}).Count){throw 'A selected dependency cannot be updated. Check its status first.'}
        Invoke-CorpusDependencyUpdate $ctx $selection $Channel
    }
    'Recover' {Repair-CorpusDependencies $ctx}
}
