@echo off
rem Builds primal-loader.asi (x64). Same toolchain as isle_mod_legacy/build_msvc.bat.
setlocal
set "ROOT=%~dp0"
set "VCVARS=%VCVARS64%"
if not defined VCVARS set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" ( echo vcvars64.bat not found: %VCVARS% & exit /b 1 )
call "%VCVARS%" >nul
if errorlevel 1 exit /b 1
if not exist "%ROOT%build" mkdir "%ROOT%build"
pushd "%ROOT%build"
rem /MT: no VC runtime dependency - the loader must load on a box with nothing installed.
cl /nologo /std:c++17 /EHsc /W4 /O2 /MT %EXTRA% /DUNICODE /D_UNICODE /LD "%ROOT%primal_loader.cpp" /Fe:primal-loader.asi /link /OUT:primal-loader.asi kernel32.lib
set ERR=%ERRORLEVEL%
popd
exit /b %ERR%
