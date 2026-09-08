@echo off
setlocal
cd /d "%~dp0"
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File ".\NDD-Deployment-Validator.ps1"
echo.
echo Validation finished. Check the output folder for TXT and JSON reports.
pause
