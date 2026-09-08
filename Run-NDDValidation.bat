@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "OUTPUT=%~dp0output"
if not exist "%OUTPUT%" mkdir "%OUTPUT%"

set "RUNLOG=%OUTPUT%\launcher-debug.txt"

> "%RUNLOG%" echo ============================================================
>>"%RUNLOG%" echo NDD Print Deployment Validator - Launcher Debug
>>"%RUNLOG%" echo ============================================================
>>"%RUNLOG%" echo Date: %date% %time%
>>"%RUNLOG%" echo Working directory: %CD%
>>"%RUNLOG%" echo Script expected: %~dp0NDD-Deployment-Validator.ps1
>>"%RUNLOG%" echo.

echo ============================================================
echo  NDD Print Deployment Validator
echo ============================================================
echo.
echo Output folder:
echo %OUTPUT%
echo.

if not exist ".\NDD-Deployment-Validator.ps1" (
    echo ERROR: NDD-Deployment-Validator.ps1 was not found.
    >>"%RUNLOG%" echo ERROR: PowerShell script was not found.
    echo Check: %RUNLOG%
    pause
    exit /b 10
)

where PowerShell.exe >>"%RUNLOG%" 2>&1
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    >>"%RUNLOG%" echo ERROR: PowerShell.exe was not found in PATH.
    echo Check: %RUNLOG%
    pause
    exit /b 11
)

>>"%RUNLOG%" echo PowerShell found. Starting validator...
>>"%RUNLOG%" echo.

PowerShell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File ".\NDD-Deployment-Validator.ps1" >>"%RUNLOG%" 2>&1
set "EXITCODE=%ERRORLEVEL%"

>>"%RUNLOG%" echo.
>>"%RUNLOG%" echo PowerShell exit code: %EXITCODE%
>>"%RUNLOG%" echo Finished: %date% %time%

echo.
if "%EXITCODE%"=="0" (
    echo Validation finished successfully.
) else (
    echo Validation returned exit code %EXITCODE%.
)

echo.
echo Files generated in:
echo %OUTPUT%
echo.
echo Diagnostic launcher log:
echo %RUNLOG%
echo.
pause
exit /b %EXITCODE%
