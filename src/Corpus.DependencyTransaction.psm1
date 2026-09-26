Set-StrictMode -Version 2
function Get-CorpusNativeNames {
    param([ValidateSet('yt-dlp','FFmpeg','Deno')][string]$Name)
    switch($Name){'yt-dlp'{return @('yt-dlp.exe')};'FFmpeg'{return @('ffmpeg.exe','ffprobe.exe')};'Deno'{return @('deno.exe')}}
}

function Restore-CorpusNativeTransaction {
    param($Context,[string]$JournalPath,[string]$TargetRoot,[string]$TransactionRoot)
    $journal=Read-CorpusJson $JournalPath
    if($journal.Status -notin @('Committing','RollbackFailed')){return}
    $allowed=@(Get-CorpusNativeNames $journal.Name)
    try {
        foreach($entry in @($journal.Entries)[($journal.Entries.Count-1)..0]){
            if($entry.Name -notin $allowed){throw 'Invalid file name in recovery journal.'}
            $target=Join-Path $TargetRoot $entry.Name
            $current=if(Test-Path -LiteralPath $target){Get-CorpusFileDigest $target}else{''}
            if($current -eq $entry.BeforeHash){continue}
            if($current -and $current -ne $entry.AfterHash){throw "$($entry.Name) changed outside this transaction. Refusing to overwrite it during recovery."}
            if($entry.Existed){
                $backup=Join-Path $TransactionRoot ('backup/'+$entry.Name)
                if((Get-CorpusFileDigest $backup) -ne $entry.BeforeHash){throw 'Backup checksum failed; manual recovery is required.'}
                $restore=Join-Path $TransactionRoot ('restore-'+$entry.Name)
                [IO.File]::Copy($backup,$restore,$true)
                if(Test-Path $target){[IO.File]::Replace($restore,$target,[NullString]::Value)}else{[IO.File]::Move($restore,$target)}
            } elseif(Test-Path $target){[IO.File]::Delete($target)}
        }
        $journal.Status='RolledBack';$journal.Message='Original binaries restored and verified.'
        Write-CorpusJson $JournalPath $journal
    } catch {
        $journal.Status='RollbackFailed';$journal.Message=$_.Exception.Message
        Write-CorpusJson $JournalPath $journal
        throw
    }
}

function Install-CorpusNativeTransaction {
    param($Context,[ValidateSet('yt-dlp','FFmpeg','Deno')][string]$Name,
          [string]$Candidate,[string]$Version,[string]$TargetRoot,[string]$TransactionRoot,
          [string]$JournalPath,[object[]]$Baseline)
    $files=@(Get-CorpusNativeNames $Name)
    $backupDir=Join-Path $TransactionRoot 'backup'
    [IO.Directory]::CreateDirectory($backupDir) | Out-Null
    Test-CorpusDependencyCandidate $Context $Name $Candidate $Version
    $entries=@()
    foreach($file in $files){
        $target=Join-Path $TargetRoot $file
        $exists=Test-Path -LiteralPath $target -PathType Leaf
        $before=if($exists){Get-CorpusFileDigest $target}else{''}
        $observed=@($Baseline | Where-Object Name -eq $file)
        if($observed.Count -ne 1 -or $observed[0].Hash -ne $before){throw "$file changed since this update was staged. Check again before updating."}
        if($exists){[IO.File]::Copy($target,(Join-Path $backupDir $file),$false)}
        $entries+=[pscustomobject]@{Name=$file;Existed=$exists;BeforeHash=$before;AfterHash=(Get-CorpusFileDigest (Join-Path $Candidate $file))}
    }
    $journal=[pscustomobject]@{Name=$Name;Version=$Version;Status='Committing';Message='Replacing verified binaries.';StartedAt=[datetime]::UtcNow.ToString('o');Entries=$entries;BackupDirectory=$backupDir}
    # Journal all members before replacing any. Recovery handles both untouched and replaced members.
    Write-CorpusJson $JournalPath $journal
    try {
        foreach($file in $files){
            $target=Join-Path $TargetRoot $file
            $source=Join-Path $Candidate $file
            if(Test-Path $target){[IO.File]::Replace($source,$target,[NullString]::Value)}else{[IO.File]::Move($source,$target)}
        }
        Test-CorpusDependencyCandidate $Context $Name $TargetRoot $Version
        foreach($entry in $entries){if((Get-CorpusFileDigest (Join-Path $TargetRoot $entry.Name)) -ne $entry.AfterHash){throw 'Installed dependency checksum changed during verification.'}}
        $journal.Status='Success';$journal.Message='Installed binaries passed version and checksum verification.'
        Write-CorpusJson $JournalPath $journal
    } catch {
        $reason=$_.Exception.Message
        try {Restore-CorpusNativeTransaction $Context $JournalPath $TargetRoot $TransactionRoot}
        catch {throw "Update failed: $reason. Automatic rollback also failed: $($_.Exception.Message). Recovery journal: $JournalPath"}
        throw "Update failed: $reason. Original binaries were restored."
    }
}
Export-ModuleMember -Function *-Corpus*
