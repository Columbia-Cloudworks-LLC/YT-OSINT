[CmdletBinding()]
param([string]$Root='',[switch]$NativeOnly,[string]$ProgressPath='')
$ErrorActionPreference='Stop'
if(-not $Root){ $Root=Split-Path -Parent $MyInvocation.MyCommand.Path }
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$logDir=Join-Path $Root 'logs'; [IO.Directory]::CreateDirectory($logDir) | Out-Null
$log=Join-Path $logDir 'dependencies.jsonl'
function Write-DependencyEvent($Name,$Url,$Target,$Version,$Status,$Message) {
    $row=[ordered]@{Timestamp=[datetime]::UtcNow.ToString('o');Dependency=$Name;SourceUrl=$Url;TargetPath=$Target;Version=$Version;Status=$Status;Message=$Message}
    [IO.File]::AppendAllText($log,($row | ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
}
function Set-DependencyProgress([string]$Stage) {
    Write-Host $Stage
    if($ProgressPath) { [IO.File]::WriteAllText($ProgressPath,$Stage) }
}
function Get-DependencyHash([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create(); $stream=[IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Receive-DependencyFile([string]$Url,[string]$Target) {
    if(([uri]$Url).Scheme -ne 'https'){throw 'Dependency downloads require HTTPS.'}
    Set-DependencyProgress "Dependency download: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Target -UseBasicParsing -TimeoutSec 600
}
function Get-DependencyVersion([string]$Path,[string]$Argument) {
    $info=[Diagnostics.ProcessStartInfo]::new($Path,$Argument)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$info
    try {
        $null=$p.Start(); $stdout=$p.StandardOutput.ReadToEndAsync(); $stderr=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(30000)){ $p.Kill(); throw 'Version check timed out.' }
        $result=$stdout.Result+$stderr.Result
        if($p.ExitCode -ne 0 -or $result -notmatch '\d+\.\d+') { throw "Invalid version response (exit $($p.ExitCode))." }
        return ($result -split '\r?\n')[0]
    } finally {$p.Dispose()}
}
try {
    if(-not $env:SystemRoot -or -not (Test-Path -LiteralPath $env:SystemRoot -PathType Container)){throw 'Windows SystemRoot could not be determined.'}
    $names=@('yt-dlp.exe','ffmpeg.exe','ffprobe.exe')
    $missing=@($names | Where-Object {-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot $_))})
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if($missing.Count -and -not $admin) {
        Set-DependencyProgress 'Administrator approval required to install missing native binaries'
        # Elevate only this installer. The GUI and Gallery installation remain in the original user process.
        $script=Join-Path $PSScriptRoot 'Install-Dependencies.ps1'
        if($script.Contains('"') -or $Root.Contains('"') -or $ProgressPath.Contains('"')){throw 'Invalid bootstrap path.'}
        $arguments="-NoProfile -ExecutionPolicy Bypass -File `"$script`" -NativeOnly -Root `"$Root`""
        if($ProgressPath){$arguments+=" -ProgressPath `"$ProgressPath`""}
        try { $elevated=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe') -Verb RunAs -ArgumentList $arguments -PassThru -Wait }
        catch {throw "Native dependency installation needs UAC approval: $($_.Exception.Message)"}
        if($elevated.ExitCode -ne 0){throw "Elevated dependency installation failed. See $log"}
    } elseif($missing.Count) {
        $temp=Join-Path ([IO.Path]::GetTempPath()) ('YouTubeCorpus-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temp) | Out-Null
        try {
            if($missing -contains 'yt-dlp.exe') {
                $url='https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
                $download=Join-Path $temp 'yt-dlp.exe'; Receive-DependencyFile $url $download
                $checks=Join-Path $temp 'SHA2-256SUMS'; Receive-DependencyFile 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS' $checks
                $match=@(Get-Content $checks | Where-Object {$_ -match '^[a-fA-F0-9]{64}\s+\*?yt-dlp\.exe$'})
                if($match.Count -ne 1 -or (Get-DependencyHash $download) -ne ($match[0] -split '\s+')[0]){throw 'yt-dlp SHA256 verification failed.'}
                $target=Join-Path $env:SystemRoot 'yt-dlp.exe'
                # File.Copy(false) refuses races; an existing executable is never replaced.
                if(-not (Test-Path -LiteralPath $target)){[IO.File]::Copy($download,$target,$false); Write-DependencyEvent 'yt-dlp' $url $target '' 'Installed' 'SHA256 verified.'}
            }
            if($missing -contains 'ffmpeg.exe' -or $missing -contains 'ffprobe.exe') {
                $url='https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
                $zip=Join-Path $temp 'ffmpeg.zip'; Receive-DependencyFile $url $zip
                $checksum=Join-Path $temp 'ffmpeg.sha256'; Receive-DependencyFile ($url+'.sha256') $checksum
                $expected=([IO.File]::ReadAllText($checksum) -split '\s+')[0]
                if($expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-DependencyHash $zip) -ne $expected){throw 'FFmpeg SHA256 verification failed.'}
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                $archive=[IO.Compression.ZipFile]::OpenRead($zip)
                try {
                    foreach($name in @('ffmpeg.exe','ffprobe.exe')) {
                        $target=Join-Path $env:SystemRoot $name
                        if(Test-Path -LiteralPath $target){continue}
                        Set-DependencyProgress "Archive extraction: $name"
                        $entries=@($archive.Entries | Where-Object { $_.FullName -match ('/bin/'+[regex]::Escape($name)+'$') })
                        if($entries.Count -ne 1){throw "Expected exactly one $name in the upstream archive."}
                        $extracted=Join-Path $temp $name
                        [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[0],$extracted,$false)
                        if(-not (Test-Path -LiteralPath $target)){[IO.File]::Copy($extracted,$target,$false);Write-DependencyEvent $name $url $target '' 'Installed' 'SHA256 verified.'}
                    }
                } finally {$archive.Dispose()}
            }
        } finally {Remove-Item -LiteralPath $temp -Recurse -Force}
    }
    foreach($name in $names) {
        $target=Join-Path $env:SystemRoot $name
        Set-DependencyProgress "Verifying $name"
        try {
            $version=Get-DependencyVersion $target $(if($name -eq 'yt-dlp.exe'){'--version'}else{'-version'})
            Write-DependencyEvent $name '' $target $version 'Verified' 'Existing binaries are never replaced.'
        } catch { Write-DependencyEvent $name '' $target '' 'Failed' $_.Exception.Message; throw "Dependency $name failed verification at $target. Existing files were preserved. $($_.Exception.Message)" }
    }
    if(-not $NativeOnly) {
        Set-DependencyProgress 'Checking ImportExcel'
        if(-not (Get-Module -ListAvailable ImportExcel)) {
            if(-not (Get-PackageProvider -ListAvailable NuGet -ErrorAction SilentlyContinue)){Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null}
            Install-Module ImportExcel -Repository PSGallery -Scope CurrentUser -Force -ErrorAction Stop
        }
        Import-Module ImportExcel -ErrorAction Stop
        $module=Get-Module ImportExcel
        Write-DependencyEvent 'ImportExcel' 'https://www.powershellgallery.com/packages/ImportExcel' $module.ModuleBase $module.Version.ToString() 'Verified' 'Imported successfully.'
    }
    Set-DependencyProgress 'Dependencies ready'
} catch {
    Write-DependencyEvent 'Bootstrap' '' '' '' 'Failed' $_.Exception.Message
    if($NativeOnly){ Write-Error $_ -ErrorAction Continue; exit 1 }
    throw
}
