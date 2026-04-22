@echo off
REM SIDECAR_RESTART.bat - wrapper so SIDECAR_RESTART.ps1 runs regardless
REM of execution policy. Kills any process on port 27116 and relaunches
REM lsb_admin_api so it picks up fresh config.py.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\SIDECAR_RESTART.ps1"
echo.
echo === SIDECAR_RESTART.bat finished. Log at SIDECAR_RESTART.log ===
pause
