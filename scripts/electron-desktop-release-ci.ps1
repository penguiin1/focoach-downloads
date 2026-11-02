#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Restore', 'Build', 'Collect', 'Cleanup')]
    [string]$Phase
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if (!$IsWindows -or $env:GITHUB_REPOSITORY -cne 'penguiin1/focoach-downloads' -or
    $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
    $env:GITHUB_RUN_ID -notmatch '^[0-9]+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^[0-9]+$') {
    throw 'This harness requires a manual run in the download repository on Windows.'
}

$runSuffix = $env:GITHUB_RUN_ID + '-' + $env:GITHUB_RUN_ATTEMPT
$private = Join-Path $env:RUNNER_TEMP ('focoach-electron-private-' + $runSuffix)
$source = Join-Path $private 'source'
$logs = Join-Path $private 'logs'
$artifact = Join-Path $env:RUNNER_TEMP ('focoach-electron-artifact-' + $runSuffix)
$verification = Join-Path $artifact 'verification'
$stateFile = Join-Path $private 'source-input.json'
$summaryFile = Join-Path $verification 'build.json'

function Write-Json($Value, [string]$Path) {
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-PublicErrorType($Record) {
    $name = $Record.Exception.GetType().Name
    if ($name -in @('RuntimeException', 'IOException', 'UnauthorizedAccessException',
        'InvalidDataException', 'InvalidOperationException', 'FileNotFoundException',
        'DirectoryNotFoundException', 'JsonException', 'ArgumentException',
        'MethodInvocationException', 'CommandNotFoundException', 'ParameterBindingException',
        'ActionPreferenceStopException')) { return $name }
    return 'OtherException'
}

function Get-TestDiagnostics([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $diagnostics = [Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^not ok [0-9]+(?: - [^\x00-\x1f]{1,200})?$') {
            $diagnostics.Add($line)
        } elseif ($line -match '^\s*(?:code|errorCode):\s*[\x27\x22]?(?<code>ERR_[A-Z0-9_]+|E[A-Z0-9_]+)[\x27\x22]?\s*$' -or
            $line -match '^npm (?:ERR!|error) code (?<code>ERR_[A-Z0-9_]+|E[A-Z0-9_]+)\s*$') {
            $diagnostics.Add('errorCode: ' + $Matches.code)
        }
        if ($diagnostics.Count -ge 30) { break }
    }
    return @($diagnostics | Select-Object -Unique)
}

function Read-SourceState {
    if (!(Test-Path -LiteralPath $stateFile -PathType Leaf)) { throw 'Verified source metadata is unavailable.' }
    return Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json -AsHashtable
}

function Assert-Draft([string]$Tag) {
    # The REST tag endpoint omits drafts. Resolve the draft's numeric API ID first.
    $apiUrl = & gh release view $Tag --repo $env:GITHUB_REPOSITORY --json apiUrl --jq .apiUrl 2> (Join-Path $logs 'release-lookup.stderr')
    if ($LASTEXITCODE -ne 0) { throw 'The source draft cannot be resolved with this run token.' }
    if ($apiUrl -isnot [string] -or
        $apiUrl -cnotmatch '^https://api\.github\.com/repos/penguiin1/focoach-downloads/releases/[1-9][0-9]*$') {
        throw 'The source draft API URL must identify this repository and a numeric release ID.'
    }
    $raw = & gh api $apiUrl 2> (Join-Path $logs 'release-api.stderr')
    if ($LASTEXITCODE -ne 0) { throw 'The source draft cannot be read with this run token.' }
    $release = $raw | ConvertFrom-Json
    if ($release.tag_name -cne $Tag -or $release.draft -ne $true -or $null -ne $release.published_at) {
        throw 'Private source must remain in a never-published draft.'
    }
    return $release
}

function Read-GitArchiveCommit([string]$Archive) {
    # git archive --format=zip records the commit in the ZIP's final comment.
    $stream = [IO.File]::OpenRead($Archive)
    try {
        $length = [int][Math]::Min(65557, $stream.Length)
        $tail = [byte[]]::new($length)
        $null = $stream.Seek(-$length, [IO.SeekOrigin]::End)
        $stream.ReadExactly($tail, 0, $length)
        for ($index = $tail.Length - 22; $index -ge 0; $index--) {
            if ([BitConverter]::ToUInt32($tail, $index) -ne 0x06054b50) { continue }
            $commentLength = [BitConverter]::ToUInt16($tail, $index + 20)
            if ($index + 22 + $commentLength -ne $tail.Length) { continue }
            $comment = [Text.Encoding]::ASCII.GetString($tail, $index + 22, $commentLength)
            if ($comment -cmatch '^[0-9a-f]{40}$') { return $comment }
            break
        }
    } finally { $stream.Dispose() }
    throw 'The source ZIP must be a git archive of a commit, with its commit comment intact.'
}

function Assert-Archive([string]$Archive) {
    Add-Type -AssemblyName System.IO.Compression
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        if ($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt 50000) { throw 'Source ZIP has an invalid entry count.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [long]$expanded = 0
        $root = [IO.Path]::GetFullPath($source) + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $relative = $name.TrimEnd('/')
            if (!$relative -or $name.Contains('\') -or $name.Contains(':') -or $name.StartsWith('/') -or
                ($relative.Split('/') | Where-Object { $_ -in @('', '.', '..') })) {
                throw 'Source ZIP contains an unsafe path.'
            }
            foreach ($part in $relative.Split('/')) {
                if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part.EndsWith('.') -or
                    $part.EndsWith(' ') -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
                    throw 'Source ZIP contains a name that aliases a Windows device or another path.'
                }
            }
            if (!$seen.Add($relative) -or
                (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or
                ($entry.ExternalAttributes -band 0x400) -ne 0) {
                throw 'Source ZIP contains duplicate names or links.'
            }
            $destination = [IO.Path]::GetFullPath([IO.Path]::Combine($source, $relative))
            if (!$destination.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source ZIP escapes its extraction directory.' }
            if ($entry.Length -lt 0 -or $entry.Length -gt 1073741824 - $expanded) { throw 'Source ZIP expands beyond its size limit.' }
            $expanded += $entry.Length
        }
    } finally { $zip.Dispose() }
}

if ($Phase -eq 'Restore') {
    $tag = $env:FOCOACH_SOURCE_TAG
    $asset = $env:FOCOACH_SOURCE_ASSET
    $sha = $env:FOCOACH_SOURCE_SHA256
    if ($tag -cnotmatch '^qa-[A-Za-z0-9][A-Za-z0-9._-]{0,119}$' -or
        $asset -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,159}\.zip$' -or
        $sha -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'Provide a qa-* draft tag, a plain ZIP asset name and a 64-digit SHA-256.'
    }
    if (Test-Path -LiteralPath $private) { throw 'The private staging directory must be new.' }
    New-Item -ItemType Directory -Path $logs, $verification -Force | Out-Null
    $restoreStage = 'lookup'
    try {
        $release = Assert-Draft $tag
        $sourceAssets = @($release.assets | Where-Object { $_.name -ceq $asset })
        if ($sourceAssets.Count -ne 1 -or $sourceAssets[0].size -le 0 -or $sourceAssets[0].size -gt 536870912) {
            throw 'Exactly one bounded source asset is required.'
        }
        $restoreStage = 'download'
        & gh release download $tag --repo $env:GITHUB_REPOSITORY --pattern $asset --dir $private *> (Join-Path $logs 'source-download.log')
        if ($LASTEXITCODE -ne 0) { throw 'The frozen source download failed.' }
        $restoreStage = 'hash'
        $archive = Join-Path $private $asset
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ((Get-Item -LiteralPath $archive).Length -ne $sourceAssets[0].size -or $actual -cne $sha.ToLowerInvariant()) {
            throw 'The private source size or SHA-256 does not match its frozen input.'
        }
        $restoreStage = 'lookup'
        $null = Assert-Draft $tag
        $restoreStage = 'archive'
        Assert-Archive $archive
        $commit = Read-GitArchiveCommit $archive
        $restoreStage = 'extract'
        New-Item -ItemType Directory -Path $source | Out-Null
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $source)
        $restoreStage = 'package'
        $package = Get-Content -LiteralPath (Join-Path $source 'package.json') -Raw | ConvertFrom-Json
        if ($package.main -cne 'main/index.cjs' -or !$package.scripts.'release:desktop' -or
            $package.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$') {
            throw 'The frozen archive must contain the desktop release source at its root.'
        }
        $state = [ordered]@{
            schemaVersion = 1; repository = $env:GITHUB_REPOSITORY
            sourceTag = $tag; sourceAsset = $asset; sourceSha256 = $actual
            sourceSizeBytes = (Get-Item -LiteralPath $archive).Length; sourceCommit = $commit
            version = $package.version; platform = 'win32'; architecture = 'x64'
            workflowCommit = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID
            runAttempt = $env:GITHUB_RUN_ATTEMPT; sourceDraftVerified = $true
        }
        Write-Json $state $stateFile
        Write-Json $state (Join-Path $verification 'source-input.json')
        Add-Content -LiteralPath $env:GITHUB_ENV -Value ('FOCOACH_SOURCE_COMMIT=' + $commit) -Encoding utf8NoBOM
        Write-Json ([ordered]@{ success = $true; stage = 'package'; failureCode = $null; errorType = $null }) (Join-Path $verification 'source-restore.json')
        Write-Host 'Verified and restored the private source; no source content is printed.'
    } catch {
        Write-Json ([ordered]@{
            success = $false; stage = $restoreStage
            failureCode = 'source-' + $restoreStage + '-failed'; errorType = Get-PublicErrorType $_
        }) (Join-Path $verification 'source-restore.json')
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $logs 'restore-error.log')
        throw 'Private source restoration failed; detailed source output is withheld.'
    }
    exit 0
}

