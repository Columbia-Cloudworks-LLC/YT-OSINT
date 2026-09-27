[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Path,[int]$ExpectedTables=4)
$ErrorActionPreference='Stop'
$excel=$null;$book=$null
try {
 $excel=New-Object -ComObject Excel.Application
 $excel.Visible=$false;$excel.DisplayAlerts=$false
 $book=$excel.Workbooks.Open($Path,0,$true)
 $tables=0;foreach($sheet in $book.Worksheets){$tables+=$sheet.ListObjects.Count}
 if($tables -ne $ExpectedTables){throw "Expected $ExpectedTables tables; Excel retained $tables."}
 [pscustomobject]@{Opened=$true;Worksheets=$book.Worksheets.Count;Tables=$tables;LoadMode='Normal (no repair requested)'} | ConvertTo-Json
} catch {Write-Output $_.Exception.Message;exit 1}
finally {if($book){$book.Close($false);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book)};if($excel){$excel.Quit();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)}}
