[CmdletBinding()]
param([int]$Limit=2,[string]$TestRoot=(Join-Path ([IO.Path]::GetTempPath()) ('YT-OSINT-integration-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
[IO.Directory]::CreateDirectory($TestRoot) | Out-Null
Copy-Item (Join-Path $project config.json) (Join-Path $TestRoot config.json)
foreach($name in @('Logging','Core','Process','Transcript','YouTube','Excel','Operations')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
& (Join-Path $project Install-Dependencies.ps1) -Root $TestRoot
$results=@()
foreach($iteration in 1..2) {
    $run=Invoke-CorpusOperation $TestRoot SyncAll @{Limit=$Limit}
    $videos=@(Get-CorpusVideos $TestRoot);$segments=@(foreach($v in $videos){Get-CorpusTranscript $TestRoot $v})
    $results+=[pscustomobject]@{Iteration=$iteration;Run=$run;Videos=$videos.Count;Segments=$segments.Count;UniqueVideoIds=@($videos.VideoId | Sort-Object -Unique).Count;UniqueSegmentIds=@($segments | ForEach-Object SegmentId | Sort-Object -Unique).Count}
}
Write-CorpusJson (Join-Path $TestRoot integration-results.json) $results
$results | ConvertTo-Json -Depth 10
Write-Host "Integration artifacts: $TestRoot"
if(@($results | Where-Object {$_.Run.Failures -gt 0}).Count){exit 2}
if($results[1].Videos -ne $results[1].UniqueVideoIds -or $results[1].Segments -ne $results[1].UniqueSegmentIds){throw 'Duplicate canonical identities detected.'}
