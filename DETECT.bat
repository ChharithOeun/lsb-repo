@echo off
REM DETECT.bat - run the version-detection diagnostic probe and leave
REM the window open long enough to read. Writes chharbot\bin\detect_probe.log.
cd /d "%~dp0"
where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python chharbot\bin\detect_probe.py
) else (
    py -3 chharbot\bin\detect_probe.py
)
echo.
echo === DETECT.bat finished. Log at chharbot\bin\detect_probe.log ===
pause
