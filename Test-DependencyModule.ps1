[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ModulePath,[Parameter(Mandatory=$true)][string]$ExpectedVersion)
$ErrorActionPreference='Stop'
$path=Join-Path ([IO.Path]::GetTempPath()) ('YTOSINT-module-test-'+[guid]::NewGuid().ToString('N')+'.xlsx')
try {
    Import-Module -Name $ModulePath -Force -ErrorAction Stop
    if((Get-Module ImportExcel).Version.ToString() -ne $ExpectedVersion){throw 'Imported module version does not match the selected release.'}
    [pscustomobject]@{Evidence='Unicode café';Timestamp=42} | Export-Excel -Path $path -WorksheetName Test -TableName Verification
    $row=Import-Excel -Path $path -WorksheetName Test
    if($row.Evidence -ne 'Unicode café' -or $row.Timestamp -ne 42){throw 'ImportExcel workbook round-trip failed.'}
} catch {Write-Error $_ -ErrorAction Continue;exit 1}
finally {if(Test-Path $path){Remove-Item -LiteralPath $path -Force}}
