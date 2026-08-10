@echo off
title Anima
cd /d "%~dp0"

echo Zapuskayu Anima...

start "Anima Server" cmd /c "julia --project=. run_anima.jl"

REM Chekayemo poky server pidnimetsya na porti 8088 (maks ~60 sek)
set count=0
:WAIT
curl -s http://127.0.0.1:8088 >nul 2>&1
if not errorlevel 1 goto OPEN
set /a count+=1
if %count% GEQ 60 goto OPEN
timeout /t 1 /nobreak >nul
goto WAIT

:OPEN
start http://127.0.0.1:8088
echo Anima zapushchena. Tse vikno mozhna zakryty.