if ($Phase -eq 'Build') {
    $state = Read-SourceState
    $summary = [ordered]@{ sourceCommit = $state.sourceCommit; version = $state.version; success = $false; steps = @() }
    function Invoke-PrivateStep([string]$Name, [scriptblock]$Action) {
        $log = Join-Path $logs ($Name + '.log')
        $started = [DateTimeOffset]::UtcNow
        $passed = $false
        $exitCode = 0
        $errorType = $null
        $global:LASTEXITCODE = 0
        try {
            & $Action *> $log
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) { $errorType = 'NativeCommandExit'; throw 'The private command failed.' }
            $passed = $true
        } catch {
            if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE } else { $exitCode = 1 }
            if (!$errorType) { $errorType = Get-PublicErrorType $_ }
            $_ | Out-String | Add-Content -LiteralPath $log
        }
        $summary.steps += [ordered]@{
            name = $Name; passed = $passed; exitCode = $exitCode
            failureCode = $(if ($passed) { $null } else { 'build-step-failed' }); errorType = $errorType
            diagnostics = @(if (!$passed -and $Name -ceq 'node-tests') { Get-TestDiagnostics $log })
            durationSeconds = [Math]::Round(([DateTimeOffset]::UtcNow - $started).TotalSeconds, 2)
        }
        Write-Json $summary $summaryFile
        if (!$passed) { throw "Private build step '$Name' failed; detailed output is withheld." }
        Write-Host "Completed $Name."
    }
    Push-Location $source
    try {
        $env:FOCOACH_ELECTRON_DATA_DIR = Join-Path $private 'isolated-userdata'
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        Invoke-PrivateStep 'npm-ci' { & npm.cmd ci --no-audit --no-fund }
        Invoke-PrivateStep 'node-tests' { & npm.cmd test }
        Invoke-PrivateStep 'native-private-desktop' { & ./native/windows/Build.ps1 -CheckPrivateDesktop }
        Invoke-PrivateStep 'electron-package' { & npm.cmd run package:win }
        Invoke-PrivateStep 'packaged-application' { & npm.cmd run check:package }
        Invoke-PrivateStep 'desktop-release' { & npm.cmd run release:desktop -- win32 x64 }
        Invoke-PrivateStep 'installed-update-package' { & node.exe ./scripts/check-update-package.cjs }
        $summary.success = $true
        Write-Json $summary $summaryFile
    } finally { Pop-Location }
    exit 0
}

