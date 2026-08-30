@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem Sparrow adapter entry point for gitea-transfer v7.2
rem
rem Arguments
rem   %1 = ScanDirectory   (temporary full project workspace)
rem   %2 = ResultDirectory (place Sparrow result/log files here)
rem   %3 = ProjectName
rem   %4 = Mode            (test/prod)
rem   %5 = SourceBranch
rem   %6 = FreezeId
rem
rem Required normalized exit codes
rem   0  = PASS
rem   10 = code findings -> REJECTED
rem   other = Sparrow/connection/config technical error
rem
rem CURRENT STATE:
rem   Sparrow environment is not configured yet.
rem   Keep config\<project>.json -> sparrow.enabled=false.
rem
rem When Sparrow CLI/Cloud connection is ready, replace ONLY the marked
rem VENDOR COMMAND section below so this wrapper returns the exit codes above.
rem After that, normal operation only needs sparrow.enabled true/false.
rem ============================================================

if not exist "%~2" mkdir "%~2"

> "%~2\adapter-not-configured.txt" echo Sparrow adapter is not configured.
>>"%~2\adapter-not-configured.txt" echo Project=%~3
>>"%~2\adapter-not-configured.txt" echo Mode=%~4
>>"%~2\adapter-not-configured.txt" echo Branch=%~5
>>"%~2\adapter-not-configured.txt" echo FreezeId=%~6
>>"%~2\adapter-not-configured.txt" echo ScanDirectory=%~1

rem ===== VENDOR COMMAND: configure once when Sparrow is installed =====
rem Example concept only - DO NOT uncomment until your Sparrow command is known:
rem   "C:\Path\To\SparrowCli.exe" ... "%~1" ... > "%~2\sparrow.log" 2>&1
rem   if ERRORLEVEL ... exit /b 10
rem   exit /b 0
rem ====================================================================

echo [SPARROW] Adapter is not configured. Keep sparrow.enabled=false for now.
exit /b 90
