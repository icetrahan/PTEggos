@echo off
setlocal
set "ROOT=%~dp0"
set "VCVARS=%VCVARS64%"
if not defined VCVARS set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
call "%VCVARS%" >nul
if not exist "%ROOT%build" mkdir "%ROOT%build"
pushd "%ROOT%build"
cl /nologo /EHsc /O2 /MT /DUNICODE /D_UNICODE "%ROOT%fake_game.cpp" /Fe:fake_game.exe || exit /b 1
cl /nologo /EHsc /O2 /MT /DUNICODE /D_UNICODE /LD "%ROOT%probe_dll.cpp" /Fe:probe.dll || exit /b 1
popd
