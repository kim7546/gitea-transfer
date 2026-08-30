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
$successPrefix = $ext.SuccessPrefix

Push-Location $ProjectRoot
try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " 00 INITIALIZE BASELINE - ONE PROJECT"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Mode    : $tagScope"
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
        throw "$ProjectName / $stateScope 에 이미 Success Tag가 존재합니다. 00은 프로젝트+Mode+Branch별 최초 1회만 실행합니다."
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
