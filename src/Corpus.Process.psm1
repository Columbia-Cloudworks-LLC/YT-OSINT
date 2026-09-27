Set-StrictMode -Version 2
if(-not ('YouTubeCorpus.ProcessRunner' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Corpus.Process.cs') }
function Test-CorpusMembersOnlyMessage {
    param([string]$Message)
    return $Message -match "(?i)(Join this channel to get access to members-only content|This video is available to this channel's members(?: on level| only|\.|$)|This video is only available (?:to|for) (?:channel )?members)"
}
function Invoke-CorpusProcess {
    param($Context,[string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds=300,[switch]$Quiet,[switch]$StopOnRateLimit,[switch]$AllowMembersOnly)
    $runner=[YouTubeCorpus.ProcessRunner]::new(); $watch=[Diagnostics.Stopwatch]::StartNew()
    # Never log full URLs/arguments: caption URLs can contain signed tokens.
    Write-CorpusLog $Context Info Process ([IO.Path]::GetFileName($Executable)) "Starting $([IO.Path]::GetFileName($Executable)) ($($Arguments.Count) arguments)."
    try {
        Test-CorpusCancellation $Context
        $runner.Start($Executable,$Arguments)
        while(-not $runner.Process.WaitForExit(100)) {
            Test-CorpusCancellation $Context
            if($watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw "Process timed out after $TimeoutSeconds seconds: $Executable" }
            if($StopOnRateLimit -and $runner.Error -match '(?i)HTTP(?: Error| error| status(?: code)?)?[: ]+429\b|\b429:\s*Too Many Requests'){
                $runner.Cancel();$runner.Process.WaitForExit()
                return [pscustomobject]@{StdOut=$runner.Output;StdErr=$runner.Error;ExitCode=429;RateLimited=$true}
            }
            $line=''
            while($runner.Lines.TryDequeue([ref]$line)) {
                if(-not $Quiet -and $Context.Shared) { $Context.Shared.Messages.Enqueue(($line -replace 'https?://\S+','[URL]')) }
            }
        }
        $runner.Process.WaitForExit()
        $result=[pscustomobject]@{StdOut=$runner.Output;StdErr=$runner.Error;ExitCode=$runner.Process.ExitCode}
        if($AllowMembersOnly -and $result.ExitCode -ne 0 -and (Test-CorpusMembersOnlyMessage $result.StdErr)){
            $result | Add-Member NoteProperty MembersOnly $true
            Write-CorpusLog $Context Info Process '' 'Members-only video; skipping.'
            return $result
        }
        if($result.StdErr) { Write-CorpusLog $Context $(if($result.ExitCode){'Error'}else{'Warning'}) Process '' ($result.StdErr -replace 'https?://\S+','[URL]') }
        return $result
    } finally { $runner.Dispose() }
}
Export-ModuleMember -Function Invoke-CorpusProcess,Test-CorpusMembersOnlyMessage
