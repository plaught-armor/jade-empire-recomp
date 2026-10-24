@echo off
rem Builds the Odin tools into port\build on 64-bit Windows, as build.sh does
rem on Linux: the recompiler (x86rec) and the analysis tools. The ones that
rem disassemble use capstone 5.0.7, built here from its pinned source tarball
rem (x86 only) into port\build\capstone, plus the flat-view shim
rem tools\capstone\capstone.c, rebuilt every run. Run it from an "x64 Native
rem Tools Command Prompt for VS" with odin on PATH.
rem Usage: tools\build.bat [tool...]   (all when none given)
setlocal
cd /d "%~dp0.."
where cl >nul 2>nul || (echo cl.exe not found: run this from an x64 Native Tools Command Prompt. & exit /b 1)
where odin >nul 2>nul || (echo odin not found on PATH. & exit /b 1)
set CS=5.0.7
set OUT=port\build\capstone
set SRC=port\build\dl\capstone-%CS%
if not exist %OUT%\capstone.lib goto fetch
if not exist %SRC%\include\ goto fetch
goto shim
:fetch
mkdir port\build\dl %OUT%\obj 2>nul
curl -sSLf -o port\build\dl\capstone.tar.gz "https://github.com/capstone-engine/capstone/archive/refs/tags/%CS%.tar.gz" || exit /b 1
certutil -hashfile port\build\dl\capstone.tar.gz SHA256 | findstr /i /x "6427a724726d161d1e05fb49fff8cd0064f67836c04ffca3c11d6d859e719caa" >nul || (echo capstone.tar.gz: checksum mismatch. & exit /b 1)
if exist %SRC%\ rmdir /s /q %SRC%
tar -xzf port\build\dl\capstone.tar.gz -C port\build\dl || exit /b 1
for %%f in (cs Mapping MCInst MCInstrDesc MCRegisterInfo SStream utils) do call :cc "%SRC%\%%f.c" || exit /b 1
for %%f in (%SRC%\arch\X86\*.c) do call :cc "%%f" || exit /b 1
:shim
call :cc tools\capstone\capstone.c || exit /b 1
if exist %OUT%\capstone.lib del %OUT%\capstone.lib
lib /nologo /out:%OUT%\capstone.lib %OUT%\obj\*.obj || exit /b 1
set TOOLS=%*
if "%TOOLS%"=="" set TOOLS=x86rec inventory srcmap devcalls funcnames cmdtable untpf
for %%t in (%TOOLS%) do odin build tools\%%t -out:port\build\%%t.exe -o:speed || exit /b 1
exit /b 0

rem Static CRT (/MT) like Odin's.
:cc
cl /nologo /O2 /MT /w /I%SRC%\include /DCAPSTONE_HAS_X86 /DCAPSTONE_USE_SYS_DYN_MEM /c "%~1" /Fo%OUT%\obj\%~n1.obj
exit /b %errorlevel%
