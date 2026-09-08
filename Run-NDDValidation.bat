@echo off
setlocal
cd /d "%~dp0"

echo ============================================================
echo  NDD Print Deployment Validator
echo ============================================================
echo.

PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File ".\NDD-Deployment-Validator.ps1"
set EXITCODE=%ERRORLEVEL%

echo.
if "%EXITCODE%"=="0" (
    echo Validation finished successfully.
    echo Reports were saved in:
    echo %~dp0output
) else (
    echo Validation finished with an execution error. Exit code: %EXITCODE%
    echo Check the output folder for an *-error.txt file:
    echo %~dp0output
)

echo.
pause
exit /b %EXITCODE%
