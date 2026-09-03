param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [ValidateSet("test", "prod")][string]$Mode = "test"
)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Get-ToolkitRoot { return (Split-Path $PSScriptRoot -Parent) }
function Get-JsonFile([string]$Path) {
    if (!(Test-Path -LiteralPath $Path)) { throw "설정 파일이 없습니다: $Path" }
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
}
function Assert-GitSuccess([string]$Message) { if ($LASTEXITCODE -ne 0) { throw $Message } }
function Get-BranchKey([string]$BranchName) {
    $key=$BranchName.Trim().Replace("\\","__").Replace("/","__")
    $key=$key -replace '[<>:"|?*]','_'; $key=$key -replace '\s+','_'; return $key
}

$ProjectRoot=(Resolve-Path $ProjectRoot).Path.TrimEnd("\\")
$ProjectName=Split-Path $ProjectRoot -Leaf
$ToolkitRoot=Get-ToolkitRoot
$global=Get-JsonFile (Join-Path $ToolkitRoot "config\global.json")
$cfg=Get-JsonFile (Join-Path $ToolkitRoot "config\$ProjectName.json")
$sp=$cfg.internal.sparrow
if (!$sp -or ![bool]$sp.enabled) { throw "internal.sparrow.enabled=true 설정이 필요합니다." }

$modeKey=$Mode.ToLowerInvariant()
$profileProp=$cfg.external.profiles.PSObject.Properties[$modeKey]
if(!$profileProp){ throw "external.profiles.$modeKey 설정이 없습니다." }
$sourceBranch=[string]$profileProp.Value.sourceBranch
$partCode=[string]$cfg.partCode
$branchKey=Get-BranchKey $sourceBranch
$prefix=[string]$cfg.internal.importBranchPrefix
$expectedPrefix="$prefix$ProjectName-$modeKey-$partCode-$branchKey-"
$remote=[string]$cfg.internal.remote
$main=[string]$cfg.internal.mainBranch

Push-Location $ProjectRoot
try {
    $changes=@(& git status --porcelain); Assert-GitSuccess "git status 실패"
    if ($changes.Count -gt 0) { & git status --short; throw "Working Tree가 깨끗하지 않습니다. Commit/Stash 후 실행하세요." }
    $branch=(& git branch --show-current).Trim(); Assert-GitSuccess "현재 Branch 조회 실패"
    if (!$branch.StartsWith($expectedPrefix)) { throw "현재 Branch가 이번 반입 import Branch가 아닙니다. 현재=$branch / 예상 prefix=$expectedPrefix" }
    & git fetch $remote --prune; Assert-GitSuccess "GitLab fetch 실패"
    $baseRef="refs/remotes/$remote/$main"
    & git show-ref --verify --quiet $baseRef
    if ($LASTEXITCODE -ne 0) { throw "기준 Branch를 찾을 수 없습니다: $baseRef" }

    $work=Join-Path $ToolkitRoot "work\sparrow\$ProjectName\$modeKey"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $targetList=Join-Path $work "target_list.txt"
    $logFile=Join-Path $work ("sparrow-"+(Get-Date -Format 'yyyyMMddHHmmss')+".log")

    # origin/main 대비 이번 local import branch에서 변경된 파일만 추출한다.
    $files=@(& git diff --name-only --diff-filter=ACMRT $baseRef HEAD); Assert-GitSuccess "변경 파일 목록 생성 실패"
    $targets=New-Object System.Collections.Generic.List[string]
    foreach($fObj in $files){
        $f=([string]$fObj).Trim(); if([string]::IsNullOrWhiteSpace($f)){continue}
        $full=Join-Path $ProjectRoot ($f.Replace('/', '\\'))
        if(Test-Path -LiteralPath $full -PathType Leaf){ $targets.Add((Resolve-Path $full).Path) }
    }
    if($targets.Count -eq 0){ throw "Sparrow 분석 대상 변경 파일이 없습니다." }
    $targets | Set-Content -LiteralPath $targetList -Encoding UTF8

    $cli=[string]$sp.cliPath; if(!(Test-Path -LiteralPath $cli)){ throw "Sparrow CLI를 찾을 수 없습니다: $cli" }
    $args=@('create','analysis','-k',[string]$sp.projectKey,'-s',[string]$sp.server,'-u',[string]$sp.user,
            '--type',[string]$sp.analysisType,'--profile',[string]$sp.profile,
            '--target-type','file','--path-list',$targetList,'--base-path',$ProjectRoot)
    $pw=[string]$sp.passwordFile
    if(![string]::IsNullOrWhiteSpace($pw)){
        if(!(Test-Path -LiteralPath $pw)){ throw "Sparrow passwordFile을 찾을 수 없습니다: $pw" }
        $args += @('-p',$pw)
    }

    Write-Host "[03-1 SPARROW CLI]"
    Write-Host "Branch     : $branch"
    Write-Host "Base       : $remote/$main"
    Write-Host "TargetCount: $($targets.Count)"
    Write-Host "TargetList : $targetList"
    Write-Host "Log        : $logFile"
    Write-Host ""
    & $cli @args 2>&1 | Tee-Object -FilePath $logFile
    if($LASTEXITCODE -ne 0){ throw "Sparrow CLI 실행 실패 (exit=$LASTEXITCODE). 로그를 확인하세요: $logFile" }
    Write-Host ""
    Write-Host "Sparrow CLI 명령이 정상 종료되었습니다."
    Write-Host "주의: CLI 정상 종료를 취약점 PASS로 간주하지 않습니다."
    Write-Host "Sparrow Enterprise GUI에서 해당 분석 결과를 확인하고 필요하면 Excel 보고서를 내려받으세요."
    Write-Host "검사 PASS 후 IntelliJ에서 현재 import Branch를 직접 Push하세요."
}
finally { Pop-Location }
