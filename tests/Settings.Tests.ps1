$project=Split-Path $PSScriptRoot -Parent
foreach($name in @('Logging','Core','Process','Dependencies','RateLimit','DependencyTransaction','Transcript','YouTube','Excel','Operations','Queue','Settings')){Import-Module (Join-Path $project "src/Corpus.$name.psm1") -Force -Global}
Describe 'Storage preferences and verified migration' {
    BeforeEach {
        $root=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));$null=New-CorpusContext $root
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/config.json') (Join-Path $root config.json)
        $destination=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $settings=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.json')
    }
    It 'defaults to seven days and persists per-user settings in the specified profile file' {
        (Get-CorpusUserSettings $settings).StaleDays | Should Be 7
        $result=Save-CorpusStorageSettings $root $root Switch 14 $settings
        $result.Changed | Should Be $false
        (Get-CorpusUserSettings $settings).StaleDays | Should Be 14
        (Get-CorpusUserSettings $settings).CorpusRoot | Should Be $root
        {Save-CorpusStorageSettings $root $root Switch 0 $settings} | Should Throw
    }
    It 'copies and verifies queue and captures while preserving originals and relative paths' {
        $null=Add-CorpusQueueUrls $root 'https://youtu.be/abcDEF12_-3' mo
        [IO.File]::WriteAllText((Join-Path $root 'data/evidence.txt'),'Original evidence')
        $result=Save-CorpusStorageSettings $root $destination Move 10 $settings
        $result.Changed | Should Be $true
        [IO.File]::ReadAllText((Join-Path $destination 'data/evidence.txt')) | Should Be 'Original evidence'
        (Get-CorpusQueue $destination).Items[0].SubjectId | Should Be mo
        (Get-CorpusQueue $destination).Paused | Should Be $true
        Test-Path (Join-Path $root 'data/evidence.txt') | Should Be $true
        (Get-CorpusUserSettings $settings).CorpusRoot | Should Be $destination
    }
    It 'keeps preferences unchanged and blocks a partially copied destination after verification failure' {
        Mock Get-CorpusFileDigest {[guid]::NewGuid().ToString()} -ModuleName Corpus.Settings
        {Save-CorpusStorageSettings $root $destination Move 7 $settings} | Should Throw
        Test-Path $settings | Should Be $false
        {Get-CorpusConfig $destination} | Should Throw
        {Save-CorpusStorageSettings $root $destination Switch 7 $settings} | Should Throw
        (Get-CorpusConfig $root).subjects[0].id | Should Be mo
    }
    It 'creates an empty corpus and switches to an existing corpus without copying subjects' {
        $null=Save-CorpusStorageSettings $root $destination Switch 7 $settings
        @((Get-CorpusConfig $destination).subjects).Count | Should Be 0
        $null=Set-CorpusSubject $destination 'Different corpus'
        $null=Save-CorpusStorageSettings $root $destination Switch 8 $settings
        (Get-CorpusConfig $destination).subjects[0].name | Should Be 'Different corpus'
        (Get-CorpusConfig $root).subjects[0].id | Should Be mo
    }
    It 'rejects occupied and nested move destinations without changing preferences' {
        $null=[IO.Directory]::CreateDirectory($destination);[IO.File]::WriteAllText((Join-Path $destination keep.txt),'keep')
        {Save-CorpusStorageSettings $root $destination Move 7 $settings} | Should Throw
        {Save-CorpusStorageSettings $root (Join-Path $root nested) Move 7 $settings} | Should Throw
        Test-Path $settings | Should Be $false
        [IO.File]::ReadAllText((Join-Path $destination keep.txt)) | Should Be keep
    }
    It 'refuses migration or switching while a source or destination runner owns the corpus' {
        $guard=Enter-CorpusQueueRunner $root
        try{{Save-CorpusStorageSettings $root $destination Move 7 $settings} | Should Throw}finally{$guard.Dispose()}
        $null=New-CorpusContext $destination;Copy-Item (Join-Path $root config.json) (Join-Path $destination config.json)
        $guard=Enter-CorpusQueueRunner $destination
        try{{Save-CorpusStorageSettings $root $destination Switch 7 $settings} | Should Throw}finally{$guard.Dispose()}
        Test-Path $settings | Should Be $false
    }
}
Describe 'Channel freshness and activity' {
    BeforeEach {
        $now=[datetime]'2026-09-27T12:00:00Z'
        $channel=[pscustomobject]@{LastSuccessfulSync=$now.AddDays(-7).ToString('o');Status='Completed'}
        $queue=[pscustomobject]@{Paused=$false;Items=@()}
    }
    It 'keeps the exact threshold fresh and marks older successful syncs stale' {
        (Get-CorpusChannelIndicator $channel $null $queue 7 $now).Freshness | Should Be 'Up to date'
        (Get-CorpusChannelIndicator $channel $null $queue 6 $now).Freshness | Should Be Stale
        $channel.LastSuccessfulSync=''
        (Get-CorpusChannelIndicator $channel $null $queue 7 $now).Freshness | Should Be 'Never synced'
    }
    It 'distinguishes queued, downloading, paused and partial work without losing freshness' {
        $job=[pscustomobject]@{Id='job';Status='Downloading';PartialImport=$false}
        (Get-CorpusChannelIndicator $channel $job $queue 7 $now).Label | Should Match Queued
        $queue.Items=@([pscustomobject]@{JobIds=@('job');Status='Running'})
        (Get-CorpusChannelIndicator $channel $job $queue 7 $now).Label | Should Match Syncing
        $queue.Items=@();$queue.Paused=$true
        (Get-CorpusChannelIndicator $channel $job $queue 7 $now).Label | Should Match Paused
        $job.Status='Partial';$job.PartialImport=$true
        $indicator=Get-CorpusChannelIndicator $channel $job $queue 7 $now
        $indicator.Label | Should Match 'Partial channel import';$indicator.Freshness | Should Be 'Up to date';$indicator.Locked | Should Be $false
    }
}