if ($Phase -eq 'Collect') {
    New-Item -ItemType Directory -Path $verification -Force | Out-Null
    $summary = if (Test-Path -LiteralPath $summaryFile) { Get-Content -LiteralPath $summaryFile -Raw | ConvertFrom-Json -AsHashtable } else { @{ success = $false; steps = @() } }
    $report = @('Private source and detailed command output are intentionally excluded.')
    foreach ($step in $summary.steps) {
        $report += "$($step.name): passed=$($step.passed); exitCode=$($step.exitCode); errorType=$($step.errorType); seconds=$($step.durationSeconds)"
        $report += @($step.diagnostics)
    }
    $testLog = Join-Path $logs 'node-tests.log'
    if (Test-Path -LiteralPath $testLog) {
        $report += @(Get-Content -LiteralPath $testLog | Where-Object { $_ -match '^# (tests|suites|pass|fail|cancelled|skipped|todo|duration_ms) [0-9.]+$' })
    }
    $report | Set-Content -LiteralPath (Join-Path $verification 'verification.log') -Encoding utf8NoBOM
    if (!$summary.success) { Write-Host 'Only sanitized failure verification will be uploaded.'; exit 0 }

    $state = Read-SourceState
    $output = Join-Path $source 'dist/releases/win32-x64'
    $files = @(Get-ChildItem -LiteralPath $output -File | Where-Object {
        $_.Extension -in @('.exe', '.zip', '.yml', '.blockmap', '.json', '.sha256', '.txt') -and
        $_.Name -notlike 'builder-*'
    })
    if (!($files | Where-Object Extension -eq '.exe') -or !($files | Where-Object Extension -eq '.zip') -or
        !($files | Where-Object Name -ceq 'latest.yml')) {
        throw 'The release must produce an NSIS setup, ZIP and latest.yml.'
    }
    $destination = Join-Path $artifact 'releases/win32-x64'
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $inventory = foreach ($file in $files) {
        if ($file.Length -le 0 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Release files must be nonempty regular files.' }
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $destination $file.Name)
        [ordered]@{ name = $file.Name; sizeBytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    Write-Json ([ordered]@{ sourceCommit = $state.sourceCommit; version = $state.version; files = @($inventory) }) (Join-Path $verification 'artifacts.json')
    Write-Host 'Collected only release distributables and sanitized verification.'
    exit 0
}

if ($Phase -eq 'Cleanup') {
    if (Test-Path -LiteralPath $private) {
        Remove-Item -LiteralPath $private -Recurse -Force
    }
}
