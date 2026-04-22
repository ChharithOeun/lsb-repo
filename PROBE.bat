@echo off
REM Direct Python probe for chharbot. Skips the PowerShell wrapper entirely so
REM Python tracebacks survive verbatim. Log lands in chharbot\bin\probe.log.
cd /d "%~dp0"
where python >nul 2>&1
if errorlevel 1 (
    where py >nul 2>&1
    if errorlevel 1 (
        echo [FATAL] neither python nor py is on PATH.
        pause
        exit /b 2
    )
    py -3 chharbot\bin\probe.py
) else (
    python chharbot\bin\probe.py
)
echo.
echo === PROBE.bat finished. Log at chharbot\bin\probe.log ===
type chharbot\bin\probe.log
echo.
pause
