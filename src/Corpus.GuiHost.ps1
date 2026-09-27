# Enable background GC before the CLR starts. Setting LatencyMode alone cannot enable
# background collection in a PowerShell host that started with it disabled.
function Invoke-CorpusGuiHost {
    param([string]$ScriptPath,[System.Collections.IDictionary]$Parameters)
    $forward=@{}
    foreach($key in $Parameters.Keys){$value=$Parameters[$key];$forward[$key]=if($value -is [Management.Automation.SwitchParameter]){[bool]$value}else{$value}}
    $serialized=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([Management.Automation.PSSerializer]::Serialize($forward)))
    $literalPath=$ScriptPath.Replace("'","''")
    $command=@"
`$ErrorActionPreference='Stop'
`$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new()
try {
    `$parameters=[Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$serialized')))
    & '$literalPath' @parameters
} catch { [Console]::Error.WriteLine(`$_.Exception.ToString()); exit 1 }
"@
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME powershell.exe))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.EnvironmentVariables['COMPlus_gcConcurrent']='1'
    $info.Arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=[Diagnostics.Process]::Start($info)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [Console]::Out.Write($stdout.GetAwaiter().GetResult());[Console]::Error.Write($stderr.GetAwaiter().GetResult())
        return $process.ExitCode
    } finally {$process.Dispose()}
}
