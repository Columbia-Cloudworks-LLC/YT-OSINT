$project=Split-Path $PSScriptRoot -Parent
foreach($module in @('Logging','Core','Process','Dependencies','DependencyTransaction')){
    Import-Module (Join-Path $project "src/Corpus.$module.psm1") -Force -Global
}
function New-DependencyTestContext {
    $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    return New-CorpusContext $root
}
Describe 'Dependency version policy' {
    It 'distinguishes updates, equality and newer local versions' {
        (Compare-CorpusDependencyVersion 2025.01.26 2026.08.19 stable stable) | Should Be 'Update available'
        (Compare-CorpusDependencyVersion 7.8.10 7.8.10 stable stable) | Should Be 'Up to date'
        (Compare-CorpusDependencyVersion 8.0.0 7.8.10 stable stable) | Should Be 'Installed newer'
    }
    It 'does not compare a git snapshot as a numbered FFmpeg release' {
        (Compare-CorpusDependencyVersion '2025-01-22-git-abc-full_build' '9.0.2' 'git snapshot' release) | Should Be 'Different channel / build'
        (Compare-CorpusDependencyVersion '9.0.2-essentials_build-www.gyan.dev' '9.0.2' release release) | Should Be 'Up to date'
    }
    It 'marks absent dependencies and explicit channel switches' {
        (Compare-CorpusDependencyVersion '' 2.9.7 stable stable) | Should Be Missing
        (Compare-CorpusDependencyVersion 2026.08.19 2026.09.26.123456 stable nightly) | Should Be 'Different channel / build'
    }
}
Describe 'Read-only update checks and caching' {
    BeforeEach {
        $ctx=New-DependencyTestContext
        Mock Get-CorpusDependencyRecovery -ModuleName Corpus.Dependencies { @() }
        Mock Get-CorpusDependencyInstalled -ModuleName Corpus.Dependencies {
            param($Context,$Name)
            [pscustomobject]@{Version='1.0.0';Path="C:\fixture\$Name";Channel=$(if($Name -eq 'FFmpeg'){'release'}else{'stable'})}
        }
        Mock Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies {
            param($Name,$Channel)
            [pscustomobject]@{Name=$Name;Version='2.0.0';Provider='Fixture upstream';Channel=$(if($Name -eq 'FFmpeg'){'release'}else{'stable'})}
        }
    }
    It 'checks every managed dependency and reuses a daily cache' {
        $first=@(Get-CorpusDependencyStatus $ctx)
        $second=@(Get-CorpusDependencyStatus $ctx)
        $first.Count | Should Be 4
        @($second | Where-Object Status -eq 'Update available').Count | Should Be 4
        Assert-MockCalled Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies -Times 4 -Exactly -Scope It
        Test-Path (Join-Path $ctx.Root 'data/dependencies/staging') | Should Be $false
    }
    It 'bypasses the cache on Check now and on channel changes' {
        $null=Get-CorpusDependencyStatus $ctx
        $null=Get-CorpusDependencyStatus $ctx -Force
        $null=Get-CorpusDependencyStatus $ctx -Channel nightly
        Assert-MockCalled Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies -Times 12 -Exactly -Scope It
    }
    It 'expires checks older than 24 hours' {
        $null=Get-CorpusDependencyStatus $ctx
        $path=Join-Path $ctx.Root 'data/dependencies/checks.json'
        $cache=@(Read-CorpusJson $path)
        foreach($c in $cache){$c.CheckedAt=[datetime]::UtcNow.AddDays(-2).ToString('o')}
        Write-CorpusJson $path $cache
        $null=Get-CorpusDependencyStatus $ctx
        Assert-MockCalled Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies -Times 8 -Exactly -Scope It
    }
    It 'reports an upstream failure as Unknown and does not permit an update' {
        Mock Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies {throw 'Simulated network timeout'}
        $rows=@(Get-CorpusDependencyStatus $ctx)
        @($rows | Where-Object Status -eq Unknown).Count | Should Be 4
        @($rows | Where-Object CanUpdate).Count | Should Be 0
        $rows[0].Detail | Should Match 'network timeout'
    }
    It 'reports interrupted native transactions as requiring recovery' {
        Mock Get-CorpusDependencyRecovery -ModuleName Corpus.Dependencies { [pscustomobject]@{Name='FFmpeg';Status='Committing'} }
        $row=Get-CorpusDependencyStatus $ctx | Where-Object Name -eq FFmpeg
        $row.Status | Should Be 'Recovery required';$row.CanUpdate | Should Be $false
    }
}
Describe 'Download integrity and archive handling' {
    BeforeEach {$ctx=New-DependencyTestContext}
    It 'verifies SHA256 and rejects modified downloads' {
        $file=Join-Path $ctx.Root candidate;[IO.File]::WriteAllText($file,'verified bytes')
        $release=[pscustomobject]@{Hash=(Get-CorpusFileDigest $file);Algorithm='SHA256';Base64=$false}
        {Assert-CorpusDependencyDigest $file $release} | Should Not Throw
        [IO.File]::AppendAllText($file,' changed')
        {Assert-CorpusDependencyDigest $file $release} | Should Throw
    }
    It 'verifies Gallery SHA512 base64 hashes' {
        $file=Join-Path $ctx.Root package;[IO.File]::WriteAllText($file,'module bytes')
        $release=[pscustomobject]@{Hash=(Get-CorpusFileDigest $file SHA512 -Base64);Algorithm='SHA512';Base64=$true}
        {Assert-CorpusDependencyDigest $file $release} | Should Not Throw
        $release.Hash='bad'
        {Assert-CorpusDependencyDigest $file $release} | Should Throw
    }
    It 'rejects a traversal path in an ImportExcel archive' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $path=Join-Path $ctx.Root bad.zip;$zip=[IO.Compression.ZipFile]::Open($path,'Create')
        $entry=$zip.CreateEntry('../escape.ps1');$zip.Dispose()
        {Expand-CorpusDependency $path (Join-Path $ctx.Root extracted) ImportExcel} | Should Throw
        Test-Path (Join-Path $ctx.Root escape.ps1) | Should Be $false
    }
    It 'extracts only the two required FFmpeg binaries' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $path=Join-Path $ctx.Root good.zip;$zip=[IO.Compression.ZipFile]::Open($path,'Create')
        foreach($name in @('build/bin/ffmpeg.exe','build/bin/ffprobe.exe','build/bin/ffplay.exe','build/readme.txt')){$null=$zip.CreateEntry($name)}
        $zip.Dispose();$dest=Join-Path $ctx.Root extracted
        Expand-CorpusDependency $path $dest FFmpeg
        @(Get-ChildItem $dest).Count | Should Be 2
    }
    It 'refuses a release that changed after the user reviewed it' {
        Mock Get-CorpusDependencyRelease -ModuleName Corpus.Dependencies { [pscustomobject]@{Version='3.0.0'} }
        {Save-CorpusDependencyPlan $ctx Deno stable '2.0.0'} | Should Throw
        Test-Path (Join-Path $ctx.Root 'data/dependencies/staging') | Should Be $false
    }
    It 'honors cancellation before scheduling downloads' {
        $ctx.Shared=[hashtable]::Synchronized(@{Cancel=$true})
        {Invoke-CorpusDependencyUpdate $ctx @([pscustomobject]@{Name='Deno';AvailableVersion='2.0.0'})} | Should Throw
    }
}
Describe 'Transactional native replacement in an isolated directory' {
    BeforeEach {
        $ctx=New-DependencyTestContext
        $target=Join-Path $ctx.Root target;$candidate=Join-Path $ctx.Root candidate;$transaction=Join-Path $ctx.Root transaction
        foreach($dir in @($target,$candidate,$transaction)){New-Item $dir -ItemType Directory | Out-Null}
        $baseline=@()
        foreach($name in @('ffmpeg.exe','ffprobe.exe')){
            [IO.File]::WriteAllText((Join-Path $target $name),"old $name")
            [IO.File]::WriteAllText((Join-Path $candidate $name),"new $name")
            $baseline+=[pscustomobject]@{Name=$name;Hash=(Get-CorpusFileDigest (Join-Path $target $name))}
        }
        $journal=Join-Path $ctx.Root transaction.json
        Mock Test-CorpusDependencyCandidate -ModuleName Corpus.DependencyTransaction {}
    }
    It 'updates the pair, verifies it and retains checksummed backups' {
        Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline
        (Read-CorpusJson $journal).Status | Should Be Success
        [IO.File]::ReadAllText((Join-Path $target ffmpeg.exe)) | Should Be 'new ffmpeg.exe'
        [IO.File]::ReadAllText((Join-Path $transaction backup/ffprobe.exe)) | Should Be 'old ffprobe.exe'
        Assert-MockCalled Test-CorpusDependencyCandidate -ModuleName Corpus.DependencyTransaction -Times 2 -Exactly -Scope It
    }
    It 'restores both originals if verification fails after replacement' {
        Mock Test-CorpusDependencyCandidate -ModuleName Corpus.DependencyTransaction {
            param($Context,$Name,$Directory)
            if((Split-Path $Directory -Leaf) -eq 'target'){throw 'Simulated invalid installed executable'}
        }
        {Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline} | Should Throw
        (Read-CorpusJson $journal).Status | Should Be RolledBack
        foreach($name in @('ffmpeg.exe','ffprobe.exe')){[IO.File]::ReadAllText((Join-Path $target $name)) | Should Be "old $name"}
    }
    It 'rolls back the first file when the second destination is locked' {
        $handle=[IO.File]::Open((Join-Path $target ffprobe.exe),'Open','Read','Read')
        try {{Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline} | Should Throw}
        finally {$handle.Dispose()}
        foreach($name in @('ffmpeg.exe','ffprobe.exe')){[IO.File]::ReadAllText((Join-Path $target $name)) | Should Be "old $name"}
        (Read-CorpusJson $journal).Status | Should Be RolledBack
    }
    It 'recovers an interrupted pair from its durable journal' {
        Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline
        $j=Read-CorpusJson $journal;$j.Status='Committing';Write-CorpusJson $journal $j
        Restore-CorpusNativeTransaction $ctx $journal $target $transaction
        foreach($name in @('ffmpeg.exe','ffprobe.exe')){[IO.File]::ReadAllText((Join-Path $target $name)) | Should Be "old $name"}
        (Read-CorpusJson $journal).Status | Should Be RolledBack
    }
    It 'will not overwrite an externally modified file during recovery' {
        Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline
        $j=Read-CorpusJson $journal;$j.Status='Committing';Write-CorpusJson $journal $j
        [IO.File]::WriteAllText((Join-Path $target ffprobe.exe),'third-party change')
        {Restore-CorpusNativeTransaction $ctx $journal $target $transaction} | Should Throw
        (Read-CorpusJson $journal).Status | Should Be RollbackFailed
        [IO.File]::ReadAllText((Join-Path $target ffprobe.exe)) | Should Be 'third-party change'
    }
    It 'refuses to replace a binary changed after download staging' {
        [IO.File]::WriteAllText((Join-Path $target ffmpeg.exe),'changed externally')
        {Install-CorpusNativeTransaction $ctx FFmpeg $candidate '9.0.2' $target $transaction $journal $baseline} | Should Throw
        [IO.File]::ReadAllText((Join-Path $target ffmpeg.exe)) | Should Be 'changed externally'
    }
}
Describe 'ImportExcel candidate verification' {
    It 'imports the real installed module in a fresh process and round-trips a workbook' {
        $ctx=New-DependencyTestContext
        $module=Get-Module -ListAvailable ImportExcel | Sort-Object Version -Descending | Select-Object -First 1
        {Test-CorpusDependencyCandidate $ctx ImportExcel $module.ModuleBase $module.Version.ToString()} | Should Not Throw
    }
}
Describe 'Windows upstream response compatibility' {
    It 'decodes byte-array HTTP metadata as UTF-8 text' {
        Mock Invoke-WebRequest -ModuleName Corpus.Dependencies { [pscustomobject]@{Content=[Text.Encoding]::UTF8.GetBytes('9.0.2')} }
        (Get-CorpusDependencyText 'https://www.gyan.dev/ffmpeg/builds/release-version') | Should Be '9.0.2'
    }
    It 'recognizes native FFmpeg Git snapshot version strings' {
        $ctx=New-DependencyTestContext;$path=Join-Path $ctx.Root ffmpeg.exe
        [IO.File]::WriteAllText($path,'fixture')
        Mock Invoke-CorpusProcess -ModuleName Corpus.Dependencies { [pscustomobject]@{ExitCode=0;StdOut="ffmpeg version 2025-01-22-git-abc-full_build`r`n";StdErr=''} }
        (Get-CorpusNativeVersion $ctx $path ffmpeg) | Should Match '2025-01-22-git'
    }
}
Describe 'Side-by-side ImportExcel promotion' {
    BeforeEach {
        $ctx=New-DependencyTestContext
        $base=Join-Path $ctx.Root user-modules
        $old=Join-Path $base '1.0.0';New-Item $old -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $old ImportExcel.psd1),'previous')
        Write-CorpusJson (Join-Path $ctx.Root 'data/dependencies/settings.json') @{YtDlpChannel='stable';ImportExcelPath=(Join-Path $old ImportExcel.psd1)}
        $candidate=Join-Path $ctx.Root candidate;New-Item $candidate -ItemType Directory | Out-Null
        [IO.File]::WriteAllText((Join-Path $candidate ImportExcel.psd1),'new')
        $stage=Join-Path $ctx.Root stage;New-Item $stage -ItemType Directory | Out-Null
        $plan=[pscustomobject]@{Version='2.0.0';Candidate=$candidate;Stage=$stage}
        Mock Get-CorpusModuleInstallRoot -ModuleName Corpus.Dependencies {param($Context) Join-Path $Context.Root user-modules}
        Mock Test-CorpusDependencyCandidate -ModuleName Corpus.Dependencies {}
    }
    It 'selects the verified module without removing the previous version' {
        Install-CorpusDependencyModule $ctx $plan
        Test-Path (Join-Path $base '1.0.0/ImportExcel.psd1') | Should Be $true
        Test-Path (Join-Path $base '2.0.0/ImportExcel.psd1') | Should Be $true
        (Get-CorpusDependencySettings $ctx.Root).ImportExcelPath | Should Be (Join-Path $base '2.0.0/ImportExcel.psd1')
        (Read-CorpusJson (Join-Path $stage module-backup.json)).PreviousModulePath | Should Be (Join-Path $old ImportExcel.psd1)
    }
    It 'restores the previous selection if post-install verification fails' {
        Mock Test-CorpusDependencyCandidate -ModuleName Corpus.Dependencies {
            param($Context,$Name,$Directory)
            if((Split-Path $Directory -Leaf) -eq '2.0.0'){throw 'Simulated workbook failure'}
        }
        {Install-CorpusDependencyModule $ctx $plan} | Should Throw
        Test-Path (Join-Path $base '2.0.0') | Should Be $false
        (Get-CorpusDependencySettings $ctx.Root).ImportExcelPath | Should Be (Join-Path $old ImportExcel.psd1)
    }
    It 'does not overwrite an already installed version directory' {
        $existing=Join-Path $base '2.0.0';New-Item $existing -ItemType Directory | Out-Null
        [IO.File]::WriteAllText((Join-Path $existing ImportExcel.psd1),'existing')
        {Install-CorpusDependencyModule $ctx $plan} | Should Throw
        [IO.File]::ReadAllText((Join-Path $existing ImportExcel.psd1)) | Should Be 'existing'
    }
}
Describe 'Cross-process maintenance exclusion' {
    It 'blocks a runtime reader while the native helper owns its commit lock' {
        $owner=Enter-CorpusDependencyLock -Commit
        $worker=[powershell]::Create()
        try {
            $null=$worker.AddScript({param($modulePath)
                Import-Module $modulePath -Force
                try{$lock=Enter-CorpusDependencyLock -Commit;$lock.ReleaseMutex();$lock.Dispose();return 'Unexpectedly acquired'}
                catch{return 'Blocked'}
            }).AddArgument((Join-Path $project 'src/Corpus.Dependencies.psm1'))
            @($worker.Invoke())[0] | Should Be Blocked
        } finally {$worker.Dispose();$owner.ReleaseMutex();$owner.Dispose()}
    }
}

Describe 'Maintenance failure reporting' {
    It 'records a rejected update in the structured run log' {
        $ctx=New-DependencyTestContext
        Mock Save-CorpusDependencyPlan -ModuleName Corpus.Dependencies {throw 'Fixture checksum mismatch'}
        {Invoke-CorpusDependencyUpdate $ctx @([pscustomobject]@{Name='Deno';AvailableVersion='2.9.7'})} | Should Throw
        $events=@(Get-Content $ctx.LogPath | ForEach-Object {$_ | ConvertFrom-Json})
        $events[-1].Severity | Should Be Error
        $events[-1].Message | Should Match 'checksum mismatch'
    }
}
