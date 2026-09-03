@echo off
chcp 65001 >nul
setlocal EnableExtensions
if "%~1"=="" (
  echo [ERROR] ProjectRoot argument is required.
  echo Example: "D:\workspace\s2b_buy"  ^(or "$ProjectFileDir$"^)
  pause
  exit /b 1
)
set "ROOT=%~dp0.."
set "GLOBAL=%ROOT%\config\global.json"
if not exist "%GLOBAL%" (
  echo [ERROR] global.json not found: %GLOBAL%
  pause
  exit /b 1
)
for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; $g=Get-Content -Raw -LiteralPath '%GLOBAL%' | ConvertFrom-Json; $p=[string]$g.profile; if($p -notin @('test','prod')){throw 'global.json profile must be test or prod'}; $p"`) do set "PROFILE=%%P"
if not defined PROFILE (
  echo [ERROR] Could not read profile from global.json.
  pause
  exit /b 1
)
echo [PROFILE] %PROFILE%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\00-initialize-baseline.ps1" -ProjectRoot "%~1" -Mode "%PROFILE%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
endlocal & exit /b %RC%
