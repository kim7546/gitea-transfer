param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet("test", "prod")]
    [string]$Mode = "test",

    [string]$PackageId = ""
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
        [string]$SuccessPrefix
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
        & git show-ref --tags --verify --quiet "refs/tags/$matchingSuccess"
        if ($LASTEXITCODE -ne 0) {
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

function Get-RemoteTagExists {
    param(
        [string]$Remote,
        [string]$Tag
    )
    $lines = @(& git ls-remote --tags $Remote "refs/tags/$Tag")
    Assert-GitSuccess "Remote Tag 조회 실패: $Tag"
    return ($lines.Count -gt 0)
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


function Get-BranchKey {
    param([string]$BranchName)
    if ([string]::IsNullOrWhiteSpace($BranchName)) { throw "BranchName이 비어 있습니다." }
    $key = $BranchName.Trim().Replace("\\", "__").Replace("/", "__")
    $key = $key -replace '[<>:"|?*]', '_'
    $key = $key -replace '\s+', '_'
    return $key
}

function Get-ConfiguredSourceBranch {
    param([object]$ProjectConfig,[string]$Mode)
    $modeKey = $Mode.Trim().ToLowerInvariant()
    $profiles = $ProjectConfig.external.profiles
    if (!$profiles) { throw "external.profiles 설정이 없습니다. v7 프로젝트 설정파일을 사용하세요." }
    $profileProperty = $profiles.PSObject.Properties[$modeKey]
    if (!$profileProperty) { throw "external.profiles.$modeKey 설정이 없습니다." }
    $sourceBranch = [string]$profileProperty.Value.sourceBranch
    if ([string]::IsNullOrWhiteSpace($sourceBranch)) { throw "external.profiles.$modeKey.sourceBranch 설정이 없습니다." }
    return $sourceBranch
}

function Test-PackageChecksums {
    param([string]$PackageDirectory)

    $checksumFile = Join-Path $PackageDirectory "checksum.txt"
    if (!(Test-Path -LiteralPath $checksumFile)) {
        throw "checksum.txt가 없습니다."
    }

    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($lineObj in Get-Content -LiteralPath $checksumFile) {
        $line = [string]$lineObj
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -notmatch '^([0-9A-Fa-f]{64})\s{2}(.+)$') {
            $errors.Add("잘못된 형식: $line")
            continue
        }

        $expected = $matches[1].ToUpperInvariant()
        $rel = $matches[2].Replace("/", "\")
        $full = Join-Path $PackageDirectory $rel

        if (!(Test-Path -LiteralPath $full)) {
            $errors.Add("파일 없음: $rel")
            continue
        }

        $actual = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToUpperInvariant()
        if ($actual -ne $expected) {
            $errors.Add("HASH 불일치: $rel")
        }
    }

    if ($errors.Count -gt 0) {
        $errors | ForEach-Object { Write-Host "  $_" }
        throw "Package SHA256 검증 실패"
    }
}


function Get-CurrentBranch {
    $branch = (& git branch --show-current).Trim()
    Assert-GitSuccess "현재 Branch 조회 실패"
    return $branch
}

function Test-GitAmInProgress {
    $gitAmPath = (& git rev-parse --git-path rebase-apply).Trim()
    Assert-GitSuccess "git am 상태 조회 실패"
    return (Test-Path -LiteralPath $gitAmPath)
}

function Get-ExpectedCommitTitles {
    param([string]$PackageDirectory)

    $commitFile = Join-Path $PackageDirectory "commits.txt"
    if (!(Test-Path -LiteralPath $commitFile)) {
        return @()
    }

    $titles = New-Object System.Collections.Generic.List[string]
    $insideCommit = $false
    $titleCaptured = $false

    foreach ($lineObj in Get-Content -LiteralPath $commitFile) {
        $line = [string]$lineObj

        if ($line -match '^Commit\s*:') {
            $insideCommit = $true
            $titleCaptured = $false
            continue
        }

        if ($insideCommit -and !$titleCaptured -and $line -match '^Title\s*:\s?(.*)$') {
            $titles.Add([string]$matches[1])
            $titleCaptured = $true
            continue
        }

        if ($line -match '^-{20,}\s*$') {
            $insideCommit = $false
            $titleCaptured = $false
        }
    }

    return $titles.ToArray()
}

function Get-ExpectedAuthorEmails {
    param([string]$PackageDirectory)

    $developerFile = Join-Path $PackageDirectory "developers.txt"
    if (!(Test-Path -LiteralPath $developerFile)) {
        return @()
    }

    $emails = New-Object System.Collections.Generic.List[string]
    foreach ($lineObj in Get-Content -LiteralPath $developerFile) {
        $line = [string]$lineObj
        if ($line -match '^Author\s*:\s.*<([^<>]+)>\s*$') {
            $emails.Add(([string]$matches[1]).Trim().ToLowerInvariant())
        }
    }
    return $emails.ToArray()
}

function Assert-PatchPackageShape {
    param(
        [object]$Manifest,
        [object[]]$PatchFiles
    )

    $selectedCount = [int]$Manifest.selectedCommitCount
    $expectedPatchCount = $selectedCount
    if ($Manifest.PSObject.Properties.Name -contains "patchCount") {
        $expectedPatchCount = [int]$Manifest.patchCount
    }

    if ($expectedPatchCount -ne $selectedCount) {
        throw "Manifest의 selectedCommitCount($selectedCount)와 patchCount($expectedPatchCount)가 다릅니다."
    }

    if ($PatchFiles.Count -ne $selectedCount) {
        throw "Patch 파일 수($($PatchFiles.Count))와 반입 대상 Commit 수($selectedCount)가 다릅니다."
    }
}

function Assert-ImportedCommits {
    param(
        [string]$BaseCommit,
        [int]$ExpectedCount,
        [object[]]$AllowedAuthorEmails,
        [string]$PackageDirectory
    )

    $lines = @(& git log --reverse --format="%H%x09%ae%x09%s" "$BaseCommit..HEAD")
    Assert-GitSuccess "반입 Commit 검증용 git log 실패"

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($lineObj in $lines) {
        $line = [string]$lineObj
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) {
            throw "반입 Commit 정보 형식을 해석할 수 없습니다: $line"
        }
        $items.Add([pscustomobject]@{
            Hash = $parts[0].Trim()
            Email = $parts[1].Trim().ToLowerInvariant()
            Title = $parts[2]
        })
    }

    if ($items.Count -ne $ExpectedCount) {
        throw @"
반입 Branch의 Commit 수가 Package와 다릅니다.

Expected : $ExpectedCount
Actual   : $($items.Count)
Base     : $BaseCommit

충돌 처리 중 별도 Commit을 만들었거나, 반입 Branch 상태가 변경되었을 수 있습니다.
현재 반입 Branch를 확인한 뒤 필요하면 삭제하고 03을 처음부터 다시 실행하세요.
"@
    }

    $allowed = @{}
    foreach ($emailObj in $AllowedAuthorEmails) {
        $email = ([string]$emailObj).Trim().ToLowerInvariant()
        if (![string]::IsNullOrWhiteSpace($email)) {
            $allowed[$email] = $true
        }
    }

    if ($allowed.Count -eq 0) {
        throw "Package의 allowedAuthorEmails가 비어 있습니다."
    }

    foreach ($item in $items) {
        if (!$allowed.ContainsKey([string]$item.Email)) {
            throw "허용되지 않은 Author Email의 Commit이 반입 Branch에 있습니다: $($item.Hash) / $($item.Email)"
        }
    }

    $expectedAuthors = @(Get-ExpectedAuthorEmails $PackageDirectory)
    if ($expectedAuthors.Count -eq $ExpectedCount) {
        for ($i = 0; $i -lt $ExpectedCount; $i++) {
            if ([string]$items[$i].Email -ne [string]$expectedAuthors[$i]) {
                throw @"
반입 Commit Author가 Package 기록과 다릅니다.

Index    : $($i + 1)
Expected : $($expectedAuthors[$i])
Actual   : $($items[$i].Email)
"@
            }
        }
    }
    else {
        Write-Host "[WARNING] developers.txt Author 수가 예상 Commit 수와 달라 정확한 Author 순서 비교는 생략합니다."
    }

    $expectedTitles = @(Get-ExpectedCommitTitles $PackageDirectory)
    if ($expectedTitles.Count -eq $ExpectedCount) {
        for ($i = 0; $i -lt $ExpectedCount; $i++) {
            if ([string]$items[$i].Title -ne [string]$expectedTitles[$i]) {
                throw @"
반입 Commit 제목이 Package 기록과 다릅니다.

Index    : $($i + 1)
Expected : $($expectedTitles[$i])
Actual   : $($items[$i].Title)

충돌 해결 과정에서 Commit message를 변경하지 않았는지 확인하세요.
"@
            }
        }
    }
    else {
        Write-Host "[WARNING] commits.txt 제목 수가 예상 Commit 수와 달라 제목 비교는 생략합니다."
    }

    Write-Host "IMPORT COMMIT VERIFY OK : $ExpectedCount commit(s)"
}

function Compare-SourceReference {
    param(
        [string]$PackageDirectory,
        [object]$Manifest,
        [string]$CurrentProjectRoot
    )

    # source.zip은 반입 합격 조건이 아니다.
    # 외부 Success 기준점 위에 선택된 Commit만 재생한 참고 결과이므로,
    # 다른 팀 변경이 이미 존재하는 내부 main에서는 정상 반입이어도 달라질 수 있다.
    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("transfer-verify-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null

    try {
        $sourceZip = Join-Path $PackageDirectory "reference.txt"
        if (!(Test-Path -LiteralPath $sourceZip)) {
            Write-Host "[WARNING] reference.txt가 없어 참고 비교를 생략합니다."
            return
        }

        # reference.txt는 원래 형식을 숨긴 Base64 참고 데이터이며 03이 메모리/임시영역에서 필요한 형식으로 복원한다.
        # 내부에서만 임시 ZIP으로 복원하여 참고 비교한다.
        $sourceZipForRead = Join-Path $verifyDir "source-reference.zip"
        $sourceZipBase64 = [System.IO.File]::ReadAllText($sourceZip, [System.Text.Encoding]::ASCII).Trim()
        $sourceZipBytes = [Convert]::FromBase64String($sourceZipBase64)
        [System.IO.File]::WriteAllBytes($sourceZipForRead, $sourceZipBytes)
        $sourceExtractDir = Join-Path $verifyDir "source"
        New-Item -ItemType Directory -Force -Path $sourceExtractDir | Out-Null
        Expand-Archive -LiteralPath $sourceZipForRead -DestinationPath $sourceExtractDir -Force
        $differences = New-Object System.Collections.Generic.List[string]

        foreach ($pathObj in @($Manifest.sourceFiles)) {
            $rel = ([string]$pathObj).Replace("/", "\")
            $expectedFile = Join-Path $sourceExtractDir $rel
            $actualFile = Join-Path $CurrentProjectRoot $rel

            if (!(Test-Path -LiteralPath $expectedFile)) {
                $differences.Add("ZIP에 파일 없음: $rel")
                continue
            }

            if (!(Test-Path -LiteralPath $actualFile)) {
                $differences.Add("내부 소스에 파일 없음: $rel")
                continue
            }

            $expectedHash = (Get-FileHash -LiteralPath $expectedFile -Algorithm SHA256).Hash
            $actualHash = (Get-FileHash -LiteralPath $actualFile -Algorithm SHA256).Hash

            if ($expectedHash -ne $actualHash) {
                $differences.Add("내용 불일치: $rel")
            }
        }

        foreach ($pathObj in @($Manifest.deletedPaths)) {
            $rel = ([string]$pathObj).Replace("/", "\")
            $actualFile = Join-Path $CurrentProjectRoot $rel
            if (Test-Path -LiteralPath $actualFile) {
                $differences.Add("참고본에서는 삭제 상태이나 내부에는 존재함: $rel")
            }
        }

        if ($differences.Count -eq 0) {
            Write-Host "SOURCE REFERENCE : MATCH"
        }
        else {
            Write-Host ""
            Write-Host "===================================================="
            Write-Host " SOURCE REFERENCE WARNING"
            Write-Host "===================================================="
            Write-Host "source.zip과 현재 내부 파일이 다릅니다."
            Write-Host "공동 저장소에서 다른 팀의 반입 내용이 내부 main에 존재하면 정상적으로 발생할 수 있습니다."
            Write-Host "이 차이는 03 실패 조건이 아니며 Push를 막지 않습니다."
            Write-Host ""
            $differences | ForEach-Object { Write-Host "  $_" }
            Write-Host ""
        }
    }
    finally {
        if (Test-Path -LiteralPath $verifyDir) {
            Remove-Item -LiteralPath $verifyDir -Recurse -Force
        }
    }
}

$ProjectRoot = (Resolve-Path $ProjectRoot).Path.TrimEnd("\")
$ProjectName = Split-Path $ProjectRoot -Leaf
$ToolkitRoot = Get-ToolkitRoot

$globalConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$projectConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")

$inboundRoot = [string]$globalConfig.internalInboundRoot
$tagScope = $Mode.Trim().ToLowerInvariant()
$sourceBranch = Get-ConfiguredSourceBranch $projectConfig $Mode
$branchKey = Get-BranchKey $sourceBranch
$stateScope = "$tagScope/$sourceBranch"
$projectInbound = Join-Path (Join-Path (Join-Path $inboundRoot $ProjectName) $tagScope) $branchKey
$remote = [string]$projectConfig.internal.remote
$mainBranch = [string]$projectConfig.internal.mainBranch
$branchPrefix = [string]$projectConfig.internal.importBranchPrefix
$autoPush = [bool]$projectConfig.internal.autoPush

$extractRoot = $null
Push-Location $ProjectRoot

try {
    if (Test-GitAmInProgress) {
        $currentBranch = Get-CurrentBranch
        throw @"
현재 git am 충돌 처리가 진행 중입니다.

Branch : $currentBranch

먼저 충돌을 해결하세요.
  git add <해결한 파일>
  git am --continue

추가 충돌이 있으면 반복하고, git am이 완전히 끝난 뒤 03을 다시 실행하세요.
전체 취소는 git am --abort 입니다.
"@
    }

    $changes = @(& git status --porcelain)
    Assert-GitSuccess "git status 실패"

    if ($changes.Count -gt 0) {
        & git status --short
        throw "현재 Working Tree가 깨끗하지 않습니다. Commit 또는 Stash 후 실행하세요."
    }

    # v7.5: 사용자는 외부에서 반입한 ZIP 1개만 inbound에 복사하고 03을 누른다.
    # 프로젝트 하위 폴더를 만들 필요 없이 internalInboundRoot 어디에 두어도 재귀 검색한다.
    $zipPattern = "transfer-$ProjectName-$tagScope-$branchKey-*.zip"
    $zipCandidates = @(Get-ChildItem -LiteralPath $inboundRoot -Recurse -File -Filter $zipPattern -ErrorAction SilentlyContinue)
    if (![string]::IsNullOrWhiteSpace($PackageId)) {
        $zipCandidates = @($zipCandidates | Where-Object { $_.Name -like "*-$PackageId.zip" })
    }
    $transportZip = $zipCandidates | Sort-Object LastWriteTime, Name -Descending | Select-Object -First 1
    if (!$transportZip) {
        throw "반입 ZIP이 없습니다. ZIP 1개를 inbound 폴더에 복사하세요: $inboundRoot\$zipPattern"
    }

    $extractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitea-transfer-inbound-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    Expand-Archive -LiteralPath $transportZip.FullName -DestinationPath $extractRoot -Force
    $packageDir = $extractRoot

    $manifestFile = Join-Path $packageDir "manifest.txt"
    $manifest = Get-JsonFile $manifestFile
    Write-Host "반입 ZIP : $($transportZip.FullName)"
    Write-Host "자동 해제 : $packageDir"

    if ([string]$manifest.projectName -ne $ProjectName) {
        throw "Package 프로젝트가 다릅니다. Package=$($manifest.projectName) Current=$ProjectName"
    }
    if ($manifest.PSObject.Properties.Name -contains "tagScope") {
        if ([string]$manifest.tagScope -ne $tagScope) {
            throw "Package tagScope가 현재 설정과 다릅니다. Package=$($manifest.tagScope) Config=$tagScope"
        }
    }
    if ([string]$manifest.sourceBranch -ne $sourceBranch) {
        throw "Package sourceBranch가 현재 설정과 다릅니다. Package=$($manifest.sourceBranch) Config=$sourceBranch"
    }
    if ($manifest.PSObject.Properties.Name -contains "branchKey") {
        if ([string]$manifest.branchKey -ne $branchKey) {
            throw "Package branchKey가 현재 설정과 다릅니다. Package=$($manifest.branchKey) Config=$branchKey"
        }
    }


    Write-Host ""

    Test-PackageChecksums $packageDir
    Write-Host "SHA256 OK"

    if ([int]$manifest.selectedCommitCount -eq 0) {
        Write-Host "반입 대상 Commit이 0건입니다. 내부 Import/MR이 필요하지 않습니다."
        return
    }

    $patchDir = Join-Path $packageDir "patches"
    $patches = @(
        Get-ChildItem -LiteralPath $patchDir -Filter "*.txt" -File |
        Sort-Object Name
    )
    $patchFiles = @($patches | ForEach-Object { $_.FullName })
    Assert-PatchPackageShape $manifest $patches

    & git fetch $remote --prune
    Assert-GitSuccess "내부 GitLab fetch 실패"

    $importBranch = "$branchPrefix$ProjectName-$tagScope-$branchKey-$($manifest.freezeId)"
    $remoteMainRef = "refs/remotes/$remote/$mainBranch"

    & git show-ref --verify --quiet $remoteMainRef
    if ($LASTEXITCODE -ne 0) {
        throw "내부 기준 Branch를 찾을 수 없습니다: $remoteMainRef"
    }

    & git show-ref --verify --quiet "refs/remotes/$remote/$importBranch"
    $remoteImportExists = ($LASTEXITCODE -eq 0)
    if ($remoteImportExists) {
        Write-Host ""
        Write-Host "이미 GitLab에 반입 Branch가 존재합니다: $remote/$importBranch"
        Write-Host "중복 반입하지 않습니다. 기존 Branch의 MR 상태를 확인하세요."
        return
    }

    & git show-ref --verify --quiet "refs/heads/$importBranch"
    $localImportExists = ($LASTEXITCODE -eq 0)
    $baseCommit = ""

    if ($localImportExists) {
        $currentBranch = Get-CurrentBranch
        if ($currentBranch -ne $importBranch) {
            & git switch $importBranch
            Assert-GitSuccess "기존 반입 Branch 전환 실패: $importBranch"
        }

        if (Test-GitAmInProgress) {
            throw @"
현재 반입 Branch에서 git am 충돌 처리가 진행 중입니다.

Branch : $importBranch

1) IntelliJ 또는 직접 편집으로 충돌 해결
2) git add <해결한 파일>
3) git am --continue
4) 추가 충돌이 있으면 1~3 반복
5) git am이 모두 끝난 뒤 03을 다시 실행

전체 취소:
  git am --abort
  git switch $mainBranch
  git branch -D $importBranch
"@
        }

        $baseCommit = (& git merge-base HEAD $remoteMainRef).Trim()
        Assert-GitSuccess "기존 반입 Branch의 기준 Commit 조회 실패"
        if ([string]::IsNullOrWhiteSpace($baseCommit)) {
            throw "기존 반입 Branch와 내부 main의 공통 기준 Commit을 찾지 못했습니다."
        }

        Write-Host ""
        Write-Host "[RESUME] 기존 반입 Branch를 이어서 검증합니다."
        Write-Host "Branch : $importBranch"
        Write-Host "Base   : $baseCommit"
    }
    else {
        $baseCommit = (& git rev-parse $remoteMainRef).Trim()
        Assert-GitSuccess "내부 main 기준 Commit 조회 실패"

        & git switch -c $importBranch $remoteMainRef
        Assert-GitSuccess "반입 Branch 생성 실패"

        Write-Host ""
        Write-Host "Patch 적용 시작 : $($patchFiles.Count)개"
        Write-Host "3-way fallback   : ENABLED"

        & git am --3way @patchFiles
        if ($LASTEXITCODE -ne 0) {
            throw @"
Patch 적용 중 충돌이 발생했습니다.

현재 Branch: $importBranch

해결 순서:
  1) IntelliJ에서 충돌 파일을 현재 내부 소스를 기준으로 병합
  2) git add <해결한 파일>
  3) git am --continue
  4) 추가 충돌이 있으면 반복
  5) git am이 모두 끝난 뒤 03을 다시 실행

03 재실행 시 기존 import Branch를 인식하여 Patch를 다시 적용하지 않고
Commit 검증 -> source.zip 참고 비교 -> Push 단계부터 이어갑니다.

전체 취소:
  git am --abort
  git switch $mainBranch
  git branch -D $importBranch
"@
        }
    }

    Assert-ImportedCommits `
        $baseCommit `
        ([int]$manifest.selectedCommitCount) `
        @($manifest.allowedAuthorEmails) `
        $packageDir

    Compare-SourceReference $packageDir $manifest $ProjectRoot

    if ($autoPush) {
        & git push -u $remote $importBranch
        Assert-GitSuccess "GitLab Push 실패"
        Write-Host ""
        Write-Host "Push 완료"
        Write-Host "GitLab에서 MR 생성:"
        Write-Host "  Source : $importBranch"
        Write-Host "  Target : $mainBranch"
    }
    else {
        Write-Host "autoPush=false. 검토 후 직접 Push하세요."
    }
}
finally {
    Pop-Location
    if ($extractRoot -and (Test-Path -LiteralPath $extractRoot)) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
