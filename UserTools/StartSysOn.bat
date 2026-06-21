@echo off
setlocal
title SysON Launcher

REM Store the script directory so paths are always resolved relative to this file
set SCRIPT_DIR=%~dp0

REM docker-compose.yml lives at the syson repo root, one level up from this script
set COMPOSE_FILE=%SCRIPT_DIR%..\docker-compose.yml

echo ========================================
echo  SysON Launcher
echo ========================================

REM Step 0: Verify Docker is running before doing anything else
docker info >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: Docker does not appear to be running.
    echo Please start Docker Desktop and re-run this script.
    exit /b 1
)

REM Step 1: Clean up any leftover containers from previous run
call :CLEANUP

REM Step 2: Start SysON
echo Starting SysON server...
start "SysON-Server" cmd /c "docker compose -f "%COMPOSE_FILE%" up"

REM Step 3: Wait for ready
echo Waiting for SysON (max 120s)...
set MAX_WAIT=120
set WAITED=0

:WAIT_LOOP
    timeout /t 3 /nobreak >nul
    set /a WAITED+=3
    curl -s -f http://localhost:8080 >nul 2>&1
    if not errorlevel 1 goto SERVER_READY
    if %WAITED% GEQ %MAX_WAIT% goto TIMEOUT
    goto WAIT_LOOP

:SERVER_READY
echo SysON ready! (%WAITED%s)

REM Step 4: Open browser or launch client, wait for it to close
echo Opening SysON in browser...
REM --user-data-dir forces a fresh Edge instance (no hand-off to existing one), so /wait blocks until this window closes
start "SysON-Browser" /wait "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --user-data-dir="%TEMP%\SysONEdge" --app=http://localhost:8080


REM Step 5: Browser/client closed - clean up
echo Client closed. Cleaning up...
call :CLEANUP
goto END

:TIMEOUT
echo ERROR: SysON did not start within %MAX_WAIT%s.
call :CLEANUP
exit /b 1

REM ============================================================
:CLEANUP
echo.

REM Ask confirmation before stopping containers
choice /c YN /n /m "Stop SysON containers? [Y/N]: "
if errorlevel 2 (
    echo Stop skipped.
    goto :eof
)

echo Stopping SysON containers...
docker compose -f "%COMPOSE_FILE%" stop >nul 2>&1
for /f "tokens=*" %%i in ('docker ps -q --filter "name=syson" 2^>nul') do (
    echo Stopping container %%i...
    docker stop %%i >nul 2>&1
)
taskkill /FI "WINDOWTITLE eq SysON-Server" /T /F >nul 2>&1
echo Containers stopped.

REM Ask confirmation before removing containers
echo.
choice /c YN /n /m "Remove SysON containers? [Y/N]: "
if errorlevel 2 (
    echo Remove skipped.
    goto :eof
)

echo Removing SysON containers...
docker compose -f "%COMPOSE_FILE%" rm -f >nul 2>&1
for /f "tokens=*" %%i in ('docker ps -aq --filter "name=syson" 2^>nul') do (
    echo Removing container %%i...
    docker rm %%i >nul 2>&1
)
echo Containers removed.
goto :eof
REM ============================================================

:END
echo All done.
exit /b 0
