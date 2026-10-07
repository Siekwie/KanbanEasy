@echo off
rem Double-click to build dist\KanbanEasy.exe (the runtime is downloaded automatically).
rem From a terminal you can pass a target: build.bat install ^| love ^| run ^| clean
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build.ps1" %*
set "rc=%ERRORLEVEL%"
if "%rc%"=="0" if "%~1"=="" explorer /select,"%~dp0dist\KanbanEasy.exe"
if "%~1"=="" pause
exit /b %rc%
