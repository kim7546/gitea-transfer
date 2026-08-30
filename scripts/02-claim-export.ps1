param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet("test", "prod")]
    [string]$Mode = "test"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8


function Assert-GitSuccess {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) {
        throw $Message
    }
}

function Get-ToolkitRoot {
    return (Split-Path $PSScriptRoot -Parent)
}

function Get-JsonFile {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) {
        throw "설정 파일이 없습니다: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}

function Invoke-GitLines {
    param([object[]]$Args)
    $result = @(& git @Args)
    Assert-GitSuccess ("git 명령 실패: git " + ($Args -join " "))
    return $result
}

function Get-TagTarget {
    param([string]$Tag)
    $value = (& git rev-parse "$Tag^{}").Trim()
    Assert-GitSuccess "Tag Commit 조회 실패: $Tag"
    return $value
}

function Get-TagId {
    param([string]$Tag, [string]$Prefix)
    if (!$Tag.StartsWith($Prefix)) {
        return ""
    }
    return $Tag.Substring($Prefix.Length)
}

function Get-LatestSuccessTag {
    param([string]$SuccessPrefix)
    $tags = @(& git tag -l "$SuccessPrefix*" --sort=-refname)
    Assert-GitSuccess "Success Tag 조회 실패"
    if ($tags.Count -eq 0) {
        return $null
    }
    return ([string]$tags[0]).Trim()
}

function Get-ActiveFreezeTag {
    param(
        [string]$FreezePrefix,
        [string]$SuccessPrefix,
        [string]$RejectedPrefix
    )

    $latestSuccess = Get-LatestSuccessTag $SuccessPrefix
    if (!$latestSuccess) {
        throw "Success Tag가 없습니다. 최초 기준점(Baseline)을 먼저 초기화하세요."
    }

    $successId = Get-TagId $latestSuccess $SuccessPrefix

    $freezeTags = @(& git tag -l "$FreezePrefix*" --sort=refname)
    Assert-GitSuccess "Freeze Tag 조회 실패"

    $active = New-Object System.Collections.Generic.List[string]

    foreach ($tagObj in $freezeTags) {
        $tag = ([string]$tagObj).Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }

        $freezeId = Get-TagId $tag $FreezePrefix

        if ($freezeId -le $successId) {
            continue
        }

        $matchingSuccess = "$SuccessPrefix$freezeId"
        $matchingRejected = "$RejectedPrefix$freezeId"

        & git show-ref --tags --verify --quiet "refs/tags/$matchingSuccess"
        $hasSuccess = ($LASTEXITCODE -eq 0)

        & git show-ref --tags --verify --quiet "refs/tags/$matchingRejected"
        $hasRejected = ($LASTEXITCODE -eq 0)

        if (!$hasSuccess -and !$hasRejected) {
            $active.Add($tag)
        }
    }

    if ($active.Count -eq 0) {
        throw "처리할 Freeze가 없습니다. 먼저 Freeze를 실행하세요."
    }

    if ($active.Count -gt 1) {
        throw @"
완료되지 않은 Freeze Tag가 2개 이상 있습니다.

$($active -join "`n")

새 Freeze를 만들기 전에 이전 Freeze를 먼저 완료해야 합니다.
반입담당자끼리 현재 Freeze 상태를 확인하세요.
"@
    }

    return $active[0]
}

function Normalize-Extension {
    param([string]$Extension)
    $e = $Extension.Trim().ToLowerInvariant()
    if (!$e.StartsWith(".")) { $e = "." + $e }
    return $e
}

function Get-PathSpecs {
    param(
        [object[]]$IncludePaths,
        [object[]]$ExcludeExtensions
    )

    $specs = New-Object System.Collections.Generic.List[string]

    foreach ($pObj in $IncludePaths) {
        $p = ([string]$pObj).Trim()
        if (![string]::IsNullOrWhiteSpace($p)) {
            $specs.Add($p.Replace("\", "/"))
        }
    }

    foreach ($eObj in $ExcludeExtensions) {
        $e = Normalize-Extension ([string]$eObj)
        if (![string]::IsNullOrWhiteSpace($e)) {
            $specs.Add(":(exclude,glob)**/*$e")
        }
    }

    return $specs.ToArray()
}

function New-EmptyZip {
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) {
        Remove-Item -LiteralPath $ZipPath -Force
    }
    $stream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        $archive.Dispose()
    }
    finally {
        $stream.Dispose()
    }
}


