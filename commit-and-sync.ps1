#Requires -Version 5.1
# Double-click commit-and-sync.cmd. PowerShell 7 is required for the commit/sync workflow.
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
        Write-Host 'Install PowerShell 7 first, then run commit-and-sync again.' -ForegroundColor Red
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
    $default='Routine sync'
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        $value=Read-Host "Commit comment [$default]"
        if ([string]::IsNullOrWhiteSpace($value)) {return $default}
        return $value
    }
    # ReadKey supplies an editable initial value in both Windows PowerShell and PS7.
    Write-Host 'Commit comment (edit with arrows, Home/End, Backspace or Delete):'
    $value=$default; $position=$value.Length
    [Console]::Write($value)
    while ($true) {
        $key=[Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') {[Console]::WriteLine(); return $value}
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
}

# Git output is captured so a refused preview never enters an actual merge.
function Get-WorkGitResult {
    param([string[]]$Arguments)
    $ErrorActionPreference='Continue'
    $PSNativeCommandUseErrorActionPreference=$false
    $output=@(& git @Arguments 2>&1 | ForEach-Object {$_.ToString()})
    [pscustomobject]@{Code=$LASTEXITCODE;Output=$output}
}
function Invoke-WorkGit {
    param([string[]]$Arguments)
    $result=Get-WorkGitResult $Arguments
    if ($result.Code -ne 0) {throw ("Git $($Arguments[0]) failed:`n"+($result.Output -join "`n"))}
    return $result.Output
}
function Get-WorkHead {
    $result=Get-WorkGitResult @('rev-parse','--verify','HEAD')
    if ($result.Code -eq 0) {return $result.Output[0]}
    return $null
}
function Get-GitHubSnapshot {
    param([string]$Url,[string]$Ref)
    $lines=@(Invoke-WorkGit @('ls-remote','--refs',$Url,$Ref))
    if (!$lines.Count) {return $null}
    if ($lines.Count -ne 1) {throw 'GitHub returned an ambiguous branch reference.'}
    $oid=($lines[0] -split '\s+')[0]
    if ($oid -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {throw 'Invalid GitHub commit identifier.'}
    Invoke-WorkGit @('fetch','--no-write-fetch-head','--no-tags','--no-recurse-submodules',$Url,$oid) | Out-Null
    return $oid
}
function Get-SyncCounts {
    param($LocalOid,$RemoteOid)
    if (!$LocalOid) {return [pscustomobject]@{Ahead=0;Behind=$(if($RemoteOid){[int]@(Invoke-WorkGit @('rev-list','--count',$RemoteOid))[0]}else{0})}}
    if (!$RemoteOid) {return [pscustomobject]@{Ahead=[int]@(Invoke-WorkGit @('rev-list','--count',$LocalOid))[0];Behind=0}}
    $counts=@(Invoke-WorkGit @('rev-list','--left-right','--count',"${LocalOid}...${RemoteOid}"))[0] -split '\s+'
    [pscustomobject]@{Ahead=[int]$counts[0];Behind=[int]$counts[1]}
}
function Assert-SyncWorkArea {
    param($ExpectedHead,[string]$Branch)
    $current=@(Invoke-WorkGit @('symbolic-ref','--quiet','--short','HEAD'))[0]
    if ($current -cne $Branch -or (Get-WorkHead) -cne $ExpectedHead) {throw 'The local branch changed during this run. Nothing further was synced; please run again.'}
    if (@(Invoke-WorkGit @('status','--porcelain','--untracked-files=all')).Count) {throw 'Further uncommitted changes appeared. They are preserved; run again to review and commit them before syncing.'}
}
function Sync-WorkBranch {
    param([string]$Url,[string]$Ref,[string]$Branch)
    $localOid=Get-WorkHead
    Assert-SyncWorkArea $localOid $Branch
    $remoteOid=Get-GitHubSnapshot $Url $Ref
    $counts=Get-SyncCounts $localOid $remoteOid
    if ($counts.Behind -gt 0) {
        if ($counts.Ahead -eq 0) {
            Write-Host 'GitHub is ahead. Updating local files by fast-forward...'
            Write-Host ''
            Assert-SyncWorkArea $localOid $Branch
            Invoke-WorkGit @('-c','merge.autostash=false','merge','--ff-only','--no-edit',$remoteOid) | ForEach-Object {Write-Host $_}
        } else {
            Write-Host 'Both sides have commits. Checking whether Git can combine them without conflicts...'
            Write-Host ''
            $preview=Get-WorkGitResult @('merge-tree','--write-tree','--messages',$localOid,$remoteOid)
            if ($preview.Code -ne 0) {
                $preview.Output | Where-Object {$_ -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$'} | ForEach-Object {Write-Host $_}
                throw 'Sync stopped: the merge preview failed or found conflicts. No merge was applied to your files. Existing local commits, including any just created, are preserved.'
            }
            $tree=$preview.Output[0]
            if ($tree -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {throw 'Git did not return a valid preview tree. No merge was applied.'}
            # Record exactly the conflict-free preview, preserving both parent histories.
            # Fast-forward to that commit rather than rerunning merge drivers on live files.
            $mergeOid=@(Invoke-WorkGit @('commit-tree',$tree,'-p',$localOid,'-p',$remoteOid,'-m',"Merge GitHub changes into $Branch (commit-and-sync)"))[0]
            Assert-SyncWorkArea $localOid $Branch
            Invoke-WorkGit @('-c','merge.autostash=false','merge','--ff-only','--no-edit',$mergeOid) | ForEach-Object {Write-Host $_}
            Write-Host ''
            Write-Host 'The clean merge is committed locally; both original histories are preserved.'
        }
        Write-Host ''
        $localOid=Get-WorkHead
    }
    Assert-SyncWorkArea $localOid $Branch
    if ($localOid -and $localOid -ne $remoteOid) {
        Write-Host 'Syncing pending commits to GitHub...'
        Write-Host ''
        # An explicit, non-forced refspec also prevents following unrelated tags.
        Invoke-WorkGit @('-c','push.followTags=false','push','--porcelain',$Url,"${localOid}:$Ref") | ForEach-Object {Write-Host $_}
        Write-Host ''
    }
    $verified=@(Invoke-WorkGit @('ls-remote','--refs',$Url,$Ref))
    $verifiedOid=if($verified.Count){($verified[0] -split '\s+')[0]}else{$null}
    if ($verifiedOid -ne $localOid) {throw 'GitHub changed during sync, or verification failed. Your local commits are preserved; run again to retry.'}
    Write-Host 'Sync complete. This local branch and GitHub are up to date.'
}

$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
Set-Location -LiteralPath $PSScriptRoot
$failed=$false
try {
    if (!(Get-Command git -ErrorAction SilentlyContinue)) {throw 'Install Git for Windows, including Git Credential Manager, first.'}
    $version=@(Invoke-WorkGit @('--version'))[0]
    if ($version -notmatch 'git version (\d+)\.(\d+)' -or [int]$Matches[1] -lt 2 -or ([int]$Matches[1] -eq 2 -and [int]$Matches[2] -lt 38)) {throw 'Install Git 2.38 or newer first; clean merge preview requires it.'}
    $root=@(Invoke-WorkGit @('rev-parse','--show-toplevel'))[0]
    $expected=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\','/')
    $actual=[IO.Path]::GetFullPath($root).TrimEnd('\','/')
    $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if (![string]::Equals($expected,$actual,$comparison)) {throw 'Put this script at the repository root before running it.'}
    foreach ($operation in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','rebase-merge','rebase-apply','sequencer')) {
        $operationPath=@(Invoke-WorkGit @('rev-parse','--git-path',$operation))[0]
        if (Test-Path -LiteralPath $operationPath) {throw 'Another Git merge, rebase or recovery operation is already in progress. Finish it before running this script.'}
    }
    $branch=@(Invoke-WorkGit @('symbolic-ref','--quiet','--short','HEAD'))[0]
    $url=@(Invoke-WorkGit @('remote','get-url','--push','origin'))[0]
    if ($url -notmatch '^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)') {throw 'origin must point to a GitHub repository.'}
    $ref="refs/heads/$branch"
    $initialHead=Get-WorkHead
    Write-Host ''
    Write-Host "Work area: $PSScriptRoot"
    Write-Host "GitHub destination: $url (branch $branch)"
    Write-Host ''
    Write-Host 'Ctrl+C cancels and leaves you in PowerShell here.'
    Write-Host ''
    Write-Host 'Checking GitHub for existing unsynced commits...'
    $syncNeeded=$true
    try {
        $remoteOid=Get-GitHubSnapshot $url $ref
        $counts=Get-SyncCounts $initialHead $remoteOid
        $syncNeeded=$counts.Ahead -gt 0 -or $counts.Behind -gt 0
        if ($counts.Ahead -gt 0) {
            Write-Host ''
            Write-Host 'These commits are saved locally but have not been synced to GitHub:'
            Write-Host ''
            $range=if($remoteOid){"${remoteOid}..$initialHead"}else{$initialHead}
            Invoke-WorkGit @('--no-pager','log','--reverse','--format=Commit %h%nComment: %B',$range) | ForEach-Object {Write-Host $_}
        } else {Write-Host 'All existing local commits are already on GitHub.'}
        if ($counts.Behind -gt 0) {
            Write-Host ''
            Write-Host "GitHub has $($counts.Behind) commit(s) missing locally."
            if ($counts.Ahead -gt 0) {Write-Host 'A conflict-free merge will be attempted after confirmation.'}
            else {Write-Host 'Local files will be updated by fast-forward after confirmation.'}
        } elseif (!$syncNeeded) {Write-Host 'The local branch and GitHub currently match.'}
    } catch {
        $syncNeeded=$true
        Write-Host ''
        Write-Host 'GitHub sync status could not be verified. A sync attempt can be retried after confirmation.'
        if ($initialHead) {
            Write-Host 'Latest local commit (its sync status is unknown):'
            Write-Host ''
            Invoke-WorkGit @('--no-pager','log','-1','--format=Commit %h%nComment: %B',$initialHead) | ForEach-Object {Write-Host $_}
        }
    }
    $changes=@(Invoke-WorkGit @('status','--porcelain','--untracked-files=all'))
    Write-Host ''
    $comment=$null
    if ($changes.Count) {
        Write-Host 'Further file changes are present. These will form a new commit; existing commits stay intact.'
        Write-Host 'All Git-visible changes are included, including new files and deletions. Ignored files stay ignored.'
        Write-Host ''
        $changes | ForEach-Object {Write-Host $_}
        Write-Host ''
        $comment=Read-CommitComment
        if ([string]::IsNullOrWhiteSpace($comment)) {throw 'No commit was made: the comment was empty.'}
        Write-Host ''
        Write-Host "New commit comment: $comment"
        $syncNeeded=$true
        $question='Commit these further changes and sync with GitHub (allowing only conflict-free merges)? Type YES to confirm'
    } else {
        Write-Host 'No further file changes to commit.'
        $question='Try syncing with GitHub (allowing only conflict-free merges)? Type YES to confirm'
    }
    if (!$syncNeeded) {Write-Host 'Nothing needs to be committed or synced.'}
    else {
        Write-Host ''
        $confirmation=Read-Host $question
        Write-Host ''
        if ($confirmation -cne 'YES') {Write-Host 'Cancelled. Nothing was staged, committed or synced.'}
        else {
            if ((Get-WorkHead) -cne $initialHead -or @(Invoke-WorkGit @('symbolic-ref','--quiet','--short','HEAD'))[0] -cne $branch) {throw 'The branch changed while waiting for confirmation. Run again to review its current state.'}
            $currentChanges=@(Invoke-WorkGit @('status','--porcelain','--untracked-files=all'))
            if (($currentChanges -join "`n") -cne ($changes -join "`n")) {throw 'The file-change list changed while waiting for confirmation. Run again to review it.'}
            if ($changes.Count) {
                Write-Host 'Creating the new local commit...'
                Write-Host ''
                Invoke-WorkGit @('add','--all','--','.') | Out-Null
                Invoke-WorkGit @('commit','-m',$comment) | ForEach-Object {Write-Host $_}
                Write-Host ''
                Write-Host 'Local commit complete.'
                Write-Host ''
            }
            Sync-WorkBranch $url $ref $branch
        }
    }
} catch {
    $failed=$true
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host 'Any completed local commits are preserved. Resolve the reported problem and run again; no force-push is used.'
}
Write-Host ''
Write-Host 'Press Enter to close, or Ctrl+C to stay in PowerShell in this work area.'
$null=Read-Host
if ($failed) {[Environment]::Exit(1)}
[Environment]::Exit(0)
