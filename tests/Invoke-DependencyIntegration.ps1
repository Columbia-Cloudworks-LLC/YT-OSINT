[CmdletBinding()]
param(
    [ValidateSet('yt-dlp','FFmpeg','Deno','ImportExcel')][string[]]$Name=@('yt-dlp','FFmpeg','Deno','ImportExcel'),
    [string]$TestRoot=(Join-Path ([IO.Path]::GetTempPath()) ('YTOSINT-dependency-test-'+[guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Logging','Core','Process','Dependencies','DependencyTransaction')){
    Import-Module (Join-Path $project "src/Corpus.$module.psm1") -Force -Global
}
$ctx=New-CorpusContext ([IO.Path]::GetFullPath($TestRoot))
$report=@()
foreach($dependency in $Name){
    Write-Host "Staging real $dependency release; installed dependencies will not be modified."
    $plan=Save-CorpusDependencyPlan $ctx $dependency stable
    if($dependency -ne 'ImportExcel'){
        $target=Join-Path $TestRoot "targets/$dependency"
        $transaction=Join-Path $TestRoot "transactions/$dependency"
        foreach($dir in @($target,$transaction)){[IO.Directory]::CreateDirectory($dir) | Out-Null}
        foreach($file in @(Get-CorpusNativeNames $dependency)){
            $installed=Join-Path $env:SystemRoot $file
            if(Test-Path -LiteralPath $installed){[IO.File]::Copy($installed,(Join-Path $target $file),$false)}
        }
        $journal=Join-Path $transaction transaction.json
        Install-CorpusNativeTransaction $ctx $dependency $plan.Candidate $plan.Version $target $transaction $journal $plan.Baseline
        if((Read-CorpusJson $journal).Status -ne 'Success'){throw 'Temporary native transaction failed.'}
        Write-Host "Verified real replacement under $target"
    } else {Write-Host 'Verified Gallery package and fresh-process XLSX round-trip; no module installed.'}
    $report+=[pscustomobject]@{Name=$dependency;Version=$plan.Version;Source=$plan.Release.Url;Status='Passed';InstalledDependenciesModified=$false}
    Write-CorpusJson (Join-Path $TestRoot integration-results.json) $report
}
$report | Format-Table
Write-Host "Integration evidence: $TestRoot"
