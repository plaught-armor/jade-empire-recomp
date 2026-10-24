@echo off
rem Runs the Jade Empire port on Windows with the whole session logged to
rem logs\play-<timestamp>.log beside this file. F12 in game writes a mark line
rem and the frame as logs\play-<timestamp>\mark_NN_frame_NNNNN.ppm.
rem
rem GAME is the Jade Empire install folder: by default Steam's, or the GOG
rem offline installer's C:\GOG Games\Jade Empire when only that one exists
rem (GOG Galaxy and other folders: set GAME). EXE is the unpacked Steam
rem JadeEmpire.exe (docs/unpack.md; the shipped Steam exe is packed and does
rem not run) or the GOG one as shipped; by default it is a copy named
rem JadeEmpire.exe beside this file.
rem Either can also be set in the environment before running this.
rem
rem Online co-op: on the title menu the host picks Host Online Game; the
rem address to join goes in the window title and on the clipboard (the
rem router's UDP port 47000 is opened by UPnP when it allows, else forward it
rem by hand). The joiner picks Join Online Game and types or pastes it.
rem Both must run the same jade.exe, game exe, override and textures_hd
rem folders; the joiner plays on the host's Save, JadeEmpire.ini and
rem gameplay settings, fetched as needed, and its own are left alone.
rem By hand instead: the host adds  set JE_NET_HOST=7777  below, the joiner
rem set JE_NET_JOIN=<host address>:7777  and  set JE_P2_HERO=3  (0-6:
rem Blossom, Ming, Shen, Jen Zi, Ling, Prodigy, Tan). Player 2's hero is
rem also the Control panel setting Player 2's Hero; online the joiner's pick
rem counts.
setlocal
if not defined GAME if not exist "C:\Program Files (x86)\Steam\steamapps\common\Jade Empire\" if exist "C:\GOG Games\Jade Empire\" set "GAME=C:\GOG Games\Jade Empire"
if not defined GAME set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Jade Empire"
if not defined EXE set "EXE=%~dp0JadeEmpire.exe"
cd /d "%~dp0"
if not exist "%GAME%\" goto no_game
if not exist "%EXE%" goto no_exe

for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do set "STAMP=%%t"
if not defined STAMP set "STAMP=run"
set "JE_MARK_DIR=%~dp0logs\play-%STAMP%"
mkdir "%JE_MARK_DIR%" 2>nul
set "LOG=%~dp0logs\play-%STAMP%.log"
set JE_STICK_LOG=1
echo logging to %LOG%
jade.exe "%GAME%" "%EXE%" > "%LOG%" 2>&1
if errorlevel 1 goto failed
exit /b 0

:failed
echo jade.exe stopped with an error. The end of %LOG%:
powershell -NoProfile -Command "Get-Content -Tail 30 -LiteralPath $env:LOG"
pause
exit /b 1

:no_game
echo Jade Empire folder not found: %GAME%
echo Edit GAME at the top of %~nx0.
pause
exit /b 1

:no_exe
echo JadeEmpire.exe not found: %EXE%
echo Copy it beside jade.exe, or edit EXE at the top of %~nx0.
pause
exit /b 1
