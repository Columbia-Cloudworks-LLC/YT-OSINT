[CmdletBinding()]
param([string]$Root='',[string]$ProgressPath='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $Root){$Root=$PSScriptRoot}
foreach($module in @('Logging','Core','Process','Dependencies','DependencyTransaction')){
    Import-Module (Join-Path $PSScriptRoot "src/Corpus.$module.psm1") -Force -Global
}
$ctx=New-CorpusContext $Root
$lock=Enter-CorpusDependencyLock
$commitLock=$null
function Set-DependencyProgress([string]$Stage){
    Write-Host $Stage
    if($ProgressPath){[IO.File]::WriteAllText($ProgressPath,$Stage)}
}
try {
    $commitLock=Enter-CorpusDependencyLock -Commit
    if(@(Get-CorpusDependencyRecovery).Count){throw 'Recover the interrupted update in Settings > Dependencies.'}
    foreach($name in @('yt-dlp','FFmpeg','Deno')){
        $missing=@(Get-CorpusNativeNames $name | Where-Object {-not (Test-Path -LiteralPath (Join-Path (Get-CorpusNativeRoot) $_))})
        if($missing.Count){
            Set-DependencyProgress "Installing $name in your user folder"
            $channel=(Get-CorpusDependencySettings $Root).YtDlpChannel
            $null=Invoke-CorpusDependencyUpdate $ctx @([pscustomobject]@{Name=$name;AvailableVersion=''}) $channel
        }
        Set-DependencyProgress "Verifying $name"
        $null=Get-CorpusDependencyInstalled $ctx $name
    }
    Set-DependencyProgress 'Checking ImportExcel'
    $module=Get-CorpusDependencyInstalled $ctx ImportExcel
    if(-not $module.Version){$null=Invoke-CorpusDependencyUpdate $ctx @([pscustomobject]@{Name='ImportExcel';AvailableVersion=''})}
    $settings=Get-CorpusDependencySettings $Root
    if($settings.ImportExcelPath){Import-Module $settings.ImportExcelPath -ErrorAction Stop}
    else {Import-Module ImportExcel -ErrorAction Stop}
    Set-DependencyProgress 'Dependencies ready'
} catch {
    Write-CorpusLog $ctx Error Bootstrap '' $_.Exception.Message $_.ScriptStackTrace
    throw
} finally {
    if($commitLock){$commitLock.ReleaseMutex();$commitLock.Dispose()}
    $lock.ReleaseMutex();$lock.Dispose()
}
