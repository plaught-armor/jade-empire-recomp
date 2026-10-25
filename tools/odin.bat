@echo off
rem Sets ODIN to the Odin release the Windows build uses, downloading it into
rem port\build\odin the first time, and ODIN_LINK and LIB to the flags and
rem library folder that link with that release's own lld-link against
rem port\winlib\lib alone, so no Visual Studio or Windows SDK is needed
rem (docs/hle.md §13). The release is pinned: online peers need the same Odin
rem version for the same build ID (tools\build_id). Call it from the
rem repository root; curl, tar and certutil come with Windows 10 and later.
set ODIN_VER=dev-2026-10
set ODIN_SHA=b6b2e426a8b6f147b74ec7e18bef8df27cf40fe16193159df7ca09a0cc0c2011
set "ODIN_ROOT=%CD%\port\build\odin\%ODIN_VER%\dist"
set "ODIN=%ODIN_ROOT%\odin.exe"
if exist "%ODIN%" goto have
mkdir port\build\dl 2>nul
set "ZIP=port\build\dl\odin-windows-amd64-%ODIN_VER%.zip"
curl -sSLf -o "%ZIP%" "https://github.com/odin-lang/Odin/releases/download/%ODIN_VER%/odin-windows-amd64-%ODIN_VER%.zip" || exit /b 1
certutil -hashfile "%ZIP%" SHA256 | findstr /i /x "%ODIN_SHA%" >nul || (echo %ZIP%: checksum mismatch. & exit /b 1)
if exist "port\build\odin\%ODIN_VER%\" rmdir /s /q "port\build\odin\%ODIN_VER%"
mkdir "port\build\odin\%ODIN_VER%"
tar -xf "%ZIP%" -C "port\build\odin\%ODIN_VER%" || exit /b 1
if not exist "%ODIN%" (echo %ZIP% holds no dist\odin.exe. & exit /b 1)
:have
rem The release's vendor\zlib\libz.lib holds link-time code generation (/GL)
rem objects, which lld-link cannot read: this private copy of Odin gets
rem winlib's instead.
copy /y port\winlib\lib\libz.lib "%ODIN_ROOT%\vendor\zlib\" >nul || exit /b 1
rem lld-link searches LIB for libraries; a /libpath flag could not hold a
rem folder with a space, as Odin splits its -extra-linker-flags at spaces.
set "LIB=%CD%\port\winlib\lib"
set ODIN_LINK=-ignore-vs-search -linker:lld "-extra-linker-flags:/nodefaultlib jadecrt.lib libucrt.lib"
exit /b 0
