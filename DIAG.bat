@echo off
REM Wrapper so DIAG.ps1 runs regardless of execution policy or Mark-of-the-Web.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\DIAG.ps1"
echo.
echo === DIAG.bat finished. Log written to DIAG.log ===
pause
