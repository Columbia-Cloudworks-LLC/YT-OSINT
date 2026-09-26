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
$shared=[hashtable]::Synchronized(@{Cancel=$false;Progress=$null;Messages=[Collections.Concurrent.ConcurrentQueue[string]]::new()})
$ctx=New-CorpusContext ([IO.Path]::GetFullPath($TestRoot)) $shared
$installedRoot=Get-CorpusNativeRoot
$originalLocalAppData=$env:LOCALAPPDATA
$report=@()
try {
    # Isolate this process's user tools; exercise the real update orchestrator, not just its transaction helper.
    $env:LOCALAPPDATA=Join-Path $ctx.Root 'Isolated User Profile'
    [IO.Directory]::CreateDirectory((Get-CorpusNativeRoot)) | Out-Null
    foreach($dependency in $Name){
        Write-Host "Testing real $dependency release in an isolated user folder."
        if($dependency -eq 'ImportExcel'){
            $plans=@(Save-CorpusDependencyPlan $ctx $dependency stable)
            if($plans.Count -ne 1){throw 'Staging leaked internal output into the plan.'}
            $version=$plans[0].Version
        } else {
            foreach($file in @(Get-CorpusNativeNames $dependency)){
                $source=Join-Path $installedRoot $file
                if(Test-Path $source){[IO.File]::Copy($source,(Join-Path (Get-CorpusNativeRoot) $file),$false)}
            }
            $result=@(Invoke-CorpusDependencyUpdate $ctx @([pscustomobject]@{Name=$dependency;AvailableVersion=''}))
            if($result.Count -ne 1 -or $result[0].Status -ne 'Updated'){throw 'Native update did not return one successful result.'}
            $version=$result[0].Version
            $null=Get-CorpusDependencyInstalled $ctx $dependency
        }
        $report+=[pscustomobject]@{Name=$dependency;Version=$version;Status='Passed';InstalledDependenciesModified=$false}
        Write-CorpusJson (Join-Path $TestRoot integration-results.json) $report
    }
} finally {$env:LOCALAPPDATA=$originalLocalAppData}
$report | Format-Table
Write-Host "Integration evidence: $TestRoot"