function Get-BranchKey {
    param([string]$BranchName)
    if ([string]::IsNullOrWhiteSpace($BranchName)) { throw "BranchName이 비어 있습니다." }
    $key = $BranchName.Trim().Replace("\\", "__").Replace("/", "__")
    $key = $key -replace '[<>:"|?*]', '_'
    $key = $key -replace '\s+', '_'
    return $key
}

function Get-ExternalTransferSettings {
    param(
        [object]$ProjectConfig,
        [object]$GlobalConfig,
        [string]$Mode
    )

    $modeKey = $Mode.Trim().ToLowerInvariant()
    if ($modeKey -notin @("test", "prod")) {
        throw "Mode는 test 또는 prod만 사용할 수 있습니다: $Mode"
    }

    $remote = [string]$ProjectConfig.external.remote
    if ([string]::IsNullOrWhiteSpace($remote)) { $remote = "origin" }

    $profiles = $ProjectConfig.external.profiles
    if (!$profiles) { throw "external.profiles 설정이 없습니다. v7 프로젝트 설정파일을 사용하세요." }

    $profileProperty = $profiles.PSObject.Properties[$modeKey]
    if (!$profileProperty) { throw "external.profiles.$modeKey 설정이 없습니다." }
    $profile = $profileProperty.Value

    $sourceBranch = [string]$profile.sourceBranch
    if ([string]::IsNullOrWhiteSpace($sourceBranch)) {
        throw "external.profiles.$modeKey.sourceBranch 설정이 없습니다."
    }

    # 핵심: 상태 키는 Project + Mode + SourceBranch 이다.
    # Git Tag에는 실제 브랜치명을 그대로 namespace로 사용하고,
    # Windows 폴더/내부 import branch에는 안전한 BranchKey를 사용한다.
    $tagScope = $modeKey
    $branchKey = Get-BranchKey $sourceBranch
    $stateScope = "$modeKey/$sourceBranch"

    return [pscustomobject]@{
        Remote = $remote
        SourceBranch = $sourceBranch
        BranchKey = $branchKey
        TagScope = $tagScope
        StateScope = $stateScope
        FreezePrefix = "$([string]$GlobalConfig.tagPrefixes.freeze)$modeKey/$sourceBranch/"
        SuccessPrefix = "$([string]$GlobalConfig.tagPrefixes.success)$modeKey/$sourceBranch/"
        ClaimPrefix = "$([string]$GlobalConfig.tagPrefixes.claim)$modeKey/$sourceBranch/"
        RejectedPrefix = "$([string]$GlobalConfig.tagPrefixes.rejected)$modeKey/$sourceBranch/"
    }
}

function Get-RemoteTagExists {
    param(
        [string]$Remote,
        [string]$Tag
    )
    $lines = @(& git ls-remote --tags $Remote "refs/tags/$Tag")
    Assert-GitSuccess "Remote Tag 조회 실패: $Tag"
    return ($lines.Count -gt 0)
}


function Test-LocalTagExists {
    param([string]$Tag)
    $tags = @(& git tag -l $Tag)
    Assert-GitSuccess "Local Tag 조회 실패: $Tag"
    return ($tags.Count -gt 0)
}
function Remove-LocalTagIfExists {
    param([string]$Tag)
    if (Test-LocalTagExists $Tag) {
        & git tag -d $Tag | Out-Null
        Assert-GitSuccess "Local Tag 삭제 실패: $Tag"
    }
}

function Fetch-OneTag {
    param(
        [string]$Remote,
        [string]$Tag
    )
    & git fetch $Remote "+refs/tags/${Tag}:refs/tags/${Tag}" | Out-Null
    Assert-GitSuccess "Tag Fetch 실패: $Tag"
}

function Get-TagMessage {
    param([string]$Tag)
    $lines = @(& git for-each-ref "refs/tags/$Tag" --format="%(contents)")
    Assert-GitSuccess "Tag Message 조회 실패: $Tag"
    return ($lines -join "`n")
}


function Get-ProjectConfig {
    param([string]$ToolkitRoot, [string]$ProjectName)
    return Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")
}

