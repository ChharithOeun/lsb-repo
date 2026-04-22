@echo off
rem ====================================================================
rem Launch-Altana.bat - one-click launcher for the LSB Altana profile.
rem
rem Runs xiloader 2.1.1 to authenticate against the local LSB server,
rem then launches Ashita with the Altana profile so the spawned pol.exe
rem inherits the live session.
rem
rem This is the wrapper-script "Option 2" alternative to the
rem xiloader_fixed Ashita addon. Use either, not both.
rem ====================================================================

setlocal

set "XILOADER=F:\ffxi\Ashita\ffxi-bootmod\pol.exe"
set "ASHITA=F:\ffxi\Ashita\ashita.exe"
set "PROFILE=Private Server"
set "SERVER=127.0.0.1"
set "USERNAME=GUESTCL1"
set "PASSWORD=guestpass"
set "LOG=F:\ffxi\deploy\altana-launch.log"

if not exist "%XILOADER%" (
    echo ERROR: xiloader not found at %XILOADER%
    echo Run examples\install-xiloader-2.1.1.ps1 first.
    pause
    exit /b 1
)
if not exist "%ASHITA%" (
    echo ERROR: ashita.exe not found at %ASHITA%
    pause
    exit /b 1
)

echo === Altana launcher %DATE% %TIME% === > "%LOG%"
echo xiloader: %XILOADER% >> "%LOG%"
echo ashita  : %ASHITA% >> "%LOG%"
echo profile : %PROFILE% >> "%LOG%"
echo server  : %SERVER% >> "%LOG%"

rem Kick off xiloader with --hairpin so the LSB-returned address gets
rem rewritten to 127.0.0.1 for same-box runs. --hide keeps the console
rem suppressed; comment it out if you want to watch the handshake.
start "" "%XILOADER%" --server %SERVER% --user %USERNAME% --password %PASSWORD% --hairpin --hide

rem Give xiloader a tick to spawn the retail pol.exe before Ashita
rem reaches the inject step.
timeout /t 1 /nobreak >nul

rem Launch Ashita against the chosen profile. Ashita's boot_file should
rem be the retail pol.exe (NOT xiloader) when using this wrapper.
"%ASHITA%" --boot "%PROFILE%"

echo done %DATE% %TIME% >> "%LOG%"
endlocal
