Set-StrictMode -Version 2
function Export-CorpusWorkbook {
    param($Context,[string]$Path='',$RunOverride=$null)
    $dependencySettings=Get-CorpusDependencySettings $Context.Root
    if($dependencySettings.ImportExcelPath){Import-Module $dependencySettings.ImportExcelPath -ErrorAction Stop}
    else {Import-Module ImportExcel -ErrorAction Stop}
    if(-not $Path){$Path=Join-Path $Context.Root 'output/YouTubeCorpus.xlsx'}
    $Path=[IO.Path]::GetFullPath($Path); [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    $temp=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.corpus-'+[guid]::NewGuid().ToString('N')+'.xlsx')
    $package=Open-ExcelPackage -Path $temp -Create
    try {
        $videos=@(Get-CorpusVideos $Context.Root)
        $definitions=@{
            Videos=@('Subject','Subject ID','Channel','Channel ID','Video Title','Video ID','Published Date','Duration','Video URL','Description','View Count','Like Count','Subtitle Source','Transcript Available','Metadata Captured At','Transcript Captured At','Last Sync Status')
            Transcript=@('Subject','Channel','Published Date','Video Title','Video ID','Timestamp','Start Seconds','Transcript Text','Timestamp URL','Transcript Source','Captured At')
            Channels=@('Subject','Channel Name','YouTube Channel ID','Handle','URL','First Captured','Last Sync','Video Count','Transcript Count','Transcript Failures','Last Attempt','Status')
            Runs=@('RunId','StartTimestamp','EndTimestamp','Machine','WindowsVersion','PowerShellVersion','YtDlpVersion','FFmpegVersion','ImportExcelVersion','ChannelsRequested','VideosDiscovered','VideosAdded','VideosAlreadyKnown','TranscriptsAdded','TranscriptsUnavailable','Failures','FinalState')
        }
        function New-Sheet($Name,$Headers) {
            $sheet=$package.Workbook.Worksheets.Add($Name)
            for($i=0;$i -lt $Headers.Count;$i++){$sheet.Cells[1,($i+1)].Value=$Headers[$i]}
            $sheet.View.FreezePanes(2,1); return ,$sheet
        }
        function Set-Cell($Sheet,[int]$Row,[int]$Col,$Value,[switch]$Date,[switch]$Link) {
            if($null -eq $Value -or ($Value -is [string] -and $Value -eq '')){return}
            if($Date){$Sheet.Cells[$Row,$Col].Value=[datetime]$Value; $Sheet.Cells[$Row,$Col].Style.Numberformat.Format='yyyy-mm-dd hh:mm:ss'}
            else {
                # Value (never Formula) prevents formula injection from untrusted captions/titles.
                if($Value -is [string] -and $Value.Length -gt 32767){$Value=$Value.Substring(0,32767)}
                $Sheet.Cells[$Row,$Col].Value=$Value
            }
            if($Link){$Sheet.Cells[$Row,$Col].Hyperlink=[uri]$Value; $Sheet.Cells[$Row,$Col].Style.Font.Color.SetColor([Drawing.Color]::Blue)}
        }
        $ws=New-Sheet 'Videos' $definitions.Videos; $row=1
        foreach($v in $videos) {
            Test-CorpusCancellation $Context; $row++; Set-CorpusProgress $Context 'Excel: videos' $v.VideoId ($row-1) $videos.Count
            if($row -gt 1048576){throw 'Videos exceed the Excel worksheet row limit.'}
            $values=@($v.SubjectName,$v.SubjectId,$v.ChannelName,$v.ChannelId,$v.VideoTitle,$v.VideoId,$v.PublishedDate,$v.Duration,$v.VideoUrl,$v.Description,$v.ViewCount,$v.LikeCount,$v.SubtitleSource,$v.TranscriptAvailable,$v.MetadataCapturedAt,$v.TranscriptCapturedAt,$v.LastSyncStatus)
            for($c=1;$c -le $values.Count;$c++){Set-Cell $ws $row $c $values[$c-1] -Date:($c -in @(7,15,16)) -Link:($c -eq 9)}
        }
        $ws=New-Sheet 'Transcript' $definitions.Transcript; $row=1; $part=1; $n=0
        foreach($v in $videos) {
            $n++; Set-CorpusProgress $Context 'Excel: transcripts' $v.VideoId $n $videos.Count
            foreach($r in @(Get-CorpusTranscript $Context.Root $v)) {
                Test-CorpusCancellation $Context
                if($row -ge 1048576){$part++; $ws=New-Sheet "Transcript_$part" $definitions.Transcript; $row=1}
                $row++
                $values=@($v.SubjectName,$v.ChannelName,$v.PublishedDate,$v.VideoTitle,$v.VideoId,$r.TimestampDisplay,($r.StartMilliseconds/1000.0),$r.TranscriptText,$r.TimestampUrl,$r.TranscriptSource,$r.CapturedAt)
                for($c=1;$c -le $values.Count;$c++){Set-Cell $ws $row $c $values[$c-1] -Date:($c -in @(3,11)) -Link:($c -eq 9)}
            }
        }
        $ws=New-Sheet 'Channels' $definitions.Channels; $row=1
        foreach($file in Get-ChildItem (Join-Path $Context.Root 'data/normalized/channels') -Filter '*.json') {
            Test-CorpusCancellation $Context; $ch=Read-CorpusJson $file.FullName; $row++
            $values=@($ch.Subject,$ch.ChannelName,$ch.ChannelId,$ch.Handle,$ch.Url,$ch.FirstCaptured,$ch.LastSync,$ch.VideosDiscovered,$ch.TranscriptCount,$ch.Failures,$ch.LastAttempt,$ch.Status)
            for($c=1;$c -le $values.Count;$c++){Set-Cell $ws $row $c $values[$c-1] -Date:($c -in @(6,7,11)) -Link:($c -eq 5)}
        }
        $ws=New-Sheet 'Runs' $definitions.Runs; $row=1
        foreach($file in Get-ChildItem (Join-Path $Context.Root 'data/normalized/runs') -Filter '*.json' | Sort-Object Name) {
            $run=Read-CorpusJson $file.FullName; if($RunOverride -and $run.RunId -eq $RunOverride.RunId){$run=$RunOverride}; $row++
            for($c=1;$c -le $definitions.Runs.Count;$c++){Set-Cell $ws $row $c (Get-CorpusProperty $run $definitions.Runs[$c-1]) -Date:($c -in @(2,3))}
        }
        foreach($sheet in $package.Workbook.Worksheets) {
            Set-CorpusProgress $Context 'Excel: formatting' $sheet.Name
            $sheet.Cells[1,1,1,$sheet.Dimension.End.Column].Style.Font.Bold=$true
            $sheet.Cells[1,1,$sheet.Dimension.End.Row,$sheet.Dimension.End.Column].AutoFilter=$true
            $sheet.Cells.Style.VerticalAlignment=[OfficeOpenXml.Style.ExcelVerticalAlignment]::Top
            if($sheet.Dimension.End.Row -gt 1){$table=$sheet.Tables.Add($sheet.Dimension,('Corpus'+$sheet.Name));$table.TableStyle=[OfficeOpenXml.Table.TableStyles]::Medium2}
            for($c=1;$c -le $sheet.Dimension.End.Column;$c++){
                $header=[string]$sheet.Cells[1,$c].Value; $sheet.Column($c).Width=24
                if($header -match 'Text|Description|Title'){$sheet.Column($c).Width=65;$sheet.Column($c).Style.WrapText=$true}
                if($header -match 'URL'){$sheet.Column($c).Width=48}
            }
        }
        Test-CorpusCancellation $Context
        Set-CorpusProgress $Context 'Excel: saving' $Path
        $package.Save();$package.Dispose();$package=$null
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
        Write-CorpusLog $Context Info Excel '' "Workbook saved: $Path"
        return $Path
    } catch { Write-CorpusLog $Context Error Excel '' $_.Exception.Message $_.ScriptStackTrace; throw "Workbook generation failed. Close the workbook if it is open and check disk space. $($_.Exception.Message)" }
    finally {if($package){$package.Dispose()};if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
Export-ModuleMember -Function Export-CorpusWorkbook