function Get-SelectedCommits {
    param(
        [string]$FromCommit,
        [string]$ToCommit,
        [string[]]$PathSpecs,
        [object[]]$AllowedAuthorEmails
    )

    $allowed = @{}
    foreach ($emailObj in $AllowedAuthorEmails) {
        $e = ([string]$emailObj).Trim().ToLowerInvariant()
        if (![string]::IsNullOrWhiteSpace($e)) {
            $allowed[$e] = $true
        }
    }

    if ($allowed.Count -eq 0) {
        throw "allowedAuthorEmails가 비어 있습니다. 프로젝트별 반입 대상 개발자 Email을 설정하세요."
    }

    $args = @(
        "log",
        "$FromCommit..$ToCommit",
        "--reverse",
        "--no-merges",
        "--format=%H%x09%ae",
        "--"
    ) + $PathSpecs

    $lines = @(& git @args)
    Assert-GitSuccess "Commit 목록 조회 실패"

    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($lineObj in $lines) {
        $line = [string]$lineObj
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split "`t", 2
        if ($parts.Count -lt 2) { continue }

        $hash = $parts[0].Trim()
        $email = $parts[1].Trim().ToLowerInvariant()

        if ($allowed.ContainsKey($email)) {
            $selected.Add([pscustomobject]@{
                Hash = $hash
                Email = $email
            })
        }
    }

    return $selected.ToArray()
}

function New-OneCommitPatch {
    param(
        [string]$CommitHash,
        [int]$Sequence,
        [string[]]$PathSpecs,
        [string]$PatchDirectory,
        [string]$TempDirectory
    )

    $oneDir = Join-Path $TempDirectory ("patch-" + $Sequence.ToString("D4"))
    New-Item -ItemType Directory -Force -Path $oneDir | Out-Null

    $args = @(
        "format-patch",
        "-1",
        "--no-signature",
        "--no-renames",
        "--output-directory=$oneDir",
        $CommitHash,
        "--"
    ) + $PathSpecs

    & git @args | Out-Null
    Assert-GitSuccess "Patch 생성 실패: $CommitHash"

    $generated = @(
        Get-ChildItem -LiteralPath $oneDir -Filter "*.patch" -File
    )

    if ($generated.Count -ne 1) {
        throw "Commit $CommitHash 의 Patch 파일이 정확히 1개 생성되지 않았습니다."
    }

    $shortHash = $CommitHash.Substring(0, [Math]::Min(12, $CommitHash.Length))
    $destination = Join-Path $PatchDirectory (
        "{0:D4}-{1}.patch" -f $Sequence, $shortHash
    )

    Move-Item -LiteralPath $generated[0].FullName -Destination $destination -Force
    return $destination
}

function Write-CommitInfo {
    param(
        [string[]]$CommitHashes,
        [string]$OutputFile
    )

    $all = New-Object System.Collections.Generic.List[string]

    foreach ($hash in $CommitHashes) {
        $lines = @(& git show -s --date=iso-strict `
            --format="Commit : %H%nAuthor : %an <%ae>%nAuthorDate : %aI%nCommitter : %cn <%ce>%nTitle : %s%nBody : %b%n----------------------------------------" `
            $hash)
        Assert-GitSuccess "Commit 정보 조회 실패: $hash"

        foreach ($line in $lines) {
            $all.Add([string]$line)
        }
    }

    if ($all.Count -eq 0) {
        "" | Set-Content -Encoding UTF8 $OutputFile
    }
    else {
        $all | Set-Content -Encoding UTF8 $OutputFile
    }
}


function Get-SparrowEnabled {
    param([object]$ProjectConfig)
    if (!$ProjectConfig.sparrow) { return $false }
    return [bool]$ProjectConfig.sparrow.enabled
}

function Get-SafeFileName {
    param([string]$Value)
    $name = $Value
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) {
        $name = $name.Replace([string]$c, "_")
    }
    return $name
}

