@echo off
REM PUSH_AAR.bat - wrapper for PUSH_AAR.ps1. Commits AAR + smoke-test + cleanup
REM scripts and pushes to origin main.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\PUSH_AAR.ps1"
echo.
echo === PUSH_AAR.bat finished. Log at PUSH_AAR.log ===
pause
