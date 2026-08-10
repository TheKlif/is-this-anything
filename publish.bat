@echo off
cd /d "%~dp0"

set /p COMMITMSG="Enter publish reason: "

if not defined COMMITMSG (
    echo You must enter a reason.
    pause
    exit /b
)
if "%COMMITMSG%"=="" (
    echo You must enter a reason.
    pause
    exit /b
)

powershell.exe -ExecutionPolicy Bypass -File "publish.ps1"

if %errorlevel% neq 0 (
    echo Publish failed.
    pause
    exit /b
)

echo Publish complete.
pause