function Write-SelectedDeveloperLog {
    param(
        [object[]]$SelectedCommits,
        [string]$OutputFile
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Selected developers / commits for this transfer")
    $lines.Add("================================================")
    $lines.Add("")

    if ($SelectedCommits.Count -eq 0) {
        $lines.Add("No selected commits.")
    }
    else {
        foreach ($item in $SelectedCommits) {
            $hash = [string]$item.Hash
            $email = [string]$item.Email
            $authorName = (& git show -s --format="%an" $hash).Trim()
            Assert-GitSuccess "Commit Author 조회 실패: $hash"
            $subject = (& git show -s --format="%s" $hash).Trim()
            Assert-GitSuccess "Commit 제목 조회 실패: $hash"

            $lines.Add("Author : $authorName <$email>")
            $lines.Add("Commit : $hash")
            $lines.Add("Title  : $subject")
            $lines.Add("Files  :")

            $files = @(& git show --pretty="" --name-only --no-renames $hash)
            Assert-GitSuccess "Commit 파일 목록 조회 실패: $hash"

            foreach ($fileObj in $files) {
                $file = ([string]$fileObj).Trim()
                if (![string]::IsNullOrWhiteSpace($file)) {
                    $lines.Add("  - $file")
                }
            }
            $lines.Add("----------------------------------------")
        }
    }

    $lines | Set-Content -Encoding UTF8 $OutputFile
}

function Remove-ClaimTag {
    param(
        [string]$Remote,
        [string]$ClaimTag
    )

    if (Get-RemoteTagExists $Remote $ClaimTag) {
        & git push $Remote ":refs/tags/$ClaimTag" | Out-Null
        Assert-GitSuccess "Remote Claim Tag 삭제 실패: $ClaimTag"
    }
    Remove-LocalTagIfExists $ClaimTag
}

function New-RejectedTag {
    param(
        [string]$Remote,
        [string]$RejectedTag,
        [string]$TargetCommit,
        [string]$Message
    )

    if (Get-RemoteTagExists $Remote $RejectedTag) {
        Fetch-OneTag $Remote $RejectedTag
        return
    }

    Remove-LocalTagIfExists $RejectedTag
    & git tag -a $RejectedTag $TargetCommit -m $Message
    Assert-GitSuccess "Rejected Tag 생성 실패"

    & git push $Remote "refs/tags/$RejectedTag" | Out-Null
    Assert-GitSuccess "Rejected Tag Push 실패"
}

function Invoke-SparrowRunner {
    param(
        [string]$RunnerPath,
        [string]$ScanDirectory,
        [string]$ResultDirectory,
        [string]$ProjectName,
        [string]$Mode,
        [string]$SourceBranch,
        [string]$FreezeId
    )

    if ([string]::IsNullOrWhiteSpace($RunnerPath)) {
        throw "global.json의 sparrowRunnerPath가 비어 있습니다."
    }
    if (!(Test-Path -LiteralPath $RunnerPath)) {
        throw "Sparrow Runner가 없습니다: $RunnerPath"
    }

    New-Item -ItemType Directory -Force -Path $ResultDirectory | Out-Null
    $runnerLog = Join-Path $ResultDirectory "runner-output.log"

    $runnerArgs = @(
        $ScanDirectory,
        $ResultDirectory,
        $ProjectName,
        $Mode,
        $SourceBranch,
        $FreezeId
    )

    Write-Host ""
    Write-Host "===================================================="
    Write-Host " SPARROW SCAN"
    Write-Host "===================================================="
    Write-Host "ScanDir : $ScanDirectory"
    Write-Host "Result  : $ResultDirectory"
    Write-Host ""

    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $RunnerPath @runnerArgs 2>&1 | Tee-Object -FilePath $runnerLog
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    return [int]$exitCode
}

function Write-SparrowStatus {
    param(
        [string]$ResultDirectory,
        [string]$Status,
        [int]$ExitCode,
        [string]$ProjectName,
        [string]$Mode,
        [string]$SourceBranch,
        [string]$FreezeId,
        [int]$SelectedCommitCount
    )

    New-Item -ItemType Directory -Force -Path $ResultDirectory | Out-Null

    $statusObject = [ordered]@{
        projectName = $ProjectName
        mode = $Mode
        sourceBranch = $SourceBranch
        freezeId = $FreezeId
        status = $Status
        exitCode = $ExitCode
        selectedCommitCount = $SelectedCommitCount
        scannedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    }

    $statusObject | ConvertTo-Json -Depth 10 |
        Set-Content -Encoding UTF8 (Join-Path $ResultDirectory "scan-status.json")
}


$ProjectRoot = (Resolve-Path $ProjectRoot).Path.TrimEnd("\")
$ProjectName = Split-Path $ProjectRoot -Leaf
$ToolkitRoot = Get-ToolkitRoot

$globalConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$projectConfig = Get-ProjectConfig $ToolkitRoot $ProjectName

if ([string]$projectConfig.projectName -ne $ProjectName) {
    throw "프로젝트 폴더명과 config projectName이 다릅니다. Folder=$ProjectName Config=$($projectConfig.projectName)"
}

$ext = Get-ExternalTransferSettings $projectConfig $globalConfig $Mode
$freezePrefix = $ext.FreezePrefix
$successPrefix = $ext.SuccessPrefix
$claimPrefix = $ext.ClaimPrefix
$rejectedPrefix = $ext.RejectedPrefix
$remote = $ext.Remote
$sourceBranch = $ext.SourceBranch
$tagScope = $ext.TagScope
$branchKey = $ext.BranchKey
$stateScope = $ext.StateScope
$includePaths = @($projectConfig.includePaths)
$excludeExtensions = @($projectConfig.excludeExtensions)
$allowedAuthors = @($projectConfig.allowedAuthorEmails)
$pathSpecs = @(Get-PathSpecs $includePaths $excludeExtensions)

$distRoot = [string]$globalConfig.externalDistRoot
$projectDistRoot = Join-Path (Join-Path (Join-Path $distRoot $ProjectName) $tagScope) $branchKey

$sparrowEnabled = Get-SparrowEnabled $projectConfig
$scanRoot = [string]$globalConfig.externalScanRoot
$sparrowResultRoot = [string]$globalConfig.sparrowResultRoot
$sparrowRunnerPath = [string]$globalConfig.sparrowRunnerPath

if ([string]::IsNullOrWhiteSpace($scanRoot)) {
    $scanRoot = Join-Path $ToolkitRoot "scan"
}
if ([string]::IsNullOrWhiteSpace($sparrowResultRoot)) {
    $sparrowResultRoot = Join-Path $ToolkitRoot "results\sparrow"
}

New-Item -ItemType Directory -Force -Path $projectDistRoot | Out-Null

Push-Location $ProjectRoot

$tempRoot = $null
$replayDir = $null

try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " CLAIM & EXPORT"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Source  : $remote/$sourceBranch"
    Write-Host "Mode    : $tagScope"
    Write-Host "Branch  : $sourceBranch"
    Write-Host "State   : $ProjectName / $stateScope"
    $sparrowLabel = if ($sparrowEnabled) { "ENABLED" } else { "DISABLED" }
    Write-Host "Sparrow : $sparrowLabel"
    Write-Host ""

    & git fetch $remote --tags --prune
    Assert-GitSuccess "git fetch 실패"

    $freezeTag = Get-ActiveFreezeTag $freezePrefix $successPrefix $rejectedPrefix
    $freezeId = Get-TagId $freezeTag $freezePrefix
    $successTag = Get-LatestSuccessTag $successPrefix
    $fromCommit = Get-TagTarget $successTag
    $toCommit = Get-TagTarget $freezeTag

    & git merge-base --is-ancestor $fromCommit $toCommit
    if ($LASTEXITCODE -ne 0) {
        throw "Success Commit이 Freeze Commit의 조상이 아닙니다. Git history를 확인하세요."
    }

    Write-Host "Success : $successTag -> $fromCommit"
    Write-Host "Freeze  : $freezeTag -> $toCommit"
    Write-Host ""

    # Claim 획득
    $operatorName = (& git config user.name).Trim()
    $operatorEmail = (& git config user.email).Trim()

    if ([string]::IsNullOrWhiteSpace($operatorEmail)) {
        throw "git config user.email이 없습니다. 반입담당자 개인 Email을 설정하세요."
    }

    $claimTag = "$claimPrefix$freezeId"
    $claimExists = Get-RemoteTagExists $remote $claimTag

    if ($claimExists) {
        Fetch-OneTag $remote $claimTag
        $claimMessage = Get-TagMessage $claimTag

        $ownerLine = @($claimMessage -split "`n" | Where-Object { $_ -like "OperatorEmail=*" } | Select-Object -First 1)
        $ownerEmail = ""
        if ($ownerLine.Count -gt 0) {
            $ownerEmail = ([string]$ownerLine[0]).Substring("OperatorEmail=".Length).Trim()
        }

        if ($ownerEmail.ToLowerInvariant() -ne $operatorEmail.ToLowerInvariant()) {
            throw @"
이미 다른 반입담당자가 이 프로젝트를 선점(Claim)했습니다.

Project : $ProjectName
Freeze  : $freezeId
Owner   : $ownerEmail

다른 프로젝트를 선택하거나 반입담당자끼리 확인 후 Claim을 해제하세요.
"@
        }

        Write-Host "현재 사용자가 이미 Claim한 프로젝트입니다. 재실행을 허용합니다."
    }
    else {
        Remove-LocalTagIfExists $claimTag

        $claimMessage = @"
Type=CLAIM
Project=$ProjectName
Mode=$tagScope
SourceBranch=$sourceBranch
BranchKey=$branchKey
StateScope=$stateScope
FreezeId=$freezeId
FreezeCommit=$toCommit
OperatorName=$operatorName
OperatorEmail=$operatorEmail
Machine=$env:COMPUTERNAME
ClaimedAt=$((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"))
"@

        & git tag -a $claimTag $toCommit -m $claimMessage
        Assert-GitSuccess "Claim Tag 로컬 생성 실패"

        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & git push $remote "refs/tags/$claimTag" 2>$null
            $claimPushExitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        if ($claimPushExitCode -ne 0) {
            Remove-LocalTagIfExists $claimTag
            & git fetch $remote --tags --prune | Out-Null

            if (Get-RemoteTagExists $remote $claimTag) {
                Fetch-OneTag $remote $claimTag
                $message = Get-TagMessage $claimTag
                throw "다른 사용자가 먼저 Claim했습니다.`n$message"
            }

            throw "Claim Tag Push 실패"
        }

        Write-Host "CLAIM OK : $operatorEmail"
    }

    $selected = @(Get-SelectedCommits $fromCommit $toCommit $pathSpecs $allowedAuthors)
    $selectedHashes = @($selected | ForEach-Object { $_.Hash })

    Write-Host ""
    Write-Host "반입 대상 Commit 수 : $($selectedHashes.Count)"

    $packageDir = Join-Path $projectDistRoot $freezeId
    if (Test-Path -LiteralPath $packageDir) {
        $suffix = Get-Date -Format "HHmmss"
        $packageDir = Join-Path $projectDistRoot "$freezeId-rerun-$suffix"
    }

    $patchDir = Join-Path $packageDir "patches"
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitea-transfer-" + [guid]::NewGuid().ToString("N"))
    $patchTemp = Join-Path $tempRoot "patch-temp"
    $replayDir = Join-Path (Join-Path (Join-Path (Join-Path $scanRoot $ProjectName) $tagScope) $branchKey) $freezeId

    New-Item -ItemType Directory -Force -Path (Split-Path $replayDir -Parent) | Out-Null

    if (Test-Path -LiteralPath $replayDir) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & git worktree remove --force $replayDir 2>$null | Out-Null
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        Remove-Item -LiteralPath $replayDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Force -Path $patchDir | Out-Null
    New-Item -ItemType Directory -Force -Path $patchTemp | Out-Null

    $patchFiles = New-Object System.Collections.Generic.List[string]

    $seq = 1
    foreach ($commit in $selectedHashes) {
        $patch = New-OneCommitPatch $commit $seq $pathSpecs $patchDir $patchTemp
        $patchFiles.Add($patch)
        $seq++
    }

    $developerLog = Join-Path $packageDir "developers.txt"
    Write-SelectedDeveloperLog $selected $developerLog

    $sourceFiles = @()
    $deletedPaths = @()
    $sourceZip = Join-Path $packageDir "source.zip"

    $sparrowStatus = if ($sparrowEnabled) { "PENDING" } else { "SKIPPED_DISABLED" }
    $sparrowExitCode = 0
    $sparrowResultDir = ""
    $sparrowPackageDir = ""

    if ($patchFiles.Count -eq 0) {
        if ($sparrowEnabled) {
            $sparrowStatus = "SKIPPED_NO_COMMITS"
        }
        Write-Host "Sparrow : $sparrowStatus"
        New-EmptyZip $sourceZip
    }
    else {
        # 선택된 Commit만 기준점 위에 재생해서 의존성 확인 + 최종 소스 생성
        & git worktree add --detach $replayDir $fromCommit | Out-Null
        Assert-GitSuccess "임시 Worktree 생성 실패"

        Push-Location $replayDir
        try {
            $patchArray = @($patchFiles.ToArray())
            $oldErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "SilentlyContinue"
                & git am @patchArray
                $gitAmExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $oldErrorActionPreference
            }
            if ($gitAmExitCode -ne 0) {
                $oldErrorActionPreference = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "SilentlyContinue"
                    & git am --abort 2>$null | Out-Null
                }
                finally {
                    $ErrorActionPreference = $oldErrorActionPreference
                }
                throw @"
선택된 개발자 Commit만 재생하는 과정에서 충돌이 발생했습니다.

가능한 원인:
- 선택된 Commit이 반입 대상이 아닌 다른 개발자 Commit에 의존함
- 기준점의 소스와 Commit 전제가 다름

자동 반입을 중단합니다. 반입담당 개발자끼리 의존성을 확인하세요.
"@
            }

            if ($sparrowEnabled) {
                $resultBase = Join-Path (Join-Path (Join-Path (Join-Path $sparrowResultRoot $ProjectName) $tagScope) $branchKey) $freezeId
                $sparrowResultDir = $resultBase
                if (Test-Path -LiteralPath $sparrowResultDir) {
                    $rerunSuffix = Get-Date -Format "HHmmss"
                    $sparrowResultDir = "$resultBase-rerun-$rerunSuffix"
                }

                New-Item -ItemType Directory -Force -Path $sparrowResultDir | Out-Null
                Copy-Item -LiteralPath $developerLog -Destination (Join-Path $sparrowResultDir "developers.txt") -Force

                $sparrowExitCode = Invoke-SparrowRunner `
                    $sparrowRunnerPath `
                    $replayDir `
                    $sparrowResultDir `
                    $ProjectName `
                    $tagScope `
                    $sourceBranch `
                    $freezeId

                if ($sparrowExitCode -eq 0) {
                    $sparrowStatus = "PASS"
                    Write-SparrowStatus $sparrowResultDir $sparrowStatus $sparrowExitCode `
                        $ProjectName $tagScope $sourceBranch $freezeId $selectedHashes.Count

                    $sparrowPackageDir = Join-Path $packageDir "sparrow"
                    New-Item -ItemType Directory -Force -Path $sparrowPackageDir | Out-Null
                    Copy-Item -Path (Join-Path $sparrowResultDir "*") -Destination $sparrowPackageDir -Recurse -Force

                    Write-Host "SPARROW PASS"
                }
                elseif ($sparrowExitCode -eq 10) {
                    $sparrowStatus = "REJECTED"
                    Write-SparrowStatus $sparrowResultDir $sparrowStatus $sparrowExitCode `
                        $ProjectName $tagScope $sourceBranch $freezeId $selectedHashes.Count

                    $rejectedTag = "$rejectedPrefix$freezeId"
                    $rejectedMessage = @"
Type=REJECTED
Reason=SPARROW_FINDINGS
Project=$ProjectName
Mode=$tagScope
SourceBranch=$sourceBranch
BranchKey=$branchKey
StateScope=$stateScope
FreezeId=$freezeId
FreezeCommit=$toCommit
SelectedCommitCount=$($selectedHashes.Count)
OperatorName=$operatorName
OperatorEmail=$operatorEmail
Machine=$env:COMPUTERNAME
ResultDirectory=$sparrowResultDir
RejectedAt=$((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"))
"@
                    New-RejectedTag $remote $rejectedTag $toCommit $rejectedMessage
                    Remove-ClaimTag $remote $claimTag

                    if (Test-Path -LiteralPath $packageDir) {
                        Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
                    }

                    throw @"
Sparrow 검사에서 수정 대상이 발견되어 이번 Freeze를 REJECTED 처리했습니다.

Project : $ProjectName
Branch  : $sourceBranch
Freeze  : $freezeId
Result  : $sparrowResultDir

Freeze Tag는 이력으로 유지됩니다.
Claim Tag는 해제되었습니다.
개발자가 수정 후 main/대상 브랜치에 Merge하면 새 01 Freeze부터 다시 진행하세요.
"@
                }
                else {
                    $sparrowStatus = "TECHNICAL_ERROR"
                    Write-SparrowStatus $sparrowResultDir $sparrowStatus $sparrowExitCode `
                        $ProjectName $tagScope $sourceBranch $freezeId $selectedHashes.Count

                    if (Test-Path -LiteralPath $packageDir) {
                        Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
                    }

                    throw @"
Sparrow 실행 자체가 정상 완료되지 않았습니다.

ExitCode : $sparrowExitCode
Result   : $sparrowResultDir

코드 REJECTED로 처리하지 않았습니다.
현재 Freeze/Claim은 그대로 유지되므로 Sparrow 환경을 수정한 뒤 같은 02를 다시 실행할 수 있습니다.
"@
                }
            }
            else {
                Write-Host "Sparrow : DISABLED - 기존 반입 로직만 수행합니다."
            }

            $diffArgs = @(
                "diff",
                "--name-status",
                "--no-renames",
                "$fromCommit..HEAD",
                "--"
            ) + $pathSpecs

            $diffLines = @(& git @diffArgs)
            Assert-GitSuccess "재생 결과 파일 목록 조회 실패"

            $sourceList = New-Object System.Collections.Generic.List[string]
            $deleteList = New-Object System.Collections.Generic.List[string]

            foreach ($lineObj in $diffLines) {
                $line = [string]$lineObj
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                $parts = $line -split "`t", 2
                if ($parts.Count -lt 2) { continue }

                $status = $parts[0].Trim().ToUpperInvariant()
                $path = $parts[1].Trim().Replace("\", "/")

                if ($status.StartsWith("D")) {
                    $deleteList.Add($path)
                }
                else {
                    $sourceList.Add($path)
                }
            }

            $sourceFiles = @($sourceList | Sort-Object -Unique)
            $deletedPaths = @($deleteList | Sort-Object -Unique)

            if ($sourceFiles.Count -gt 0) {
                $archiveArgs = @(
                    "archive",
                    "--format=zip",
                    "--output=$sourceZip",
                    "HEAD",
                    "--"
                ) + $sourceFiles

                & git @archiveArgs
                Assert-GitSuccess "source.zip 생성 실패"
            }
            else {
                New-EmptyZip $sourceZip
            }
        }
        finally {
            Pop-Location
        }
    }

    $commitFile = Join-Path $packageDir "commits.txt"
    Write-CommitInfo $selectedHashes $commitFile

    $sparrowPackageResultPath = if ($sparrowPackageDir) { "sparrow" } else { "" }

    $manifest = [ordered]@{
        version = "4.1"
        projectName = $ProjectName
        tagScope = $tagScope
        stateScope = $stateScope
        branchKey = $branchKey
        sourceRemote = $remote
        sourceBranch = $sourceBranch
        freezeId = $freezeId
        successTag = $successTag
        freezeTag = $freezeTag
        claimTag = $claimTag
        fromCommit = $fromCommit
        toCommit = $toCommit
        operatorName = $operatorName
        operatorEmail = $operatorEmail
        operatorMachine = $env:COMPUTERNAME
        createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        allowedAuthorEmails = $allowedAuthors
        includePaths = $includePaths
        excludeExtensions = $excludeExtensions
        selectedCommitCount = $selectedHashes.Count
        selectedCommits = $selectedHashes
        patchCount = $patchFiles.Count
        sourceFiles = $sourceFiles
        deletedPaths = $deletedPaths
        sparrow = [ordered]@{
            enabled = $sparrowEnabled
            status = $sparrowStatus
            exitCode = $sparrowExitCode
            packageResultPath = $sparrowPackageResultPath
        }
    }

    $manifestFile = Join-Path $packageDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $manifestFile

    $checksumFile = Join-Path $packageDir "SHA256SUMS.txt"
    Get-ChildItem -LiteralPath $packageDir -Recurse -File |
        Where-Object { $_.FullName -ne $checksumFile } |
        Sort-Object FullName |
        ForEach-Object {
            $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
            $relative = $_.FullName.Substring($packageDir.Length).TrimStart("\").Replace("\", "/")
            "$($hash.Hash)  $relative"
        } |
        Set-Content -Encoding ASCII $checksumFile

    Write-Host ""
    Write-Host "===================================================="
    Write-Host "EXPORT COMPLETE"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Mode    : $tagScope"
    Write-Host "Branch  : $sourceBranch"
    Write-Host "Freeze  : $freezeId"
    Write-Host "From    : $fromCommit"
    Write-Host "To      : $toCommit"
    Write-Host "Commits : $($selectedHashes.Count)"
    Write-Host "Files   : $($sourceFiles.Count)"
    Write-Host "Deleted : $($deletedPaths.Count)"
    Write-Host "Sparrow : $sparrowStatus"
    Write-Host "Package : $packageDir"
    Write-Host ""

    if ($selectedHashes.Count -eq 0) {
        Write-Host "반입 대상 개발자의 Commit이 0건입니다."
        Write-Host "내부 Import/MR은 필요하지 않습니다."
        Write-Host "반입 대상이 0건이면 같은 담당자가 Success 처리를 실행하세요."
    }
    else {
        Write-Host "이 Package 폴더 전체를 내부망 반입 절차로 이동하세요."
    }
}
finally {
    if ($replayDir -and (Test-Path -LiteralPath $replayDir)) {
        $oldErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "SilentlyContinue"
            & git worktree remove --force $replayDir 2>$null | Out-Null
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
    }
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pop-Location
}
