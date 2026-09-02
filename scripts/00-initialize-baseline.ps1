param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet("test", "prod")]
    [string]$Mode = "test",

    [string]$BaselineId = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Assert-GitSuccess {
    param([string]$Message)
    if ($LASTEXITCODE -ne 0) { throw $Message }
}
function Get-ToolkitRoot { return (Split-Path $PSScriptRoot -Parent) }
function Get-JsonFile {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { throw "설정 파일이 없습니다: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
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
    # 같은 프로젝트/같은 브랜치여도 PartCode가 다르면 Freeze/Success/Claim이 완전히 독립적이다.
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

$ProjectRoot = (Resolve-Path $ProjectRoot).Path.TrimEnd("\")
$ProjectName = Split-Path $ProjectRoot -Leaf
$ToolkitRoot = Get-ToolkitRoot
$globalConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$projectConfig = Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")
$ext = Get-ExternalTransferSettings $projectConfig $globalConfig $Mode

if ([string]::IsNullOrWhiteSpace($BaselineId)) { $BaselineId = Get-Date -Format "yyyyMMddHHmm" }
if ($BaselineId -notmatch '^\d{12}$') { throw "BaselineId 형식은 yyyyMMddHHmm 12자리여야 합니다." }

$remote = $ext.Remote
$sourceBranch = $ext.SourceBranch
$tagScope = $ext.TagScope
$branchKey = $ext.BranchKey
$stateScope = $ext.StateScope
$partCodeResolved = $ext.PartCode
$successPrefix = $ext.SuccessPrefix

Push-Location $ProjectRoot
try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " 00 INITIALIZE BASELINE - ONE PROJECT"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Mode    : $tagScope"
    Write-Host "Part    : $partCodeResolved"
    Write-Host "Source  : $remote/$sourceBranch"
    Write-Host "State   : $ProjectName / $stateScope"
    Write-Host ""
    if ($tagScope -eq "test") {
        Write-Host "TEST 기준점입니다. PROD 기준점과 완전히 별도로 관리됩니다."
    } else {
        Write-Host "PROD 기준점입니다. 이 시점까지 내부 GitLab main에 수동 반입이 완료되어 있어야 합니다."
    }
    Write-Host ""

    & git fetch $remote --tags --prune
    Assert-GitSuccess "git fetch 실패"

    $existing = @(& git tag -l "$successPrefix*")
    Assert-GitSuccess "Success Tag 조회 실패"
    if ($existing.Count -gt 0) {
        throw "$ProjectName / $stateScope 에 이미 Success Tag가 존재합니다. 00은 프로젝트+Mode+Part+Branch별 최초 1회만 실행합니다."
    }

    $head = (& git rev-parse "refs/remotes/$remote/$sourceBranch").Trim()
    Assert-GitSuccess "$remote/$sourceBranch HEAD 조회 실패. 테스트 브랜치를 먼저 Push했는지 확인하세요."

    $tag = "$successPrefix$BaselineId"
    $operatorName = (& git config user.name).Trim()
    $operatorEmail = (& git config user.email).Trim()
    $msg = @"
Type=BASELINE
Project=$ProjectName
Mode=$tagScope
PartCode=$partCodeResolved
SourceBranch=$sourceBranch
BranchKey=$branchKey
StateScope=$stateScope
BaselineId=$BaselineId
Commit=$head
OperatorName=$operatorName
OperatorEmail=$operatorEmail
Machine=$env:COMPUTERNAME
CreatedAt=$((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"))
"@

    & git tag -a $tag $head -m $msg
    Assert-GitSuccess "Baseline Tag 생성 실패"
    & git push $remote "refs/tags/$tag"
    Assert-GitSuccess "Baseline Tag Push 실패"

    Write-Host ""
    Write-Host "BASELINE CREATED"
    Write-Host "Tag     : $tag"
    Write-Host "Commit  : $head"
    Write-Host "00은 $ProjectName / $stateScope 기준으로 완료되었습니다."
}
finally { Pop-Location }
