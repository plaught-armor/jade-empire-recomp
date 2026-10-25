@echo off
rem Builds the Odin tools into port\build on 64-bit Windows, as build.sh does
rem on Linux: the recompiler (x86rec), the analysis tools and the game data
rem tools. Needs nothing installed: the pinned Odin release comes from
rem tools\odin.bat, and the ones that disassemble link the prebuilt
rem port\winlib\lib\capstone.lib (capstone 5.0.7 plus tools\capstone\capstone.c,
rem port\winlib\build.sh).
rem Usage: tools\build.bat [tool...]   (all when none given)
setlocal
cd /d "%~dp0.."
call tools\odin.bat || exit /b 1
set TOOLS=%*
if "%TOOLS%"=="" set TOOLS=x86rec inventory srcmap devcalls funcnames cmdtable untpf rim twoda ncs jectl dump_tex jeplay
for %%t in (%TOOLS%) do "%ODIN%" build tools\%%t -out:port\build\%%t.exe -o:speed %ODIN_LINK% || exit /b 1
exit /b 0
