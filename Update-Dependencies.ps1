[CmdletBinding()]
param(
    [ValidateSet('Check','Update','Recover')][string]$Action='Check',
    [ValidateSet('yt-dlp','FFmpeg','Deno','ImportExcel')][string[]]$Name=@(),
    [ValidateSet('stable','nightly')][string]$Channel='stable',
    [string]$Root='', [switch]$Force,
    [switch]$NativeCommit,[string]$PlanPath='',
    [switch]$RecoverNative,[ValidatePattern('^[a-f0-9]{32}$')][string]$ResultId
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
if(-not $Root){$Root=Split-Path -Parent $MyInvocation.MyCommand.Path}
foreach($module in @('Logging','Core','Process','Dependencies','DependencyTransaction')){
    Import-Module (Join-Path $PSScriptRoot "src/Corpus.$module.psm1") -Force -Global
}
function Set-ProtectedDirectory([string]$Path,[switch]$Readable) {
    if(Test-Path -LiteralPath $Path){
        if((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Dependency maintenance directories cannot be reparse points.'}
    } else {[IO.Directory]::CreateDirectory($Path) | Out-Null}
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    if($Readable){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))}
    [IO.Directory]::SetAccessControl($Path,$acl)
}
if($NativeCommit -or $RecoverNative){
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if(-not $admin){throw 'The native update helper must run elevated.'}
    # Keep a helper-owned lock even if the unelevated parent exits during UAC/commit.
    # Process exit releases it, including abnormal termination; the journal handles recovery.
    $nativeCommitLock=Enter-CorpusDependencyLock -Commit
    $protected=Join-Path $env:SystemRoot 'YT-OSINT-Updates'
    Set-ProtectedDirectory $protected -Readable
    Set-ProtectedDirectory (Join-Path $protected 'results') -Readable
    Set-ProtectedDirectory (Join-Path $protected 'transactions')
    $ctx=New-CorpusContext $protected
    if($NativeCommit){
        $id=Split-Path (Split-Path $PlanPath -Parent) -Leaf
        if($id -notmatch '^[a-f0-9]{32}$'){throw 'Invalid dependency staging identifier.'}
    } else {$id=$ResultId;if(-not $id){throw 'A recovery result identifier is required.'}}
    $journalPath=Join-Path $protected "results/$id.json"
    $transactionRoot=Join-Path $protected "transactions/$id"
    try {
        if($RecoverNative){
            foreach($file in Get-ChildItem (Join-Path $protected 'results') -Filter '*.json'){
                $entry=Read-CorpusJson $file.FullName
                if($entry.Status -in @('Committing','RollbackFailed')){
                    Restore-CorpusNativeTransaction $ctx $file.FullName $env:SystemRoot (Join-Path $protected "transactions/$($file.BaseName)")
                }
            }
            Write-CorpusJson $journalPath @{Name='Recovery';Status='Success';Message='Interrupted transactions recovered.'}
        } else {
            if(@(Get-CorpusDependencyRecovery).Count){throw 'An earlier interrupted transaction requires recovery first.'}
            $plan=Read-CorpusJson $PlanPath
            if($plan.Name -notin @('yt-dlp','FFmpeg','Deno')){throw 'Unsupported native dependency.'}
            # Re-resolve only allowlisted upstreams. Never trust a supplied URL/hash/target path from the unelevated manifest.
            $release=Get-CorpusDependencyRelease $plan.Name $plan.Channel
            if($release.Version -ne $plan.Version){throw 'The upstream release changed. Recheck and stage the update again.'}
            Set-ProtectedDirectory $transactionRoot
            $archive=Join-Path $transactionRoot $release.FileName
            $source=Join-Path (Split-Path $PlanPath -Parent) $release.FileName
            [IO.File]::Copy($source,$archive,$false)
            Assert-CorpusDependencyDigest $archive $release
            $candidate=Join-Path $transactionRoot 'candidate'
            Expand-CorpusDependency $archive $candidate $plan.Name
            # New files moved out of protected staging must be executable by ordinary users.
            foreach($file in @(Get-CorpusNativeNames $plan.Name)){
                $fileAcl=[Security.AccessControl.FileSecurity]::new()
                $fileAcl.SetAccessRuleProtection($true,$false)
                foreach($sid in @('S-1-5-18','S-1-5-32-544')){
                    $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))
                }
                $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','Allow'))
                [IO.File]::SetAccessControl((Join-Path $candidate $file),$fileAcl)
            }
            Install-CorpusNativeTransaction $ctx $plan.Name $candidate $release.Version $env:SystemRoot $transactionRoot $journalPath $plan.Baseline
            # Large downloaded archives are no longer needed; backups and the journal remain.
            [IO.File]::Delete($archive)
        }
        exit 0
    } catch {
        $existing=Read-CorpusJson $journalPath
        # Never replace a pending recovery journal with a generic error record.
        if(-not $existing -or $existing.Status -notin @('Committing','RollbackFailed')){
            if($existing){$existing.Message=$_.Exception.Message;Write-CorpusJson $journalPath $existing}
            else {Write-CorpusJson $journalPath @{Name='Update';Status='Failed';Message=$_.Exception.Message}}
        }
        Write-CorpusLog $ctx Error Dependencies '' $_.Exception.Message $_.ToString()
        exit 1
    }
}
$ctx=New-CorpusContext ([IO.Path]::GetFullPath($Root))
switch($Action){
    'Check' {Get-CorpusDependencyStatus $ctx $Channel -Force:$Force}
    'Update' {
        if(-not $Name.Count){throw 'Specify -Name with the dependencies to update.'}
        $rows=@(Get-CorpusDependencyStatus $ctx $Channel -Force)
        $selection=@($rows | Where-Object {$_.Name -in $Name})
        if(@($selection | Where-Object {-not $_.CanUpdate}).Count){throw 'A selected dependency cannot be updated. Check its status first.'}
        Invoke-CorpusDependencyUpdate $ctx $selection $Channel
    }
    'Recover' {Repair-CorpusDependencies $ctx}
}
