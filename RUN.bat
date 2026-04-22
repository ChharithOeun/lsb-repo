@echo off
REM Wrapper so RUN.ps1 runs regardless of execution policy or Mark-of-the-Web.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\RUN.ps1"
echo.
echo === RUN.bat finished. Log written to RUN.log ===
pause
