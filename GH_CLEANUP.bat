@echo off
REM GH_CLEANUP.bat - wrapper for GH_CLEANUP.ps1. Audits ChharithOeun's GitHub
REM repos for any malformed-name leftovers from the first failed GIT_INIT run
REM and deletes any empty, just-created ones.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GH_CLEANUP.ps1"
echo.
echo === GH_CLEANUP.bat finished. Log at GH_CLEANUP.log ===
pause
