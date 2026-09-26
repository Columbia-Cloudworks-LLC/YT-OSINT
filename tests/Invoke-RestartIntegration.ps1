[CmdletBinding()]
param([string]$TestRoot=(Join-Path ([IO.Path]::GetTempPath()) ('YTOSINT restart test '+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Logging','Core','Process','Dependencies','Gui')){
    Import-Module (Join-Path $project "src/Corpus.$module.psm1") -Force -Global
}
$null=New-CorpusContext $TestRoot
Write-CorpusJson (Join-Path $TestRoot config.json) @{subjects=@()}
$ticket=Start-CorpusRestart $TestRoot -SmokeTest
try {
    if($ticket.Process.WaitForExit(1000)){throw 'Relaunch exited before the old window released it.'}
    [IO.File]::WriteAllText($ticket.SignalPath,'ready')
    if(-not $ticket.Process.WaitForExit(30000)){throw 'Relaunched GUI smoke test timed out.'}
    if($ticket.Process.ExitCode -ne 0){throw "Relaunched GUI failed (exit $($ticket.Process.ExitCode))."}
    if(Test-Path $ticket.SignalPath){throw 'Relaunched process did not consume the close signal.'}
    if(-not (Test-Path (Join-Path $TestRoot config.json))){throw 'Relaunched GUI did not retain the corpus root.'}
    Write-Host 'PASS: fresh PowerShell process waited for window closure, reopened the same corpus, and completed WPF startup.'
} finally {if(-not $ticket.Process.HasExited){$ticket.Process.Kill()};$ticket.Process.Dispose()}
