@echo off
setlocal
rem Double-click to review, commit and sync this work area using PowerShell 7.
set "PWSH="
for /f "delims=" %%P in ('"%SystemRoot%\System32\where.exe" pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\PowerShell\7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\PowerShell\7\pwsh.exe"
if not defined PWSH goto missing
"%PWSH%" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 7) {exit 0} else {exit 1}"
if errorlevel 1 goto missing
"%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0commit-and-sync.ps1" -InteractiveShell
exit /b %errorlevel%
:missing
echo Install PowerShell 7 first, then run commit-and-sync again.
echo Download: https://aka.ms/powershell-release?tag=stable
pause
exit /b 1

