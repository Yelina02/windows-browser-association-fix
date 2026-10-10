@echo off
setlocal
set "WB_AF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "WB_AF_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%WB_AF_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-BrowserAssociationFix.ps1"
if errorlevel 1 pause
endlocal
