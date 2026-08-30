@echo off
chcp 65001 >nul
setlocal
if "%~1"=="" (
  echo ProjectRoot argument is required.
  echo Example: "D:\workspace\my-react-app"  ^(or "$ProjectFileDir$"^)
  pause
  exit /b 1
)
set "ROOT=%~dp0..\.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\02-claim-export.ps1" -ProjectRoot "%~1" -Mode "prod"
if errorlevel 1 pause
endlocal
