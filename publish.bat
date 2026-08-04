@echo off
cd /d "D:\Is This Anything\TheKlif.github.io"

set /p COMMITMSG="Enter publish reason: "

powershell.exe -ExecutionPolicy Bypass -File "publish.ps1"

if %errorlevel% neq 0 (
    echo Publish failed; not committing.
    pause
    exit /b
)

git add .

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

git commit -m "%COMMITMSG%"
git push

echo Publish complete.
pause