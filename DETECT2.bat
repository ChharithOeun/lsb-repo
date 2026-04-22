@echo off
REM DETECT2.bat - wide DLL walk: find and scan every FFXiMain.dll / polcore
REM dll / xiloader anywhere on the system and dump strict+loose version
REM pattern hits. Writes chharbot\bin\detect_probe2.log.
cd /d "%~dp0"
where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python chharbot\bin\detect_probe2.py
) else (
    py -3 chharbot\bin\detect_probe2.py
)
echo.
echo === DETECT2.bat finished. Log at chharbot\bin\detect_probe2.log ===
pause
