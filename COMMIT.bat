@echo off
REM COMMIT.bat - wrapper around bin\publish.ps1 that stays open long enough
REM to read the output. Commits and pushes the current repo state.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\bin\publish.ps1" -RepoRoot "%~dp0." 2>&1 > COMMIT.log
echo.
echo === COMMIT.bat finished. Log at COMMIT.log ===
type COMMIT.log
echo.
pause
