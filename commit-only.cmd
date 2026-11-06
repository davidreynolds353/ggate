@echo off
setlocal
rem Double-click to commit this work area locally using PowerShell 7.
set "PWSH="
for /f "delims=" %%P in ('"%SystemRoot%\System32\where.exe" pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH if exist "%LOCALAPPDATA%\PowerShell\7\pwsh.exe" set "PWSH=%LOCALAPPDATA%\PowerShell\7\pwsh.exe"
if not defined PWSH goto missing
"%PWSH%" -NoLogo -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -ge 7) {exit 0} else {exit 1}"
if errorlevel 1 goto missing
rem Parse launch and exit together, so replacing this launcher cannot affect its return.
(
    "%PWSH%" -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0commit-only.ps1" -InteractiveShell
    if errorlevel 1 exit /b 1
    exit /b 0
)
:missing
echo Install PowerShell 7 first, then run commit-only again.
echo Download: https://aka.ms/powershell-release?tag=stable
pause
exit /b 1

