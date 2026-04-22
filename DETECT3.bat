@echo off
REM DETECT3.bat - hunt CLIENT_VER in config/text files (not DLLs).
cd /d "%~dp0"
where python >nul 2>nul
if %ERRORLEVEL% EQU 0 (
    python chharbot\bin\detect_probe3.py
) else (
    py -3 chharbot\bin\detect_probe3.py
)
echo.
echo === DETECT3.bat finished. Log at chharbot\bin\detect_probe3.log ===
pause
