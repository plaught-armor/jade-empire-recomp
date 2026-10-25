@echo off
rem Builds the port from your own copy of Jade Empire and puts it in the game
rem folder, beside JadeEmpire.exe, as install.sh does on Linux. Afterwards,
rem run play.bat in that folder to play.
rem
rem Usage: install.bat [game folder]
rem Without a folder it looks in Steam's usual folder, then in
rem C:\GOG Games\Jade Empire. Double-clicking it works too.
rem
rem Needs Odin on PATH and Visual Studio or its Build Tools with "Desktop
rem development with C++"; it finds Visual Studio by itself. The Steam
rem JadeEmpire.exe is packed (docs/unpack.md): the first run unpacks it into
rem JadeEmpire.unpacked.exe beside it, which also needs Python, with pefile and
rem unicorn installed into port\build\venv. The GOG exe is used as it is.
setlocal
cd /d "%~dp0"
set "REPO=%CD%"
set STEAM_PACKED=0d25f18c028a7dffff9dd110b7be677f7e9b63e1cad86c1eb8e4e8e189c54fe5
set STEAM_UNPACKED=53445f0e2c33dd9f7c862999fbf9d834d6c4381cc573580cdba6fa0d2e1bcafe
set GOG=38224cc99f054f04f83190a369b82b2bc3ca65de114d780909a8ae2d09dc03c1

rem The game folder.
set "GAME=%~1"
if not defined GAME if exist "C:\Program Files (x86)\Steam\steamapps\common\Jade Empire\chitin.key" set "GAME=C:\Program Files (x86)\Steam\steamapps\common\Jade Empire"
if not defined GAME if exist "C:\GOG Games\Jade Empire\chitin.key" set "GAME=C:\GOG Games\Jade Empire"
if not defined GAME goto no_game
if not exist "%GAME%\chitin.key" goto bad_game
for %%g in ("%GAME%") do set "GAME=%%~fg"
echo Game folder: %GAME%

rem The programs the build needs.
where odin >nul 2>nul || goto no_odin
where cl >nul 2>nul && goto have_cl
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto no_vs
set VS=
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VS=%%i"
if not defined VS goto no_vs
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || goto no_vs
where cl >nul 2>nul || goto no_vs
:have_cl

rem Each step's output goes to the log, which is shown when a step fails.
set "LOG=%REPO%\port\build\install.log"
mkdir port\build 2>nul
type nul > "%LOG%"

rem The exe to build from.
set "EXE=%GAME%\JadeEmpire.unpacked.exe"
call :sha "%EXE%" %STEAM_UNPACKED% && (echo Found the unpacked Steam exe.& goto build)
set "EXE=%GAME%\JadeEmpire.exe"
if not exist "%EXE%" goto no_exe
call :sha "%EXE%" %GOG% && (echo Found the GOG exe.& goto build)
call :sha "%EXE%" %STEAM_PACKED% || goto bad_exe
echo Found the Steam exe. It is packed, so it is unpacked into JadeEmpire.unpacked.exe beside it.
set "VENV=port\build\venv"
"%VENV%\Scripts\python.exe" -c "import pefile, unicorn" >nul 2>nul && goto unpack
set PY=
py -3 -c "import venv" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "import venv" >nul 2>nul && set "PY=python"
if not defined PY goto no_python
if exist "%VENV%\" rmdir /s /q "%VENV%"
%PY% -m venv "%VENV%" >>"%LOG%" 2>&1 || goto failed
echo Installing pefile and unicorn for Python into %VENV%...
"%VENV%\Scripts\python.exe" -m pip install --quiet --disable-pip-version-check pefile unicorn >>"%LOG%" 2>&1 || goto failed
:unpack
echo Unpacking...
"%VENV%\Scripts\python.exe" tools\unpack_pec2.py "%GAME%\JadeEmpire.exe" "%GAME%\JadeEmpire.unpacked.exe" >>"%LOG%" 2>&1 || goto failed
set "EXE=%GAME%\JadeEmpire.unpacked.exe"
call :sha "%EXE%" %STEAM_UNPACKED% || goto bad_unpack

:build
echo Building the recompiler (the first time takes a few minutes)...
call tools\build.bat x86rec >>"%LOG%" 2>&1 || goto failed
echo Translating the game's code (about 10 seconds)...
port\build\x86rec.exe "%EXE%" re\ghidra_funcs.txt port\src\rec >>"%LOG%" 2>&1 || goto failed
echo Building the game (a few minutes; the first time also downloads SDL3 and FFmpeg)...
call port\build.bat >>"%LOG%" 2>&1 || goto failed
cd /d "%REPO%"
copy /y port\build\win\jade.exe "%GAME%\" >nul || goto failed
copy /y port\build\win\*.dll "%GAME%\" >nul || goto failed
copy /y port\build\win\LICENSE-*.txt "%GAME%\" >nul || goto failed
copy /y port\build\win\play.bat "%GAME%\" >nul || goto failed
echo.
echo Done. To play, run play.bat in %GAME%
pause
exit /b 0

rem Exit code 0 when file %1 has sha256 %2.
:sha
if not exist "%~1" exit /b 1
certutil -hashfile "%~1" SHA256 | findstr /i /x "%~2" >nul
exit /b %errorlevel%

:failed
cd /d "%REPO%"
echo.
echo That step failed. The end of %LOG%:
powershell -NoProfile -Command "Get-Content -Tail 20 -LiteralPath $env:LOG"
goto stop

:no_game
echo.
echo Jade Empire was not found in Steam's usual folder or in C:\GOG Games\Jade Empire.
echo Run this again from a command prompt with your game folder, for example:
echo   install.bat "D:\Games\Jade Empire"
goto stop

:bad_game
echo.
echo %GAME% is not a Jade Empire game folder (it has no chitin.key).
goto stop

:no_odin
echo.
echo Odin was not found. Install it and add its folder to PATH (README.md, "What you need").
goto stop

:no_vs
echo.
echo Visual Studio's C++ compiler was not found. Install Visual Studio or its Build Tools,
echo with "Desktop development with C++" selected.
goto stop

:no_exe
echo.
echo %GAME% has no JadeEmpire.exe.
goto stop

:bad_exe
echo.
echo %EXE% is not a version this port supports.
echo It works with Jade Empire: Special Edition from Steam or GOG only.
goto stop

:no_python
echo.
echo Python 3 is needed to unpack the Steam exe. Install it from python.org, then run this again.
goto stop

:bad_unpack
echo.
echo Unpacking gave an unexpected result. Please report this.
goto stop

:stop
pause
exit /b 1
