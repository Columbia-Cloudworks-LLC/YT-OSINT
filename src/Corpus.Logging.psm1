Set-StrictMode -Version 2
function Write-CorpusLog {
    param($Context, [string]$Severity, [string]$Operation, [string]$Identifier, [string]$Message, [string]$Detail = '')
    $entry = [ordered]@{ Timestamp=[datetime]::UtcNow.ToString('o'); Severity=$Severity; Operation=$Operation; Identifier=$Identifier; Message=$Message; Detail=$Detail }
    $line = $entry | ConvertTo-Json -Compress
    [IO.File]::AppendAllText($Context.LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    if ($Context.Shared) { $Context.Shared.Messages.Enqueue("[$Severity] $Message") }
}
function Set-CorpusProgress {
    param($Context, [string]$Stage, [string]$Item='', [int]$Current=-1, [int]$Total=-1)
    if($Current -lt 0 -and $Context.Shared -and $Context.Shared.Progress) { $Current=$Context.Shared.Progress.Current }
    if($Total -lt 0 -and $Context.Shared -and $Context.Shared.Progress) { $Total=$Context.Shared.Progress.Total }
    if ($Context.Shared) { $Context.Shared.Progress = [pscustomobject]@{ Stage=$Stage; Item=$Item; Current=$Current; Total=$Total } }
}
function Test-CorpusCancellation {
    param($Context)
    if($Context.Shared -and $Context.Shared.ContainsKey('ActiveSyncId') -and $Context.Shared.ActiveSyncId -and $Context.Shared.ContainsKey('CancelSyncId') -and $Context.Shared.ActiveSyncId -eq $Context.Shared.CancelSyncId){throw [OperationCanceledException]::new('Channel discovery cancelled.')}
    if ($Context.Shared -and $Context.Shared.Cancel) { throw [OperationCanceledException]::new('Operation cancelled; completed items have been preserved.') }
}
Export-ModuleMember -Function *-Corpus*
