Set-StrictMode -Version 2
function Get-CorpusUserSettingsPath {
    if(-not $env:LOCALAPPDATA){throw 'The Windows user profile is unavailable.'}
    Join-Path $env:LOCALAPPDATA 'YT-OSINT/settings.json'
}
function Get-CorpusUserSettings {
    param([string]$Path=(Get-CorpusUserSettingsPath))
    $settings=Read-CorpusJson $Path
    if(-not $settings){return [pscustomobject]@{CorpusRoot='';StaleDays=7}}
    $days=0
    if(-not [int]::TryParse([string](Get-CorpusProperty $settings StaleDays 7),[ref]$days) -or $days -lt 1 -or $days -gt 3650){$days=7}
    [pscustomobject]@{CorpusRoot=[string](Get-CorpusProperty $settings CorpusRoot '');StaleDays=$days}
}
function Get-CorpusChannelIndicator {
    param($Channel,$Job,$Queue,[int]$StaleDays=7,[datetime]$Now=[datetime]::UtcNow)
    $last=Get-CorpusProperty $Channel LastSuccessfulSync ''
    $freshness='Never synced';$symbol='○'
    if($last){if(($Now.ToUniversalTime()-([datetime]$last).ToUniversalTime()).TotalDays -gt $StaleDays){$freshness='Stale';$symbol='◷'}else{$freshness='Up to date';$symbol='✓'}}
    $activity='';$locked=$false
    if($Job){
        $locked=$Job.Status -in @('Pending','Discovering','Downloading','Cancelling')
        if($locked){
            $running=@($Queue.Items | Where-Object {$Job.Id -in $_.JobIds -and $_.Status -eq 'Running'}).Count -gt 0
            $activity=if($Job.Status -eq 'Cancelling'){'Cancelling'}elseif($Job.Status -eq 'Discovering' -or $running){'Syncing'}elseif($Queue.Paused){'Paused'}else{'Queued'}
            if(Get-CorpusProperty $Job PartialImport $false){$activity+=' · Partial channel import'}
            $symbol=if($activity -like 'Syncing*'){'↻'}else{'◷'}
        }elseif(Get-CorpusProperty $Job PartialImport $false){$activity='Partial channel import';$symbol='◐'}
        elseif($Job.Status -in @('Partial','Failed','Cancelled')){$activity=$Job.Status;$symbol='!'}
    }elseif((Get-CorpusProperty $Channel Status '') -in @('Partial','Failed','Cancelled')){$activity=$Channel.Status;$symbol='!'}
    $label="$symbol $(if($activity){$activity+' · '})$freshness$(if($locked){' · 🔒'})"
    [pscustomobject]@{Label=$label;Freshness=$freshness;Locked=$locked;Hint="$(if($locked){'Editing locked while this channel has queued work. '})Last successful full sync: $(if($last){$last}else{'Never'}). Latest activity: $(if($activity){$activity}else{'Idle'}). Freshness threshold: $StaleDays days."}
}
function Resolve-CorpusStoragePath {
    param([string]$Path)
    $expanded=[Environment]::ExpandEnvironmentVariables($Path.Trim())
    if([string]::IsNullOrWhiteSpace($expanded) -or -not [IO.Path]::IsPathRooted($expanded) -or $expanded -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+)'){throw 'Enter an absolute Windows folder path.'}
    $full=[IO.Path]::GetFullPath($expanded).TrimEnd('\','/')
    if($full.Length -le 3){throw 'Choose a dedicated corpus folder, not a drive root.'}
    $cursor=$full
    while($cursor){
        if(Test-Path -LiteralPath $cursor){$entry=Get-Item -LiteralPath $cursor -Force;if(-not $entry.PSIsContainer -or ((Get-CorpusProperty $entry LinkType '') -in @('SymbolicLink','Junction'))){throw 'Choose a regular folder, without symbolic links or junctions.'}}
        $cursor=Split-Path -Parent $cursor
    }
    return $full
}
function Save-CorpusStorageSettings {
    param([string]$Root,[string]$Destination,[ValidateSet('Move','Switch')][string]$Mode,[ValidateRange(1,3650)][int]$StaleDays=7,[string]$SettingsPath=(Get-CorpusUserSettingsPath),$Shared=$null)
    $source=Resolve-CorpusStoragePath $Root;$target=Resolve-CorpusStoragePath $Destination
    $changed=-not [string]::Equals($source,$target,[StringComparison]::OrdinalIgnoreCase)
    if(-not $changed){Write-CorpusJson $SettingsPath ([ordered]@{CorpusRoot=$target;StaleDays=$StaleDays});return [pscustomobject]@{Root=$target;Changed=$false}}
    if($target.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase) -or $source.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Source and destination must be separate folders, not nested inside each other.'}
    $guards=[Collections.Generic.List[object]]::new();$dependency=$null;$commit=$null
    try {
        # Match the queue lock order. Acquiring these excludes other windows and CLI writers.
        $guards.Add((Enter-CorpusQueueRunner $source))
        $dependency=Enter-CorpusDependencyLock;$commit=Enter-CorpusDependencyLock -Commit
        $guards.Add([IO.File]::Open((Join-Path $source 'data/corpus.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
        $guards.Add((Enter-CorpusConfigLock $source))
        $null=Get-CorpusConfig $source
        $exists=Test-Path -LiteralPath $target
        $entries=@(if($exists){Get-ChildItem -LiteralPath $target -Force})
        if($Mode -eq 'Move' -and $entries.Count){throw 'Move requires an empty destination. Select a new or empty folder.'}
        if($Mode -eq 'Switch' -and $entries.Count){$null=Get-CorpusConfig $target}
        $null=[IO.Directory]::CreateDirectory($target)
        $probe=Join-Path $target ('.write-test-'+[guid]::NewGuid().ToString('N'))
        try{[IO.File]::WriteAllText($probe,'test')}finally{if([IO.File]::Exists($probe)){[IO.File]::Delete($probe)}}
        $guards.Add((Enter-CorpusQueueRunner $target))
        $guards.Add([IO.File]::Open((Join-Path $target 'data/corpus.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
        $guards.Add((Enter-CorpusConfigLock $target))
        if($Mode -eq 'Move'){
            [IO.File]::WriteAllText((Join-Path $target '.yt-osint-migration-incomplete'),'Copy in progress. Use the original corpus if this operation is interrupted.')
            $files=[Collections.Generic.List[object]]::new();$files.Add((Get-Item -LiteralPath (Join-Path $source 'config.json')))
            foreach($folder in @('data','output','logs')){
                $path=Join-Path $source $folder
                if(Test-Path -LiteralPath $path){
                    $all=@(Get-ChildItem -LiteralPath $path -Recurse -Force)
                    if(@($all | Where-Object {(Get-CorpusProperty $_ LinkType '') -in @('SymbolicLink','Junction')}).Count){throw 'Cannot move a corpus containing symbolic links or junctions.'}
                    foreach($file in $all){if(-not $file.PSIsContainer -and $file.FullName -notin @((Join-Path $source 'data/config.lock'),(Join-Path $source 'data/corpus.lock'),(Join-Path $source 'data/queue-runner.lock'))){$files.Add($file)}}
                }
            }
            $index=0
            foreach($file in $files){
                $relative=$file.FullName.Substring($source.Length+1);$copy=Join-Path $target $relative
                if($Shared){$Shared.Progress=@{Stage='Copying and verifying corpus';Item=$relative;Current=$index;Total=$files.Count}}
                $null=[IO.Directory]::CreateDirectory((Split-Path -Parent $copy))
                [IO.File]::Copy($file.FullName,$copy,$false)
                if((Get-CorpusFileDigest $file.FullName) -ne (Get-CorpusFileDigest $copy)){throw "Verification failed for $relative. The original corpus remains intact."}
                $index++
            }
        }elseif(-not $entries.Count){Write-CorpusJson (Join-Path $target 'config.json') ([ordered]@{schemaVersion=1;subjects=@();archivedSubjects=@()})}
        if($Mode -eq 'Move'){[IO.File]::Delete((Join-Path $target '.yt-osint-migration-incomplete'))}
        $null=Get-CorpusConfig $target
        $null=New-CorpusContext $target
        $queue=Get-CorpusQueue $target;$queue.Paused=$true
        Write-CorpusJson (Join-Path $target 'data/queue.json') $queue
        # Commit the preference only after all destination checks and verification succeed.
        Write-CorpusJson $SettingsPath ([ordered]@{CorpusRoot=$target;StaleDays=$StaleDays})
        return [pscustomobject]@{Root=$target;Changed=$true}
    } finally {
        for($i=$guards.Count-1;$i -ge 0;$i--){$guards[$i].Dispose()}
        if($commit){$commit.ReleaseMutex();$commit.Dispose()};if($dependency){$dependency.ReleaseMutex();$dependency.Dispose()}
    }
}
Export-ModuleMember -Function Get-CorpusUserSettingsPath,Get-CorpusUserSettings,Get-CorpusChannelIndicator,Save-CorpusStorageSettings,Resolve-CorpusStoragePath
