@echo off
REM Standalone smoke test - just runs chharbot\bin\smoke-test.ps1.
REM Useful when deploy-full-stack has already set up the sidecar.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\chharbot\bin\smoke-test.ps1" 2>&1 > SMOKE.log
echo.
echo === SMOKE.bat finished. Log written to SMOKE.log ===
type SMOKE.log
echo.
pause
