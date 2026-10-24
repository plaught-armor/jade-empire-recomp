@echo off
rem Builds the recompiler (tools\x86rec) as port\build\x86rec.exe on 64-bit
rem Windows, as build.sh does on Linux: capstone 5.0.7, built here from its
rem pinned source tarball (x86 only) into port\build\capstone together with
rem the flat-view shim capstone.c. Run it from an "x64 Native Tools Command
rem Prompt for VS" with odin on PATH. Arguments pass through to odin.
setlocal
cd /d "%~dp0..\.."
where cl >nul 2>nul || (echo cl.exe not found: run this from an x64 Native Tools Command Prompt. & exit /b 1)
where odin >nul 2>nul || (echo odin not found on PATH. & exit /b 1)
set CS=5.0.7
set OUT=port\build\capstone
if not exist %OUT%\capstone.lib (
	mkdir port\build\dl %OUT%\obj 2>nul
	curl -sSLf -o port\build\dl\capstone.tar.gz "https://github.com/capstone-engine/capstone/archive/refs/tags/%CS%.tar.gz" || exit /b 1
	certutil -hashfile port\build\dl\capstone.tar.gz SHA256 | findstr /i /x "6427a724726d161d1e05fb49fff8cd0064f67836c04ffca3c11d6d859e719caa" >nul || (echo capstone.tar.gz: checksum mismatch. & exit /b 1)
	if exist port\build\dl\capstone-%CS%\ rmdir /s /q port\build\dl\capstone-%CS%
	tar -xzf port\build\dl\capstone.tar.gz -C port\build\dl || exit /b 1
	for %%f in (cs Mapping MCInst MCInstrDesc MCRegisterInfo SStream utils) do call :cc "port\build\dl\capstone-%CS%\%%f.c" || exit /b 1
	for %%f in (port\build\dl\capstone-%CS%\arch\X86\*.c) do call :cc "%%f" || exit /b 1
	call :cc tools\x86rec\capstone.c || exit /b 1
	lib /nologo /out:%OUT%\capstone.lib %OUT%\obj\*.obj || exit /b 1
)
odin build tools\x86rec -out:port\build\x86rec.exe -o:speed %* || exit /b 1
exit /b 0

rem Static CRT (/MT) like Odin's.
:cc
cl /nologo /O2 /MT /w /Iport\build\dl\capstone-%CS%\include /DCAPSTONE_HAS_X86 /DCAPSTONE_USE_SYS_DYN_MEM /c "%~1" /Fo%OUT%\obj\%~n1.obj
exit /b %errorlevel%
