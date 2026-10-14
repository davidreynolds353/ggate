#Requires -Version 5.1
# Copy this file to the root of any Git work area. Right-click > Run with PowerShell.
[CmdletBinding()]
param([switch]$InteractiveShell)

if (!$InteractiveShell) {
    # Explorer normally closes its PowerShell process after a script returns.
    # A separate -NoExit session lets Ctrl+C return to a usable shell instead.
    $executable=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $arguments='-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -InteractiveShell'
    Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Normal -Wait
    [Environment]::Exit(0)
}

$ErrorActionPreference='Stop'
Set-Location -LiteralPath $PSScriptRoot
$failed=$false
try {
    if (!(Get-Command git -ErrorAction SilentlyContinue)) {throw 'Git is not installed or is not on PATH.'}
    $root=@(& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -or $root.Count -ne 1) {throw 'This directory is not a Git work area.'}
    $expected=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
    $actual=[IO.Path]::GetFullPath($root[0]).TrimEnd('\','/')
    if (![string]::Equals($expected,$actual,[StringComparison]::OrdinalIgnoreCase)) {throw 'Put this script at the repository root before running it.'}
    $changes=@(& git status --porcelain --untracked-files=all)
    if ($LASTEXITCODE) {throw 'Git could not check the work area.'}
    Write-Host "Work area: $PSScriptRoot"
    if (!$changes.Count) {
        Write-Host 'No changes to commit.'
    } else {
        Write-Host 'Committing all Git-visible changes, including new files and deletions. Ignored files stay ignored.'
        Write-Host 'Ctrl+C cancels and leaves you in PowerShell here.'
        $comment=Read-Host 'Commit comment'
        if ([string]::IsNullOrWhiteSpace($comment)) {throw 'No commit was made: the comment was empty.'}
        & git add --all -- .
        if ($LASTEXITCODE) {throw 'Git could not prepare all changes; no commit was made.'}
        & git commit -m $comment
        if ($LASTEXITCODE) {throw 'Git could not make the commit. See its message above.'}
        Write-Host 'Commit complete.'
    }
} catch {
    $failed=$true
    Write-Host $_.Exception.Message -ForegroundColor Red
}
Write-Host ''
Write-Host 'Press Enter to close, or Ctrl+C to stay in PowerShell in this work area.'
$null=Read-Host
# With -NoExit, 'exit' inside a -File script can merely finish the script.
# Enter must terminate this dedicated host process; Ctrl+C interrupts Read-Host
# before reaching here and therefore leaves the -NoExit shell available.
if ($failed) {[Environment]::Exit(1)}
[Environment]::Exit(0)
