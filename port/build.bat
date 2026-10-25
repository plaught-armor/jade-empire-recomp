@echo off
rem Builds the port natively on 64-bit Windows: build\win\jade.exe plus the
rem DLLs it needs beside it (SDL3, FFmpeg) and play.bat. Needs nothing
rem installed: the pinned Odin release comes from ..\tools\odin.bat and links
rem with its own lld-link against the prebuilt libraries in winlib\lib, so
rem no Visual Studio or Windows SDK either; curl and tar come with Windows 10
rem and later. Generate src\rec first (README.md).
rem
rem The code targets x86-64-v3 (AVX2) unless JE_ARCH names another
rem -microarch, as in build_windows.sh, and a build from the same commit gets
rem the same build ID as that cross build, so the two play online together
rem (..\tools\build_id, docs/hle.md §11). JE_OPT=none builds unoptimized;
rem other arguments pass through to odin.
setlocal
cd /d "%~dp0"
if not exist src\rec\ (echo src\rec is missing: generate it with tools\x86rec first ^(README.md^). & exit /b 1)
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
rem uses), copied into the private Odin's vendor\sdl3 so the build links the
rem same SDL3.lib the exe ships with.
set SDL=3.4.2
if not exist build\sdl3-win\ (
	curl -sSLf -o build\dl\sdl3.zip "https://github.com/libsdl-org/SDL/releases/download/release-%SDL%/SDL3-devel-%SDL%-VC.zip" || exit /b 1
	tar -xf build\dl\sdl3.zip -C build\dl || exit /b 1
	mkdir build\sdl3-win
	copy /y "build\dl\SDL3-%SDL%\lib\x64\SDL3.dll" build\sdl3-win\ >nul || exit /b 1
	copy /y "build\dl\SDL3-%SDL%\lib\x64\SDL3.lib" build\sdl3-win\ >nul || exit /b 1
	copy /y "build\dl\SDL3-%SDL%\LICENSE.txt" build\sdl3-win\ >nul || exit /b 1
)

pushd ..
call tools\odin.bat || exit /b 1
popd
copy /y build\sdl3-win\SDL3.dll "%ODIN_ROOT%\vendor\sdl3\" >nul || exit /b 1
copy /y build\sdl3-win\SDL3.lib "%ODIN_ROOT%\vendor\sdl3\" >nul || exit /b 1

for /f %%i in ('call "%ODIN%" run ..\tools\build_id -out:build\win\build_id.exe %ODIN_LINK%') do set "BUILD_ID=%%i"
if not defined BUILD_ID (echo ..\tools\build_id failed. & exit /b 1)
"%ODIN%" build src -out:build\win\jade.exe %ODIN_LINK% -use-separate-modules -o:%JE_OPT% -microarch:%JE_ARCH% -define:GL_DEBUG=%JE_GL_DEBUG% -define:JE_BUILD_ID=%BUILD_ID% %* || exit /b 1

rem Runtime DLLs and their licences beside the exe.
copy /y build\sdl3-win\SDL3.dll build\win\ >nul || exit /b 1
for %%d in (avcodec-63 avformat-63 avutil-61 swresample-7 swscale-10) do copy /y build\ffmpeg-win\bin\%%d.dll build\win\ >nul || exit /b 1
copy /y build\sdl3-win\LICENSE.txt build\win\LICENSE-SDL3.txt >nul
copy /y build\ffmpeg-win\LICENSE.txt build\win\LICENSE-FFmpeg.txt >nul
copy /y play.bat build\win\ >nul
echo built build\win\jade.exe (build ID %BUILD_ID%)
