[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# The shipped Windows Pester 3.4 runner and Pester 4.x are supported without network installation.
$module=Get-Module -ListAvailable Pester | Where-Object {$_.Version.Major -in @(3,4)} | Sort-Object Version -Descending | Select-Object -First 1
if(-not $module){throw 'Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser, then rerun.'}
Import-Module $module.Path -Force
$result=Invoke-Pester -Script @((Join-Path $PSScriptRoot 'Corpus.Tests.ps1'),(Join-Path $PSScriptRoot 'Dependencies.Tests.ps1'),(Join-Path $PSScriptRoot 'RateLimit.Tests.ps1'),(Join-Path $PSScriptRoot 'MembersOnly.Tests.ps1'),(Join-Path $PSScriptRoot 'Queue.Tests.ps1')) -PassThru
if($result.FailedCount -gt 0){exit 1}
