Set-StrictMode -Version 2
$script:DependencyNames=@('yt-dlp','FFmpeg','Deno','ImportExcel')

function Get-CorpusDependencySettings {
    param([string]$Root)
    $settings=Read-CorpusJson (Join-Path $Root 'data/dependencies/settings.json')
    if(-not $settings){$settings=[pscustomobject]@{YtDlpChannel='stable';ImportExcelPath=''}}
    if($settings.YtDlpChannel -notin @('stable','nightly')){throw 'Invalid saved yt-dlp release channel.'}
    return $settings
}

function Enter-CorpusDependencyLock {
    param([switch]$Commit)
    # Shared by all YT-OSINT corpora in this Windows session. No waiting on the UI thread.
    $mutexName=if($Commit){'Local\YTOSINT-DependencyCommit'}else{'Local\YTOSINT-DependencyMaintenance'}
    $mutex=[Threading.Mutex]::new($false,$mutexName)
    try {
        try {$acquired=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$acquired=$true}
        if(-not $acquired){throw 'Another YT-OSINT process is using or updating dependencies. Retry when it is idle.'}
        return $mutex
    } catch {$mutex.Dispose();throw}
}

function Get-CorpusFileDigest {
    param([string]$Path,[ValidateSet('SHA256','SHA512')][string]$Algorithm='SHA256',[switch]$Base64)
    $hash=[Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    $stream=[IO.File]::OpenRead($Path)
    try {
        $bytes=$hash.ComputeHash($stream)
        if($Base64){return [Convert]::ToBase64String($bytes)}
        return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
    } finally {$stream.Dispose();$hash.Dispose()}
}

function Get-CorpusDependencyText {
    param([string]$Url)
    if(([uri]$Url).Scheme -ne 'https'){throw 'Dependency metadata requires HTTPS.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $response=Invoke-WebRequest -Uri $Url -UseBasicParsing -Headers @{'User-Agent'='YT-OSINT'} -TimeoutSec 30 -ErrorAction Stop
    if($response.Content -is [byte[]]){return [Text.Encoding]::UTF8.GetString($response.Content)}
    return [string]$response.Content
}

function Get-CorpusDependencyRelease {
    param([ValidateSet('yt-dlp','FFmpeg','Deno','ImportExcel')][string]$Name,
          [ValidateSet('stable','nightly')][string]$Channel='stable')
    if($Name -eq 'ImportExcel') {
        $url="https://www.powershellgallery.com/api/v2/Packages?`$filter=Id%20eq%20'ImportExcel'%20and%20IsLatestVersion&`$select=Version,PackageHash,PackageHashAlgorithm"
        [xml]$feed=Get-CorpusDependencyText $url
        $properties=@($feed.SelectNodes("//*[local-name()='properties']"))
        if($properties.Count -ne 1){throw 'Gallery returned an ambiguous ImportExcel release.'}
        $p=$properties[0]
        if($p.Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$' -or $p.PackageHashAlgorithm -ne 'SHA512' -or -not $p.PackageHash){throw 'Gallery release is missing a supported version or SHA512 package hash.'}
        return [pscustomobject]@{Name=$Name;Version=[string]$p.Version;Channel='stable';Provider='PowerShell Gallery';Url="https://www.powershellgallery.com/api/v2/package/ImportExcel/$($p.Version)";Hash=[string]$p.PackageHash;Algorithm='SHA512';Base64=$true;FileName='ImportExcel.nupkg'}
    }
    if($Name -eq 'FFmpeg') {
        $base='https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        $version=(Get-CorpusDependencyText ($base+'.ver')).Trim()
        $hash=((Get-CorpusDependencyText ($base+'.sha256')).Trim() -split '\s+')[0]
        if($version -notmatch '^\d+\.\d+(?:\.\d+)?$' -or $hash -notmatch '^[a-fA-F0-9]{64}$'){throw 'FFmpeg provider returned invalid release metadata.'}
        return [pscustomobject]@{Name=$Name;Version=$version;Channel='release';Provider='gyan.dev essentials release';Url=$base;Hash=$hash;Algorithm='SHA256';Base64=$false;FileName='ffmpeg.zip'}
    }
    $repo=if($Name -eq 'Deno'){'denoland/deno'}elseif($Channel -eq 'nightly'){'yt-dlp/yt-dlp-nightly-builds'}else{'yt-dlp/yt-dlp'}
    $assetName=if($Name -eq 'Deno'){'deno-x86_64-pc-windows-msvc.zip'}else{'yt-dlp.exe'}
    $release=(Get-CorpusDependencyText "https://api.github.com/repos/$repo/releases/latest") | ConvertFrom-Json
    $assets=@($release.assets | Where-Object name -eq $assetName)
    if($assets.Count -ne 1){throw "Release is missing $assetName."}
    $asset=$assets[0]
    $digest=Get-CorpusProperty $asset digest ''
    if($digest -notmatch '^sha256:([a-fA-F0-9]{64})$'){throw "GitHub release lacks a SHA256 digest for $assetName; refusing an unverified update."}
    $hash=$Matches[1]
    $expected="https://github.com/$repo/releases/download/$($release.tag_name)/$assetName"
    if($asset.browser_download_url -cne $expected){throw 'Release asset URL does not match the expected upstream repository.'}
    $version=([string]$release.tag_name).TrimStart('v')
    if($version -notmatch '^\d+(?:\.\d+){1,3}$'){throw 'Release version is not recognized.'}
    return [pscustomobject]@{Name=$Name;Version=$version;Channel=$(if($Name -eq 'Deno'){'stable'}else{$Channel});Provider=$repo;Url=$expected;Hash=$hash;Algorithm='SHA256';Base64=$false;FileName=$assetName}
}

function Get-CorpusNativeVersion {
    param($Context,[string]$Path,[string]$Name)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){return ''}
    $arg=if($Name -in @('ffmpeg','ffprobe')){'-version'}else{'--version'}
    $r=Invoke-CorpusProcess $Context $Path @($arg) -TimeoutSeconds 30 -Quiet
    if($r.ExitCode -ne 0){throw "$Name version check failed (exit $($r.ExitCode))."}
    $line=($r.StdOut -split '\r?\n')[0].Trim()
    $pattern=if($Name -in @('ffmpeg','ffprobe')){'^(?:ffmpeg|ffprobe) version \S+'}elseif($Name -eq 'deno'){'^deno \d+\.\d+'}else{'^\d{4}\.\d{2}\.\d{2}'}
    if($line -notmatch $pattern){throw "$Name returned an unrecognized version."}
    return $line
}

function Get-CorpusDependencyInstalled {
    param($Context,[string]$Name)
    if($Name -eq 'ImportExcel') {
        $settings=Get-CorpusDependencySettings $Context.Root
        if($settings.ImportExcelPath){
            if(-not (Test-Path -LiteralPath $settings.ImportExcelPath)){throw 'The selected ImportExcel module is missing. Reinstall it from Dependencies.'}
            $module=Test-ModuleManifest -Path $settings.ImportExcelPath -ErrorAction Stop
        } else {$module=Get-Module -ListAvailable ImportExcel | Sort-Object Version -Descending | Select-Object -First 1}
        return [pscustomobject]@{Version=$(if($module){$module.Version.ToString()}else{''});Path=$(if($module){$module.Path}else{'CurrentUser module directory'});Channel='stable'}
    }
    $file=if($Name -eq 'yt-dlp'){'yt-dlp.exe'}elseif($Name -eq 'FFmpeg'){'ffmpeg.exe'}else{'deno.exe'}
    $path=Join-Path $env:SystemRoot $file
    $line=Get-CorpusNativeVersion $Context $path ([IO.Path]::GetFileNameWithoutExtension($file))
    $channel='stable'
    if($Name -eq 'FFmpeg') {
        $probe=Get-CorpusNativeVersion $Context (Join-Path $env:SystemRoot 'ffprobe.exe') ffprobe
        $version=if($line -match '^ffmpeg version (\S+)'){$Matches[1]}else{''}
        $probeVersion=if($probe -match '^ffprobe version (\S+)'){$Matches[1]}else{''}
        if($version -ne $probeVersion){return [pscustomobject]@{Version="$version / $probeVersion (mismatched pair)";Path="$path + ffprobe.exe";Channel='mixed'}}
        $channel=if($version -match 'git'){'git snapshot'}elseif($version -match 'essentials_build'){'release'}else{'unmanaged build'}
    } elseif($Name -eq 'Deno') {$version=if($line -match '^deno (\S+)'){$Matches[1]}else{''}}
    else {$version=$line;if($version -match '^\d{4}\.\d{2}\.\d{2}\.\d+'){$channel='nightly'}}
    return [pscustomobject]@{Version=$version;Path=$path;Channel=$channel}
}

function Compare-CorpusDependencyVersion {
    param([string]$Installed,[string]$Available,[string]$InstalledChannel,[string]$TargetChannel)
    if(-not $Installed){return 'Missing'}
    if($InstalledChannel -ne $TargetChannel){return 'Different channel / build'}
    $a=$Installed -replace '-essentials_build.*$',''
    $a=$a -replace '^v',''
    if($a -notmatch '^\d+(?:\.\d+){1,3}$'){return 'Different channel / build'}
    if([version]$a -lt [version]$Available){return 'Update available'}
    if([version]$a -gt [version]$Available){return 'Installed newer'}
    return 'Up to date'
}

function Get-CorpusDependencyRecovery {
    $base=Join-Path $env:SystemRoot 'YT-OSINT-Updates/results'
    if(Test-Path -LiteralPath $base){
        foreach($file in Get-ChildItem $base -Filter '*.json' -ErrorAction Stop){
            $journal=Read-CorpusJson $file.FullName
            if($journal.Status -in @('Committing','RollbackFailed')){$journal}
        }
    }
}

function Get-CorpusDependencyStatus {
    param($Context,[ValidateSet('stable','nightly')][string]$Channel='stable',[switch]$Force)
    $lock=Enter-CorpusDependencyLock
    $commitLock=$null
    try {
        $commitLock=Enter-CorpusDependencyLock -Commit
        $cachePath=Join-Path $Context.Root 'data/dependencies/checks.json'
        $cache=@(Read-CorpusJson $cachePath @())
        $pending=@(Get-CorpusDependencyRecovery)
        $rows=@()
        foreach($name in $script:DependencyNames){
            Test-CorpusCancellation $Context
            Set-CorpusProgress $Context 'Checking dependencies' $name 0 0
            $row=[pscustomobject]@{Name=$name;InstalledVersion='';Path='';InstalledChannel='';AvailableVersion='';Provider='';Channel=$(if($name -eq 'yt-dlp'){$Channel}else{'stable'});LastCheck='';Status='Unknown';Detail='';CanUpdate=$false}
            try {
                $local=Get-CorpusDependencyInstalled $Context $name
                $row.InstalledVersion=$local.Version;$row.Path=$local.Path;$row.InstalledChannel=$local.Channel
            } catch {$row.Detail=$_.Exception.Message}
            $cached=@($cache | Where-Object {$_.Name -eq $name -and $_.RequestedChannel -eq $Channel})
            $remote=$null;$remoteError='';$checked=[datetime]::UtcNow.ToString('o')
            if(-not $Force -and $cached.Count -and ([datetime]::UtcNow - [datetime]$cached[0].CheckedAt).TotalHours -ge 0 -and ([datetime]::UtcNow - [datetime]$cached[0].CheckedAt).TotalHours -lt 24){
                $remote=$cached[0].Release;$remoteError=$cached[0].Error;$checked=$cached[0].CheckedAt
            } else {
                try {$remote=Get-CorpusDependencyRelease $name $Channel} catch {$remoteError=$_.Exception.Message}
            }
            $row.LastCheck=$checked
            $cache=@($cache | Where-Object {$_.Name -ne $name})+[pscustomobject]@{Name=$name;RequestedChannel=$Channel;CheckedAt=$checked;Release=$remote;Error=$remoteError}
            if($remote){
                $row.AvailableVersion=$remote.Version;$row.Provider=$remote.Provider;$row.Channel=$remote.Channel
                if(-not $row.Detail){$row.Status=Compare-CorpusDependencyVersion $row.InstalledVersion $remote.Version $row.InstalledChannel $remote.Channel}
                $row.CanUpdate=($row.Status -in @('Missing','Update available','Different channel / build','Unknown'))
            }
            if($remoteError){$row.Detail=($row.Detail+' '+$remoteError).Trim();$row.Status='Unknown';$row.CanUpdate=$false}
            if(@($pending | Where-Object Name -eq $name).Count){$row.Status='Recovery required';$row.Detail='An interrupted native update must be recovered before dependencies are used.';$row.CanUpdate=$false}
            Write-CorpusLog $Context $(if($row.Status -eq 'Unknown'){'Warning'}else{'Info'}) Dependencies $name "$name`: $($row.Status). $($row.Detail)"
            $rows+=$row
        }
        Write-CorpusJson $cachePath $cache
        return $rows
    } finally {if($commitLock){$commitLock.ReleaseMutex();$commitLock.Dispose()};$lock.ReleaseMutex();$lock.Dispose()}
}

function Receive-CorpusDependency {
    param($Context,[string]$Url,[string]$Path)
    if(([uri]$Url).Scheme -ne 'https'){throw 'Dependency downloads require HTTPS.'}
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    $client=[Net.WebClient]::new();$client.Headers['User-Agent']='YT-OSINT'
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try {
        $task=$client.DownloadFileTaskAsync([uri]$Url,$Path)
        while(-not $task.IsCompleted){
            Test-CorpusCancellation $Context
            if($watch.Elapsed.TotalMinutes -gt 15){throw 'Dependency download timed out.'}
            Start-Sleep -Milliseconds 100
        }
        $task.GetAwaiter().GetResult()
    } finally {$client.CancelAsync();$client.Dispose()}
}

function Assert-CorpusDependencyDigest {
    param([string]$Path,$Release)
    $actual=Get-CorpusFileDigest $Path $Release.Algorithm -Base64:([bool]$Release.Base64)
    if($actual -cne $Release.Hash.ToLowerInvariant() -and $Release.Algorithm -eq 'SHA256'){throw 'Downloaded dependency failed SHA256 verification.'}
    if($Release.Algorithm -eq 'SHA512' -and $actual -cne $Release.Hash){throw 'Downloaded module failed SHA512 verification.'}
}

function Expand-CorpusDependency {
    param([string]$Archive,[string]$Destination,[string]$Name)
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    if($Name -eq 'yt-dlp'){[IO.File]::Copy($Archive,(Join-Path $Destination 'yt-dlp.exe'),$false);return}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if($Name -in @('FFmpeg','Deno')){
            $required=if($Name -eq 'FFmpeg'){@('ffmpeg.exe','ffprobe.exe')}else{@('deno.exe')}
            foreach($file in $required){
                $entries=@($zip.Entries | Where-Object {($_.FullName -split '/')[-1] -ceq $file})
                if($entries.Count -ne 1){throw "Archive must contain exactly one $file."}
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],(Join-Path $Destination $file),$false)
            }
        } else {
            $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
            foreach($entry in $zip.Entries){
                $target=[IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
                if(-not $target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe path in module archive.'}
                if($entry.FullName -match '^(?:_rels/|package/|\[Content_Types\]\.xml$)' -or $entry.FullName -match '\.nuspec$'){continue}
                if(-not $entry.Name){continue}
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
            }
            if(-not (Test-Path (Join-Path $Destination 'ImportExcel.psd1'))){throw 'ImportExcel archive has no module manifest.'}
        }
    } finally {$zip.Dispose()}
}

function Test-CorpusDependencyCandidate {
    param($Context,[string]$Name,[string]$Directory,[string]$ExpectedVersion)
    if($Name -eq 'ImportExcel') {
        $scriptPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-DependencyModule.ps1'
        $r=Invoke-CorpusProcess $Context (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$scriptPath,'-ModulePath',(Join-Path $Directory 'ImportExcel.psd1'),'-ExpectedVersion',$ExpectedVersion) -Quiet
        if($r.ExitCode){throw "ImportExcel verification failed: $($r.StdErr)"}
    } else {
        $files=if($Name -eq 'FFmpeg'){@('ffmpeg','ffprobe')}elseif($Name -eq 'yt-dlp'){@('yt-dlp')}else{@('deno')}
        foreach($file in $files){
            $version=Get-CorpusNativeVersion $Context (Join-Path $Directory "$file.exe") $file
            if($version -notmatch ('(?<!\d)'+[regex]::Escape($ExpectedVersion)+'(?![\d.])')){throw "$file version does not match the selected release $ExpectedVersion."}
        }
    }
}

function Save-CorpusDependencyPlan {
    param($Context,[string]$Name,[string]$Channel='stable',[string]$ExpectedVersion='')
    $release=Get-CorpusDependencyRelease $Name $Channel
    if($ExpectedVersion -and $release.Version -ne $ExpectedVersion){throw "$Name release changed since the last check. Check again before updating."}
    $stage=Join-Path $Context.Root ('data/dependencies/staging/'+[guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    Set-CorpusProgress $Context 'Downloading update' "$Name $($release.Version)" 0 0
    $archive=Join-Path $stage $release.FileName
    Receive-CorpusDependency $Context $release.Url $archive
    Assert-CorpusDependencyDigest $archive $release
    Test-CorpusCancellation $Context
    Set-CorpusProgress $Context 'Verifying update' $Name 0 0
    $candidate=Join-Path $stage 'candidate'
    Expand-CorpusDependency $archive $candidate $Name
    Test-CorpusDependencyCandidate $Context $Name $candidate $release.Version
    $names=if($Name -eq 'FFmpeg'){@('ffmpeg.exe','ffprobe.exe')}elseif($Name -eq 'Deno'){@('deno.exe')}elseif($Name -eq 'yt-dlp'){@('yt-dlp.exe')}else{@()}
    $baseline=@(foreach($file in $names){$target=Join-Path $env:SystemRoot $file;[pscustomobject]@{Name=$file;Hash=$(if(Test-Path $target){Get-CorpusFileDigest $target}else{''})}})
    $plan=[pscustomobject]@{Name=$Name;Channel=$Channel;Version=$release.Version;Release=$release;Archive=$archive;Candidate=$candidate;Baseline=$baseline;Root=$Context.Root;Stage=$stage}
    Write-CorpusJson (Join-Path $stage 'plan.json') $plan
    Write-CorpusLog $Context Info Dependencies $Name "Verified $Name $($release.Version) from $($release.Url)."
    return $plan
}

function Get-CorpusModuleInstallRoot {
    param($Context)
    return Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell/Modules/ImportExcel'
}

function Install-CorpusDependencyModule {
    param($Context,$Plan)
    $base=Get-CorpusModuleInstallRoot $Context
    $destination=Join-Path $base $Plan.Version
    if(Test-Path $destination){throw "ImportExcel $($Plan.Version) already exists at $destination. It was not overwritten."}
    [IO.Directory]::CreateDirectory($base) | Out-Null
    # Stage on the same volume as the module location; Directory.Move commits the complete version.
    $temp=Join-Path $base ('.YTOSINT-'+[guid]::NewGuid().ToString('N'))
    $installed=$false
    try {
        Copy-Item -LiteralPath $Plan.Candidate -Destination $temp -Recurse -ErrorAction Stop
        Test-CorpusDependencyCandidate $Context ImportExcel $temp $Plan.Version
        Test-CorpusCancellation $Context
        [IO.Directory]::Move($temp,$destination);$installed=$true
        Test-CorpusDependencyCandidate $Context ImportExcel $destination $Plan.Version
        $settings=Get-CorpusDependencySettings $Context.Root
        $previous=$settings.ImportExcelPath
        $settings.ImportExcelPath=Join-Path $destination 'ImportExcel.psd1'
        Write-CorpusJson (Join-Path $Plan.Stage 'module-backup.json') @{PreviousModulePath=$previous;InstalledPath=$settings.ImportExcelPath;Version=$Plan.Version}
        Write-CorpusJson (Join-Path $Context.Root 'data/dependencies/settings.json') $settings
    } catch {
        if($installed){Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop}
        throw
    } finally {if(Test-Path $temp){Remove-Item -LiteralPath $temp -Recurse -Force}}
}

function Invoke-CorpusDependencyUpdate {
    param($Context,[object[]]$Selection,[ValidateSet('stable','nightly')][string]$Channel='stable')
    if($null -eq $Selection -or -not $Selection.Count){throw 'Select dependencies to update first.'}
    $lock=Enter-CorpusDependencyLock
    try {
        if(@(Get-CorpusDependencyRecovery).Count){throw 'Recover the interrupted native update before installing further updates.'}
        $results=@()
        foreach($selected in $Selection){
            if($selected.Name -notin $script:DependencyNames){throw 'Unrecognized dependency selection.'}
            Test-CorpusCancellation $Context
            $plan=Save-CorpusDependencyPlan $Context $selected.Name $Channel $selected.AvailableVersion
            Test-CorpusCancellation $Context
            Set-CorpusProgress $Context 'Installing verified update' $plan.Name 0 0
            if($Context.Shared){$Context.Shared.CommitInProgress=$true}
            if($plan.Name -eq 'ImportExcel') {Install-CorpusDependencyModule $Context $plan}
            else {
                $helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Dependencies.ps1'
                $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-NativeCommit','-PlanPath',(Join-Path $plan.Stage 'plan.json'))
                $quoted=@($args | ForEach-Object {[YouTubeCorpus.ProcessRunner]::Quote($_)}) -join ' '
                $process=$null
                try {
                    $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $quoted -Verb RunAs -WindowStyle Hidden -PassThru
                    # Commit/rollback is deliberately non-cancellable. The UI continues pumping messages.
                    while(-not $process.WaitForExit(200)){}
                    $result=Read-CorpusJson (Join-Path $env:SystemRoot ('YT-OSINT-Updates/results/'+(Split-Path $plan.Stage -Leaf)+'.json'))
                    if($process.ExitCode -ne 0 -or -not $result -or $result.Status -ne 'Success'){
                        $reason=if($result){$result.Message}else{'No successful result was returned.'}
                        throw "Native update failed: $reason"
                    }
                } catch {throw "Could not update $($plan.Name). UAC approval is required. $($_.Exception.Message)"}
                finally {if($process){$process.Dispose()}}
            }
            if($Context.Shared){$Context.Shared.CommitInProgress=$false}
            if($plan.Name -eq 'yt-dlp'){
                $settings=Get-CorpusDependencySettings $Context.Root;$settings.YtDlpChannel=$Channel
                Write-CorpusJson (Join-Path $Context.Root 'data/dependencies/settings.json') $settings
            }
            Write-CorpusLog $Context Info Dependencies $plan.Name "Updated $($plan.Name) to $($plan.Version). Restart YT-OSINT before resuming work."
            $results+=[pscustomobject]@{Name=$plan.Name;Version=$plan.Version;Status='Updated';RestartRequired=$true}
        }
        return $results
    } finally {
        # Invalidate cached release checks after success or failure, without touching sources or corpus data.
        $cache=Join-Path $Context.Root 'data/dependencies/checks.json'
        if(Test-Path $cache){Remove-Item -LiteralPath $cache -Force}
        $lock.ReleaseMutex();$lock.Dispose()
    }
}
Export-ModuleMember -Function *-Corpus*

function Repair-CorpusDependencies {
    param($Context)
    $lock=Enter-CorpusDependencyLock
    $process=$null
    try {
        $id=[guid]::NewGuid().ToString('N')
        $helper=Join-Path (Split-Path $PSScriptRoot -Parent) 'Update-Dependencies.ps1'
        $args=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,'-RecoverNative','-ResultId',$id)
        $quoted=@($args | ForEach-Object {[YouTubeCorpus.ProcessRunner]::Quote($_)}) -join ' '
        $process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -ArgumentList $quoted -Verb RunAs -WindowStyle Hidden -PassThru
        while(-not $process.WaitForExit(200)){}
        $result=Read-CorpusJson (Join-Path $env:SystemRoot "YT-OSINT-Updates/results/$id.json")
        if($process.ExitCode -ne 0 -or -not $result -or $result.Status -ne 'Success'){throw 'Dependency recovery did not complete. See the protected transaction journals.'}
        Write-CorpusLog $Context Info Dependencies '' $result.Message
        return $result
    } finally {if($process){$process.Dispose()};$lock.ReleaseMutex();$lock.Dispose()}
}
Export-ModuleMember -Function *-Corpus*
