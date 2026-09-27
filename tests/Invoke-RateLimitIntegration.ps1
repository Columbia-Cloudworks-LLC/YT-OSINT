[CmdletBinding()]
param([string]$TestRoot=(Join-Path ([IO.Path]::GetTempPath()) ('YTOSINT-rate-limit-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','Transcript','YouTube')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
$ctx=New-CorpusContext $TestRoot
$shared=[hashtable]::Synchronized(@{Ready=$false;Stop=$false;Count=0;Port=0;Success=$false})
$server=[powershell]::Create()
$null=$server.AddScript({param($s)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start();$s.Port=$listener.LocalEndpoint.Port;$s.Ready=$true
    try {
        while(-not $s.Stop){
            if(-not $listener.Pending()){Start-Sleep -Milliseconds 20;continue}
            $client=$listener.AcceptTcpClient();$s.Count++
            try {
                $stream=$client.GetStream();$stream.ReadTimeout=5000
                $reader=[IO.StreamReader]::new($stream)
                while($reader.ReadLine()){}
                $body=if($s.Success){"WEBVTT`n`n00:00:01.000 --> 00:00:02.000`nLocal caption test`n"}else{''}
                $status=if($s.Success){'200 OK'}else{'429 Too Many Requests'}
                $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Type: text/vtt`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
                $stream.Write($bytes,0,$bytes.Length);$stream.Flush()
            } finally {$client.Dispose()}
        }
    } finally {$listener.Stop()}
}).AddArgument($shared)
$handle=$server.BeginInvoke()
try {
    $deadline=[datetime]::UtcNow.AddSeconds(5)
    while(-not $shared.Ready){if([datetime]::UtcNow -gt $deadline){throw 'Test server did not start'};Start-Sleep -Milliseconds 20}
    $url="http://127.0.0.1:$($shared.Port)/caption"
    $meta=[pscustomobject]@{id='abcDEF12_-3';title='Local caption fixture';extractor='youtube';webpage_url="http://127.0.0.1:$($shared.Port)/unexpected-fallback";formats=@([pscustomobject]@{format_id='test';url="http://127.0.0.1:$($shared.Port)/media";ext='mp4'});subtitles=[pscustomobject]@{en=@([pscustomobject]@{ext='vtt';url=$url})}}
    $sub=Select-CorpusSubtitle $meta
    $request=Join-Path $ctx.Root request.json;Save-CorpusCaptionRequest $meta $sub $request
    $args=(Get-CorpusYtArguments)+@('--sleep-subtitles','0','--sleep-requests','0','--load-info-json',$request,'--abort-on-error','--write-subs','--sub-langs','en','--sub-format','vtt','--output',(Join-Path $ctx.Root '%(id)s.%(ext)s'))
    $r=Invoke-CorpusProcess $ctx (Join-Path (Get-CorpusNativeRoot) yt-dlp.exe) $args -TimeoutSeconds 30
    if($r.StdErr -notmatch 'HTTP Error 429'){throw "Expected subtitle 429 (exit $($r.ExitCode), requests $($shared.Count)), received: $($r.StdOut) $($r.StdErr)"}
    if($shared.Count -ne 1 -or $r.StdErr -match 'trying with URL'){throw "Unexpected fallback or duplicate request: count $($shared.Count) $($r.StdErr)"}
    $shared.Success=$true
    $success=Invoke-CorpusProcess $ctx (Join-Path (Get-CorpusNativeRoot) yt-dlp.exe) $args -TimeoutSeconds 30
    if($success.ExitCode -ne 0 -or $shared.Count -ne 2){throw 'Successful caption download did not use exactly one additional request.'}
    $video=ConvertTo-CorpusVideo $meta
    $rows=@(ConvertFrom-CorpusVtt (Join-Path $ctx.Root 'abcDEF12_-3.en.vtt') $video Manual en)
    if($rows.Count -ne 1 -or $rows[0].TranscriptText -ne 'Local caption test'){throw 'Downloaded subtitle did not normalize correctly.'}
    Write-Host 'PASS: real yt-dlp issued one request per attempt, exposed 429 without fallback, then downloaded and normalized a valid VTT; no media requests.'
} finally {$shared.Stop=$true;$null=$server.EndInvoke($handle);$server.Dispose()}
