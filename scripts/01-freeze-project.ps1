param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [ValidateSet("test", "prod")]
    [string]$Mode = "test",

    [string]$FreezeId = ""
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
function Assert-GitSuccess { param([string]$Message) if ($LASTEXITCODE -ne 0) { throw $Message } }
function Get-ToolkitRoot { return (Split-Path $PSScriptRoot -Parent) }
function Get-JsonFile {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { throw "설정 파일이 없습니다: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
function Get-TagId { param([string]$Tag,[string]$Prefix) if (!$Tag.StartsWith($Prefix)) { return "" }; return $Tag.Substring($Prefix.Length) }
function Get-LatestSuccessTag {
    param([string]$SuccessPrefix)
    $tags=@(& git tag -l "$SuccessPrefix*" --sort=-refname)
    Assert-GitSuccess "Success Tag 조회 실패"
    if ($tags.Count -eq 0) { return $null }
    return ([string]$tags[0]).Trim()
}
function Get-RemoteTagExists {
    param([string]$Remote,[string]$Tag)
    $lines=@(& git ls-remote --tags $Remote "refs/tags/$Tag")
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
    param([string]$Remote,[string]$Tag)
    & git fetch $Remote "+refs/tags/${Tag}:refs/tags/${Tag}" | Out-Null
    Assert-GitSuccess "Tag Fetch 실패: $Tag"
}
function Get-TagTarget { param([string]$Tag) $v=(& git rev-parse "$Tag^{}").Trim(); Assert-GitSuccess "Tag Commit 조회 실패: $Tag"; return $v }
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

$ProjectRoot=(Resolve-Path $ProjectRoot).Path.TrimEnd("\")
$ProjectName=Split-Path $ProjectRoot -Leaf
$ToolkitRoot=Get-ToolkitRoot
$globalConfig=Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$projectConfig=Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")
$ext=Get-ExternalTransferSettings $projectConfig $globalConfig $Mode

if ([string]::IsNullOrWhiteSpace($FreezeId)) { $FreezeId=Get-Date -Format "yyyyMMddHHmm" }
if ($FreezeId -notmatch '^\d{12}$') { throw "FreezeId 형식은 yyyyMMddHHmm 12자리여야 합니다." }

$remote=$ext.Remote; $sourceBranch=$ext.SourceBranch; $tagScope=$ext.TagScope; $branchKey=$ext.BranchKey; $stateScope=$ext.StateScope
$freezePrefix=$ext.FreezePrefix; $successPrefix=$ext.SuccessPrefix; $rejectedPrefix=$ext.RejectedPrefix

Push-Location $ProjectRoot
try {
    Write-Host ""
    Write-Host "===================================================="
    Write-Host " 01 FREEZE PROJECT - ONE PROJECT"
    Write-Host "===================================================="
    Write-Host "Project : $ProjectName"
    Write-Host "Mode    : $tagScope"
    Write-Host "Source  : $remote/$sourceBranch"
    Write-Host "State   : $ProjectName / $stateScope"
    Write-Host "Freeze  : $FreezeId"
    Write-Host ""

    & git fetch $remote --tags --prune
    Assert-GitSuccess "git fetch 실패"

    $latestSuccess=Get-LatestSuccessTag $successPrefix
    if (!$latestSuccess) { throw "$ProjectName / $stateScope Baseline/Success Tag가 없습니다. 이 브랜치에서 먼저 00을 실행하세요." }
    $successId=Get-TagId $latestSuccess $successPrefix

    $unfinished=@()
    $freezeTags=@(& git tag -l "$freezePrefix*" --sort=refname)
    Assert-GitSuccess "Freeze Tag 조회 실패"
    foreach ($ftObj in $freezeTags) {
        $ft=([string]$ftObj).Trim(); if ([string]::IsNullOrWhiteSpace($ft)) { continue }
        $fid=Get-TagId $ft $freezePrefix
        if ($fid -gt $successId) {
            $st="$successPrefix$fid"
            $rt="$rejectedPrefix$fid"

            & git show-ref --tags --verify --quiet "refs/tags/$st"
            $hasSuccess = ($LASTEXITCODE -eq 0)

            & git show-ref --tags --verify --quiet "refs/tags/$rt"
            $hasRejected = ($LASTEXITCODE -eq 0)

            # 완료된 Success 또는 Sparrow FAIL로 종결된 Rejected Freeze는
            # 새 Freeze 생성을 막지 않는다.
            if (!$hasSuccess -and !$hasRejected -and $fid -ne $FreezeId) {
                $unfinished += $ft
            }
        }
    }
    if ($unfinished.Count -gt 0) { throw "완료되지 않은 이전 Freeze가 있습니다: $($unfinished -join ', ')" }

    $head=(& git rev-parse "refs/remotes/$remote/$sourceBranch").Trim()
    Assert-GitSuccess "$remote/$sourceBranch HEAD 조회 실패"
    $tag="$freezePrefix$FreezeId"

    if (Get-RemoteTagExists $remote $tag) {
        Fetch-OneTag $remote $tag
        $existingTarget=Get-TagTarget $tag
        if ($existingTarget -ne $head) { throw "같은 FreezeId가 다른 Commit에 이미 사용되었습니다: $tag" }
        Write-Host "이미 같은 Freeze가 존재합니다: $tag -> $head"
        return
    }

    Remove-LocalTagIfExists $tag
    $operatorName=(& git config user.name).Trim()
    $operatorEmail=(& git config user.email).Trim()
    $msg=@"
Type=FREEZE
Project=$ProjectName
Mode=$tagScope
SourceBranch=$sourceBranch
BranchKey=$branchKey
StateScope=$stateScope
FreezeId=$FreezeId
Commit=$head
OperatorName=$operatorName
OperatorEmail=$operatorEmail
Machine=$env:COMPUTERNAME
CreatedAt=$((Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK"))
"@
    & git tag -a $tag $head -m $msg
    Assert-GitSuccess "Freeze Tag 생성 실패"
    & git push $remote "refs/tags/$tag"
    Assert-GitSuccess "Freeze Tag Push 실패"

    Write-Host ""
    Write-Host "FREEZE CREATED : $ProjectName / $stateScope"
    Write-Host "Tag    : $tag"
    Write-Host "Commit : $head"
    Write-Host "이번 반입은 이 Commit까지만 처리합니다. 바로 같은 담당자가 02를 실행하세요."
}
finally { Pop-Location }
