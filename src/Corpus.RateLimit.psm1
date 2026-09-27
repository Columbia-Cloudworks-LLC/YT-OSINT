Set-StrictMode -Version 2
function Get-CorpusRequestTime { return [datetime]::UtcNow }
function ConvertTo-CorpusRequestTime { param([string]$Value) return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
function Get-CorpusRequestStatePath { return Join-Path (Get-CorpusDependencyHome) 'youtube-requests.json' }
function Read-CorpusRequestState {
    $state=Read-CorpusJson (Get-CorpusRequestStatePath)
    if(-not $state){$state=[pscustomobject]@{RateLimitCount=0;ResumeAfter='';NextRequestAt='';Halted=$false}}
    return $state
}
function Test-CorpusRateLimitError {
    param($Exception)
    while($Exception){if($Exception.Data.Contains('YouTubeRateLimited')){return $true};$Exception=$Exception.InnerException}
    return $false
}
function Stop-CorpusRateLimit {
    $error=[InvalidOperationException]::new('YouTube rate limit persists. Sync stopped; saved work is safe. Wait at least 8 minutes before starting another sync.')
    $error.Data['YouTubeRateLimited']=$true
    throw $error
}
function Wait-CorpusRequestTick { Start-Sleep -Milliseconds 200 }
function Wait-CorpusYouTubeRequest {
    param($Context,$State)
    if($State.Halted){
        if((Get-CorpusRequestTime) -lt (ConvertTo-CorpusRequestTime $State.ResumeAfter)){Stop-CorpusRateLimit}
        # A new user-initiated run after the final cooldown gets a fresh retry budget.
        $State.Halted=$false;$State.RateLimitCount=0;$State.ResumeAfter=''
        Write-CorpusJson (Get-CorpusRequestStatePath) $State
    }
    $lastLabel=''
    while($true){
        Test-CorpusCancellation $Context
        $now=Get-CorpusRequestTime
        $cooldown=if($State.ResumeAfter){[Math]::Ceiling(((ConvertTo-CorpusRequestTime $State.ResumeAfter)-$now).TotalSeconds)}else{0}
        $spacing=if($State.NextRequestAt){[Math]::Ceiling(((ConvertTo-CorpusRequestTime $State.NextRequestAt)-$now).TotalSeconds)}else{0}
        if($cooldown -le 0 -and $spacing -le 0){return}
        $label=if($cooldown -gt 0){"YouTube rate limit - paused (resuming in $($cooldown)s)"}else{"Spacing YouTube requests ($($spacing)s)"}
        if($label -ne $lastLabel){Set-CorpusProgress $Context $label '';$lastLabel=$label}
        Wait-CorpusRequestTick
    }
}
function Invoke-CorpusYouTubeProcess {
    param($Context,[string[]]$Arguments,[ValidateSet('Metadata','Subtitle','Enumeration')][string]$Kind='Metadata',[int]$TimeoutSeconds=300,[switch]$Quiet)
    $state=Read-CorpusRequestState
    while($true){
        Wait-CorpusYouTubeRequest $Context $state
        Test-CorpusCancellation $Context
        Set-CorpusProgress $Context "YouTube $($Kind.ToLowerInvariant())" ''
        # Persist a start reservation as well, so cancellation/restarts cannot bypass spacing.
        $state.NextRequestAt=(Get-CorpusRequestTime).AddSeconds(10).ToString('o')
        Write-CorpusJson (Get-CorpusRequestStatePath) $state
        $result=Invoke-CorpusProcess $Context (Join-Path (Get-CorpusNativeRoot) 'yt-dlp.exe') $Arguments -TimeoutSeconds $TimeoutSeconds -Quiet:$Quiet -StopOnRateLimit
        $state.NextRequestAt=(Get-CorpusRequestTime).AddSeconds(10).ToString('o')
        $limited=([bool](Get-CorpusProperty $result RateLimited $false) -or $result.StdErr -match '(?i)HTTP(?: Error| error| status(?: code)?)?[: ]+429\b|\b429:\s*Too Many Requests')
        if(-not $limited){
            # Metadata success must not reset a failing subtitle request's retry budget.
            if($Kind -eq 'Subtitle' -and $result.ExitCode -eq 0){$state.RateLimitCount=0;$state.ResumeAfter='';$state.Halted=$false}
            Write-CorpusJson (Get-CorpusRequestStatePath) $state
            return $result
        }
        $state.RateLimitCount=[int]$state.RateLimitCount+1
        $delay=@(120,240,480)[[Math]::Min($state.RateLimitCount-1,2)]
        $state.ResumeAfter=(Get-CorpusRequestTime).AddSeconds($delay).ToString('o')
        $state.Halted=($state.RateLimitCount -gt 3)
        Write-CorpusJson (Get-CorpusRequestStatePath) $state
        if($state.Halted){Stop-CorpusRateLimit}
        Write-CorpusLog $Context Warning RateLimit '' "YouTube rate limit - pausing all requests for $delay seconds (retry $($state.RateLimitCount) of 3)."
    }
}
Export-ModuleMember -Function *-Corpus*
