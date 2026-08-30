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

    $checksumFile = Join-Path $PackageDirectory "SHA256SUMS.txt"
    if (!(Test-Path -LiteralPath $checksumFile)) {
        throw "SHA256SUMS.txt가 없습니다."
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

Push-Location $ProjectRoot

try {
    $changes = @(& git status --porcelain)
    Assert-GitSuccess "git status 실패"

    if ($changes.Count -gt 0) {
        & git status --short
        throw "현재 Working Tree가 깨끗하지 않습니다. Commit 또는 Stash 후 실행하세요."
    }

    if ([string]::IsNullOrWhiteSpace($PackageId)) {
        $package = Get-ChildItem -LiteralPath $projectInbound -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") } |
            Sort-Object Name -Descending |
            Select-Object -First 1

        if (!$package) {
            throw "반입 Package가 없습니다: $projectInbound"
        }

        $packageDir = $package.FullName
    }
    else {
        $packageDir = Join-Path $projectInbound $PackageId
        if (!(Test-Path -LiteralPath $packageDir)) {
            throw "Package 경로가 없습니다: $packageDir"
        }
    }

    $manifestFile = Join-Path $packageDir "manifest.json"
    $manifest = Get-JsonFile $manifestFile

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

    if ($manifest.PSObject.Properties.Name -contains "sparrow") {
        $packageSparrowEnabled = [bool]$manifest.sparrow.enabled
        $packageSparrowStatus = [string]$manifest.sparrow.status

        if ($packageSparrowEnabled -and [int]$manifest.selectedCommitCount -gt 0 -and $packageSparrowStatus -ne "PASS") {
            throw "Sparrow가 활성화된 Package인데 PASS 상태가 아닙니다. Status=$packageSparrowStatus"
        }
    }
    else {
        $packageSparrowEnabled = $false
        $packageSparrowStatus = "LEGACY_PACKAGE"
    }

    Write-Host ""
    Write-Host "===================================================="
    Write-Host "INTERNAL IMPORT"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Mode    : $tagScope"
    Write-Host "Branch  : $sourceBranch"
    Write-Host "State   : $ProjectName / $stateScope"
    Write-Host "Freeze  : $($manifest.freezeId)"
    Write-Host "Commits : $($manifest.selectedCommitCount)"
    Write-Host "Sparrow : $packageSparrowStatus"
    Write-Host ""

    Test-PackageChecksums $packageDir
    Write-Host "SHA256 OK"

    if ([int]$manifest.selectedCommitCount -eq 0) {
        Write-Host "반입 대상 Commit이 0건입니다. 내부 Import/MR이 필요하지 않습니다."
        return
    }

    & git fetch $remote --prune
    Assert-GitSuccess "내부 GitLab fetch 실패"

    $importBranch = "$branchPrefix$ProjectName-$tagScope-$branchKey-$($manifest.freezeId)"

    & git show-ref --verify --quiet "refs/heads/$importBranch"
    if ($LASTEXITCODE -eq 0) {
        throw "로컬에 이미 반입 Branch가 있습니다: $importBranch"
    }

    & git show-ref --verify --quiet "refs/remotes/$remote/$importBranch"
    if ($LASTEXITCODE -eq 0) {
        throw "GitLab에 이미 반입 Branch가 있습니다: $remote/$importBranch"
    }

    & git switch -c $importBranch "refs/remotes/$remote/$mainBranch"
    Assert-GitSuccess "반입 Branch 생성 실패"

    $patchDir = Join-Path $packageDir "patches"
    $patches = @(
        Get-ChildItem -LiteralPath $patchDir -Filter "*.patch" -File |
        Sort-Object Name
    )

    $patchFiles = @($patches | ForEach-Object { $_.FullName })

    & git am @patchFiles
    if ($LASTEXITCODE -ne 0) {
        throw @"
Patch 적용 중 충돌이 발생했습니다.

현재 Branch: $importBranch

해결 후:
  git add <해결한 파일>
  git am --continue

전체 취소:
  git am --abort

충돌 원인을 확인한 뒤 반입담당자끼리 공유하세요.
"@
    }

    # source.zip과 선택 파일 결과 검증
    $verifyDir = Join-Path ([System.IO.Path]::GetTempPath()) ("transfer-verify-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null

    try {
        $sourceZip = Join-Path $packageDir "source.zip"
        Expand-Archive -LiteralPath $sourceZip -DestinationPath $verifyDir -Force

        $errors = New-Object System.Collections.Generic.List[string]

        foreach ($pathObj in @($manifest.sourceFiles)) {
            $rel = ([string]$pathObj).Replace("/", "\")
            $expectedFile = Join-Path $verifyDir $rel
            $actualFile = Join-Path $ProjectRoot $rel

            if (!(Test-Path -LiteralPath $expectedFile)) {
                $errors.Add("ZIP에 파일 없음: $rel")
                continue
            }

            if (!(Test-Path -LiteralPath $actualFile)) {
                $errors.Add("내부 소스에 파일 없음: $rel")
                continue
            }

            $expectedHash = (Get-FileHash -LiteralPath $expectedFile -Algorithm SHA256).Hash
            $actualHash = (Get-FileHash -LiteralPath $actualFile -Algorithm SHA256).Hash

            if ($expectedHash -ne $actualHash) {
                $errors.Add("내용 불일치: $rel")
            }
        }

        foreach ($pathObj in @($manifest.deletedPaths)) {
            $rel = ([string]$pathObj).Replace("/", "\")
            $actualFile = Join-Path $ProjectRoot $rel
            if (Test-Path -LiteralPath $actualFile) {
                $errors.Add("삭제되어야 하는 파일이 존재함: $rel")
            }
        }

        if ($errors.Count -gt 0) {
            $errors | ForEach-Object { Write-Host "  $_" }
            throw "source.zip 검증 실패. Push하지 않습니다."
        }

        Write-Host "SOURCE VERIFY OK"
    }
    finally {
        if (Test-Path -LiteralPath $verifyDir) {
            Remove-Item -LiteralPath $verifyDir -Recurse -Force
        }
    }

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
}
