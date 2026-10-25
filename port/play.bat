@echo off
rem Runs the Jade Empire port on Windows with the whole session logged to
rem logs\play-<timestamp>.log beside this file. F12 in game writes a mark line
rem and the frame as logs\play-<timestamp>\mark_NN_frame_NNNNN.ppm.
rem
rem install.bat puts this beside jade.exe in the game folder. GAME is the
rem Jade Empire game folder: by default this file's own folder, else Steam's,
rem else the GOG offline installer's C:\GOG Games\Jade Empire. jade.exe picks
rem the exe there: JadeEmpire.unpacked.exe (Steam, unpacked by install.bat)
rem or JadeEmpire.exe (GOG). EXE names another one. Either can also be set in
rem the environment before running this.
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
if not defined GAME if exist "%~dp0chitin.key" set "GAME=%~dp0."
if not defined GAME if not exist "C:\Program Files (x86)\Steam\steamapps\common\Jade Empire\" if exist "C:\GOG Games\Jade Empire\" set "GAME=C:\GOG Games\Jade Empire"
if not defined GAME set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Jade Empire"
cd /d "%~dp0"
if not exist "%GAME%\" goto no_game

for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do set "STAMP=%%t"
if not defined STAMP set "STAMP=run"
set "JE_MARK_DIR=%~dp0logs\play-%STAMP%"
mkdir "%JE_MARK_DIR%" 2>nul
set "LOG=%~dp0logs\play-%STAMP%.log"
set JE_STICK_LOG=1
echo logging to %LOG%
if defined EXE (jade.exe "%GAME%" "%EXE%" > "%LOG%" 2>&1) else (jade.exe "%GAME%" > "%LOG%" 2>&1)
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
