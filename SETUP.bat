@echo off
REM Wrapper so SETUP.ps1 runs regardless of execution policy or Mark-of-the-Web.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\SETUP.ps1"
echo.
echo === SETUP.bat finished. Log written to SETUP.log ===
pause
