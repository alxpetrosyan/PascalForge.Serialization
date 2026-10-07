@echo off
rem Compile one project against the library in src\.
rem   dcc.cmd <project.dpr> [dcc32|dcc64] [output-subfolder]
rem Everything generated lands under artifacts\, never beside source.
setlocal
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat" >nul

set REPO=%~dp0..
set COMPILER=%~2
if "%COMPILER%"=="" set COMPILER=dcc32
set SUBDIR=%~3
if "%SUBDIR%"=="" set SUBDIR=tests
if /i "%COMPILER%"=="dcc64" (set PLATFORM=Win64) else (set PLATFORM=Win32)

set OUTBIN=%REPO%\artifacts\%SUBDIR%\%PLATFORM%
set OUTDCU=%REPO%\artifacts\dcu\%SUBDIR%\%PLATFORM%
if not exist "%OUTBIN%" mkdir "%OUTBIN%"
if not exist "%OUTDCU%" mkdir "%OUTDCU%"

pushd "%~dp1"
%COMPILER% -B -NSSystem;System.Win;Winapi;Data;Datasnap;Vcl;Xml ^
  -U"%REPO%\src" -NU"%OUTDCU%" -N0"%OUTDCU%" -E"%OUTBIN%" "%~nx1"
set ERR=%ERRORLEVEL%
popd
exit /b %ERR%
