@echo off
REM Double-click launcher for run-all-fixes.ps1
REM Bypasses PowerShell execution policy for this single invocation.
setlocal
pushd "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-all-fixes.ps1"
set EXITCODE=%ERRORLEVEL%
popd
echo.
pause
exit /b %EXITCODE%
