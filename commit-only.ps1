#Requires -Version 5.1
# Double-click commit-only.cmd. PowerShell 7 is required for this commit-only workflow.
[CmdletBinding()]
param([switch]$InteractiveShell)

# Keep the bootstrap compatible with Windows PowerShell's right-click action.
if ($PSVersionTable.PSVersion.Major -lt 7 -or !$InteractiveShell) {
    $candidates=@()
    $command=Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($command) {$candidates+=$command.Source}
    foreach ($base in @($env:ProgramFiles,$env:LOCALAPPDATA)) {
        if ($base) {$candidates+=Join-Path $base 'PowerShell/7/pwsh.exe'}
    }
    $executable=$null
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (!(Test-Path -LiteralPath $candidate)) {continue}
        try {
            & $candidate -NoLogo -NoProfile -Command 'if ($PSVersionTable.PSVersion.Major -ge 7) {exit 0} else {exit 1}' | Out-Null
            if ($LASTEXITCODE -eq 0) {$executable=$candidate;break}
        } catch {continue}
    }
    if (!$executable) {
        Write-Host ''
        Write-Host 'Install PowerShell 7 first, then run commit-only again.' -ForegroundColor Red
        Write-Host 'Download: https://aka.ms/powershell-release?tag=stable'
        Write-Host ''
        $null=Read-Host 'Press Enter to close'
        [Environment]::Exit(1)
    }
    $arguments='-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -InteractiveShell'
    $child=Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $PSScriptRoot -WindowStyle Normal -Wait -PassThru
    [Environment]::Exit($child.ExitCode)
}
function Read-CommitComment {
    $default='.'
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $value=Read-Host "Commit comment [$default]"
        if ([string]::IsNullOrWhiteSpace($value)) {return $default}
        return $value
    }
    # Capture Ctrl+C explicitly so cancellation never reaches git add or git commit.
    $previousControlC=[Console]::TreatControlCAsInput
    try {
        [Console]::TreatControlCAsInput=$true
        Write-Host 'Commit comment (edit with arrows, Home/End, Backspace or Delete):'
        $value=$default; $position=$value.Length
        [Console]::Write($value)
        while ($true) {
            $key=[Console]::ReadKey($true)
            if ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                [Console]::WriteLine()
                throw [OperationCanceledException]::new('Commit cancelled.')
            }
            if ($key.Key -eq 'Enter') {
                [Console]::WriteLine()
                if ([string]::IsNullOrWhiteSpace($value)) {return $default}
                return $value
            }
            if ($key.Key -eq 'LeftArrow') {if ($position -gt 0) {[Console]::Write([char]8);$position--};continue}
            if ($key.Key -eq 'RightArrow') {if ($position -lt $value.Length) {[Console]::Write($value[$position]);$position++};continue}
            if ($key.Key -eq 'Home') {[Console]::Write(([string][char]8)*$position);$position=0;continue}
            if ($key.Key -eq 'End') {[Console]::Write($value.Substring($position));$position=$value.Length;continue}
            $oldLength=$value.Length; $oldPosition=$position
            if ($key.Key -eq 'Backspace' -and $position -gt 0) {$value=$value.Remove($position-1,1);$position--}
            elseif ($key.Key -eq 'Delete' -and $position -lt $value.Length) {$value=$value.Remove($position,1)}
            elseif (![char]::IsControl($key.KeyChar)) {$value=$value.Insert($position,[string]$key.KeyChar);$position++}
            else {continue}
            [Console]::Write(([string][char]8)*$oldPosition)
            [Console]::Write($value+(' '*[Math]::Max(0,$oldLength-$value.Length)))
            [Console]::Write(([string][char]8)*([Math]::Max($oldLength,$value.Length)-$position))
        }
    } finally {[Console]::TreatControlCAsInput=$previousControlC}
}

function Get-LocalGitResult {
    param([string[]]$Arguments)
    $ErrorActionPreference='Continue'
    $PSNativeCommandUseErrorActionPreference=$false
    $output=@(& git @Arguments 2>&1 | ForEach-Object {$_.ToString()})
    [pscustomobject]@{Code=$LASTEXITCODE;Output=$output}
}
function Invoke-LocalGit {
    param([string[]]$Arguments)
    $result=Get-LocalGitResult $Arguments
    if ($result.Code -ne 0) {throw ("Git $($Arguments[0]) failed:`n"+($result.Output -join "`n"))}
    return $result.Output
}
function Get-LocalHead {
    $result=Get-LocalGitResult @('rev-parse','--verify','HEAD')
    if ($result.Code -eq 0) {return $result.Output[0]}
    return $null
}

$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
Set-Location -LiteralPath $PSScriptRoot
$failed=$false
try {
    if (!(Get-Command git -ErrorAction SilentlyContinue)) {throw 'Install Git first and ensure it is available on PATH.'}
    $root=@(Invoke-LocalGit @('rev-parse','--show-toplevel'))[0]
    $expected=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
    $actual=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if (![string]::Equals($expected,$actual,$comparison)) {throw 'Put this script at the repository root before running it.'}
    foreach ($operation in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','sequencer')) {
        $operationPath=@(Invoke-LocalGit @('rev-parse','--git-path',$operation))[0]
        if (Test-Path -LiteralPath $operationPath) {throw 'Another Git operation is in progress. Finish it before running commit-only.'}
    }
    $branch=@(Invoke-LocalGit @('symbolic-ref','--quiet','--short','HEAD'))[0]
    $initialHead=Get-LocalHead
    $changes=@(Invoke-LocalGit @('status','--porcelain','--untracked-files=all'))
    Write-Host ''
    Write-Host "Work area: $PSScriptRoot"
    Write-Host "Branch: $branch"
    Write-Host ''
    if (!$changes.Count) {Write-Host 'No changes to commit.'}
    else {
        Write-Host 'All Git-visible changes will be committed locally, including new files and deletions.'
        Write-Host 'Ignored files stay ignored. This script does not fetch, pull or push.'
        Write-Host ''
        $changes | ForEach-Object {Write-Host $_}
        Write-Host ''
        Write-Host 'Edit the comment below. Enter commits immediately; Ctrl+C cancels and leaves you in PowerShell here.'
        Write-Host 'There is no further confirmation.'
        $comment=Read-CommitComment
        # Do not stage anything until the user has accepted their comment with Enter.
        if ((Get-LocalHead) -cne $initialHead -or @(Invoke-LocalGit @('symbolic-ref','--quiet','--short','HEAD'))[0] -cne $branch) {throw 'The branch changed while editing the comment. Run again to review its current state.'}
        $currentChanges=@(Invoke-LocalGit @('status','--porcelain','--untracked-files=all'))
        if (($currentChanges -join "`n") -cne ($changes -join "`n")) {throw 'The file-change list changed while editing the comment. Run again to review it.'}
        Write-Host ''
        Write-Host 'Creating the local commit...'
        Write-Host ''
        Invoke-LocalGit @('add','--all','--','.') | Out-Null
        Invoke-LocalGit @('commit','-m',$comment) | ForEach-Object {Write-Host $_}
        Write-Host ''
        Write-Host 'Local commit complete.'
    }
} catch [OperationCanceledException] {
    Write-Host ''
    Write-Host 'Cancelled. Nothing was staged or committed. You are in PowerShell in this work area.'
    return
} catch {
    $failed=$true
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
}
Write-Host ''
Write-Host 'Press Enter to close, or Ctrl+C to stay in PowerShell in this work area.'
$null=Read-Host
if ($failed) {[Environment]::Exit(1)}
[Environment]::Exit(0)
