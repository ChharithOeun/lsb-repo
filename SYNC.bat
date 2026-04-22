@echo off
REM SYNC.bat - run lsb_version_sync to patch login.lua to match the
REM latest retail stamp the scanner finds. Uses `sync --force` because
REM the detected retail version (30250805_0 per patch2.cfg) is OLDER
REM than the placeholder 30260203_0 currently in login.lua, and the
REM monotonic guard normally blocks "downgrades". Dry-run first, then
REM actual sync.
cd /d "%~dp0"
where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (set "PY=python") else (set "PY=py -3")

echo === step 1: status (before) ===
%PY% -m lsb_version_sync status
echo.
echo === step 2: detect ===
%PY% -m lsb_version_sync detect
echo.
echo === step 3: dry-run sync --force ===
%PY% -m lsb_version_sync sync --dry-run --force
echo.
echo === step 4: applying sync --force --no-restart ===
%PY% -m lsb_version_sync sync --force --no-restart
echo.
echo === step 5: status (after) ===
%PY% -m lsb_version_sync status
echo.
echo === SYNC.bat finished ===
pause
