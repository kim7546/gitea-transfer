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


function Get-PartSettings {
    param([object]$ProjectConfig)

    $code = [string]$ProjectConfig.partCode
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "프로젝트 config의 partCode가 비어 있습니다. 이 PC/Toolkit에서 사용하는 내 파트 코드 1개만 설정하세요."
    }
    $code = $code.Trim()
    if ($code -notmatch '^[A-Za-z0-9._-]+$') {
        throw "partCode는 영문/숫자/점/밑줄/하이픈만 사용할 수 있습니다: $code"
    }

    $allowed = @($ProjectConfig.allowedAuthorEmails)
    if ($allowed.Count -eq 0) {
        throw "프로젝트 config의 allowedAuthorEmails가 비어 있습니다. 내 파트 반입 대상 사용자 Email을 등록하세요."
    }

    return [pscustomobject]@{
        Code = $code
        AllowedAuthorEmails = $allowed
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

    # v7.6.1: 상태 키는 Project + Mode + config.partCode + SourceBranch 이다.
    $part = Get-PartSettings $ProjectConfig
    $partCodeResolved = [string]$part.Code
    $tagScope = $modeKey
    $branchKey = Get-BranchKey $sourceBranch
    $stateScope = "$modeKey/$partCodeResolved/$sourceBranch"

    return [pscustomobject]@{
        Remote = $remote
        SourceBranch = $sourceBranch
        BranchKey = $branchKey
        PartCode = $partCodeResolved
        AllowedAuthorEmails = @($part.AllowedAuthorEmails)
        TagScope = $tagScope
        StateScope = $stateScope
        FreezePrefix = "$([string]$GlobalConfig.tagPrefixes.freeze)$modeKey/$partCodeResolved/$sourceBranch/"
        SuccessPrefix = "$([string]$GlobalConfig.tagPrefixes.success)$modeKey/$partCodeResolved/$sourceBranch/"
        ClaimPrefix = "$([string]$GlobalConfig.tagPrefixes.claim)$modeKey/$partCodeResolved/$sourceBranch/"
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


$ProjectRoot = (Resolve-Path $ProjectRoot).Path.TrimEnd("\")
$ProjectName = Split-Path $ProjectRoot -Leaf
$ToolkitRoot = Get-ToolkitRoot

$globalConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$projectConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")

$ext = Get-ExternalTransferSettings $projectConfig $globalConfig $Mode
$freezePrefix = $ext.FreezePrefix
$successPrefix = $ext.SuccessPrefix
$claimPrefix = $ext.ClaimPrefix
$remote = $ext.Remote
$stateScope = $ext.StateScope

Push-Location $ProjectRoot
try {
    & git fetch $remote --tags --prune
    Assert-GitSuccess "git fetch 실패"

    $freezeTag = Get-ActiveFreezeTag $freezePrefix $successPrefix
    $freezeId = Get-TagId $freezeTag $freezePrefix
    $claimTag = "$claimPrefix$freezeId"

    Write-Host ""
    Write-Host "[05 CANCEL TRANSFER]"
    Write-Host "Project : $ProjectName"
    Write-Host "Scope   : $stateScope"
    Write-Host "Freeze  : $freezeTag"
    Write-Host "Claim   : $claimTag"
    Write-Host ""

    # Claim은 존재할 때만 삭제한다.
    if (Get-RemoteTagExists $remote $claimTag) {
        & git push $remote ":refs/tags/$claimTag"
        Assert-GitSuccess "Remote Claim Tag 삭제 실패"
        Remove-LocalTagIfExists $claimTag
        Write-Host "Claim  삭제 완료"
    } else {
        Write-Host "Claim  없음 - 건너뜀"
        Remove-LocalTagIfExists $claimTag
    }

    # 현재 회차 Freeze를 삭제하여 외부 수정 Commit 후 01부터 새 Freeze를 만들 수 있게 한다.
    if (Get-RemoteTagExists $remote $freezeTag) {
        & git push $remote ":refs/tags/$freezeTag"
        Assert-GitSuccess "Remote Freeze Tag 삭제 실패"
    }
    Remove-LocalTagIfExists $freezeTag
    Write-Host "Freeze 삭제 완료"
    Write-Host "Success Tag는 변경하지 않았습니다."
    Write-Host ""
    Write-Host "CANCELLED : $ProjectName / $stateScope / $freezeId"
    Write-Host "외부 소스를 수정/Commit한 뒤 01 Freeze부터 다시 실행하세요."
    Write-Host "기존 실패 ZIP은 외부 dist와 내부 inbound에서 삭제하세요."
}
finally {
    Pop-Location
}
