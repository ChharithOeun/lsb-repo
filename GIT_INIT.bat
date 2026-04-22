@echo off
REM GIT_INIT.bat - wrapper so GIT_INIT.ps1 runs regardless of execution
REM policy. Inits git repo in this folder, reads the GitHub PAT from .env
REM (at F:\ffxi\deploy\.env, F:\ffxi\.env, or similar), creates the remote
REM repo if it doesn't exist, commits everything, and pushes main.
REM PAT is scrubbed from .git/config after push; log is PAT-redacted.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\GIT_INIT.ps1"
echo.
echo === GIT_INIT.bat finished. Log at GIT_INIT.log ===
pause
