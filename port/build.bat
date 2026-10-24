@echo off
rem Builds the port natively on 64-bit Windows: build\win\jade.exe plus the
rem DLLs it needs beside it (SDL3, FFmpeg) and play.bat. Run it from an
rem "x64 Native Tools Command Prompt for VS" (Visual Studio or its Build
rem Tools, with the C++ workload) with odin and python on PATH; curl and tar
rem come with Windows 10 and later. Generate src\rec first (README.md).
rem
rem The code targets x86-64-v3 (AVX2) unless JE_ARCH names another
rem -microarch, as in build_windows.sh, and a build from the same commit and
rem Odin version gets the same build ID as that cross build, so the two play
rem online together (build_id.py, docs/hle.md §11). JE_OPT=none builds
rem unoptimized; other arguments pass through to odin.
setlocal
cd /d "%~dp0"
where cl >nul 2>nul || (echo cl.exe not found: run this from an x64 Native Tools Command Prompt. & exit /b 1)
where odin >nul 2>nul || (echo odin not found on PATH. & exit /b 1)
where python >nul 2>nul || (echo python not found on PATH. & exit /b 1)
if not exist src\rec\ (echo src\rec is missing: generate it with tools\x86rec.py first ^(README.md^). & exit /b 1)
if not defined JE_OPT set JE_OPT=speed
if not defined JE_ARCH set JE_ARCH=x86-64-v3
if not defined JE_GL_DEBUG set JE_GL_DEBUG=false
mkdir build\win build\dl 2>nul

rem FFmpeg 9.0 shared LGPL build (import libraries, headers, DLLs).
set FFMPEG=ffmpeg-n9.0-latest-win64-lgpl-shared-9.0
if not exist build\ffmpeg-win\ (
	curl -sSLf -o build\dl\ffmpeg.zip "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/%FFMPEG%.zip" || exit /b 1
	tar -xf build\dl\ffmpeg.zip -C build\dl || exit /b 1
	mkdir build\ffmpeg-win
	xcopy /e /i /q "build\dl\%FFMPEG%\bin" build\ffmpeg-win\bin >nul || exit /b 1
	xcopy /e /i /q "build\dl\%FFMPEG%\lib" build\ffmpeg-win\lib >nul || exit /b 1
	xcopy /e /i /q "build\dl\%FFMPEG%\include" build\ffmpeg-win\include >nul || exit /b 1
	copy /y "build\dl\%FFMPEG%\LICENSE.txt" build\ffmpeg-win\ >nul || exit /b 1
)

rem SDL3 at the version Odin's vendor:sdl3 binds (the one build_windows.sh
rem uses). Odin's own copies may be git-lfs pointers, so the build uses a
rem shadow ODIN_ROOT whose vendor\sdl3 holds the real files; everything else
rem is a junction to the installed Odin. Junctions are only ever created
rem here, never removed: deleting one recursively could reach into Odin.
set SDL=3.4.2
if not exist build\sdl3-win\ (
	curl -sSLf -o build\dl\sdl3.zip "https://github.com/libsdl-org/SDL/releases/download/release-%SDL%/SDL3-devel-%SDL%-VC.zip" || exit /b 1
	tar -xf build\dl\sdl3.zip -C build\dl || exit /b 1
	mkdir build\sdl3-win
	copy /y "build\dl\SDL3-%SDL%\lib\x64\SDL3.dll" build\sdl3-win\ >nul || exit /b 1
	copy /y "build\dl\SDL3-%SDL%\lib\x64\SDL3.lib" build\sdl3-win\ >nul || exit /b 1
	copy /y "build\dl\SDL3-%SDL%\LICENSE.txt" build\sdl3-win\ >nul || exit /b 1
)

rem zlib (src\win32\net_save.odin), built from source as build_windows.sh
rem does: Odin's vendor\zlib\libz.lib holds link-time code generation (/GL)
rem objects, which only an MSVC at least as new as the one that made them
rem can link. Static CRT (/MT) like Odin's.
set ZLIB=1.3.1
if not exist build\zlib-win\libz.lib (
	curl -sSLf -o build\dl\zlib.tar.gz "https://github.com/madler/zlib/releases/download/v%ZLIB%/zlib-%ZLIB%.tar.gz" || exit /b 1
	tar -xzf build\dl\zlib.tar.gz -C build\dl || exit /b 1
	mkdir build\zlib-win\obj 2>nul
	for %%f in (adler32 compress crc32 deflate inffast inflate inftrees trees uncompr zutil) do (
		cl /nologo /O2 /MT /w /c "build\dl\zlib-%ZLIB%\%%f.c" /Fobuild\zlib-win\obj\%%f.obj || exit /b 1
	)
	lib /nologo /out:build\zlib-win\libz.lib build\zlib-win\obj\*.obj || exit /b 1
)

for /f "delims=" %%r in ('odin root') do set "ODIN_SYS=%%r"
set "ROOT=%CD%\build\odin-win"
mkdir "%ROOT%\vendor" 2>nul
for %%d in (base core shared) do if not exist "%ROOT%\%%d" mklink /j "%ROOT%\%%d" "%ODIN_SYS%\%%d" >nul
for /d %%d in ("%ODIN_SYS%\vendor\*") do if /i not "%%~nxd"=="sdl3" if /i not "%%~nxd"=="zlib" if not exist "%ROOT%\vendor\%%~nxd" mklink /j "%ROOT%\vendor\%%~nxd" "%%d" >nul
xcopy /e /i /q /y "%ODIN_SYS%\vendor\sdl3" "%ROOT%\vendor\sdl3" >nul || exit /b 1
copy /y build\sdl3-win\SDL3.dll "%ROOT%\vendor\sdl3\" >nul || exit /b 1
copy /y build\sdl3-win\SDL3.lib "%ROOT%\vendor\sdl3\" >nul || exit /b 1
xcopy /e /i /q /y "%ODIN_SYS%\vendor\zlib" "%ROOT%\vendor\zlib" >nul || exit /b 1
copy /y build\zlib-win\libz.lib "%ROOT%\vendor\zlib\" >nul || exit /b 1

rem Bink movie decoding (src\win32\movie.c), static CRT (/MT) like Odin's.
cl /nologo /std:c17 /O2 /W3 /WX /MT /Ibuild\ffmpeg-win\include /c src\win32\movie.c /Fobuild\win\movie.obj || exit /b 1
lib /nologo /out:build\win\movie.lib build\win\movie.obj || exit /b 1

for /f %%i in ('python build_id.py windows') do set "BUILD_ID=%%i"
if not defined BUILD_ID (echo build_id.py failed. & exit /b 1)
set "ODIN_ROOT=%ROOT%"
odin build src -out:build\win\jade.exe -use-separate-modules -o:%JE_OPT% -microarch:%JE_ARCH% -define:GL_DEBUG=%JE_GL_DEBUG% -define:JE_BUILD_ID=%BUILD_ID% %* || exit /b 1

rem Runtime DLLs and their licences beside the exe.
copy /y build\sdl3-win\SDL3.dll build\win\ >nul || exit /b 1
for %%d in (avcodec-63 avformat-63 avutil-61 swresample-7 swscale-10) do copy /y build\ffmpeg-win\bin\%%d.dll build\win\ >nul || exit /b 1
copy /y build\sdl3-win\LICENSE.txt build\win\LICENSE-SDL3.txt >nul
copy /y build\ffmpeg-win\LICENSE.txt build\win\LICENSE-FFmpeg.txt >nul
copy /y play.bat build\win\ >nul
echo built build\win\jade.exe (build ID %BUILD_ID%)
