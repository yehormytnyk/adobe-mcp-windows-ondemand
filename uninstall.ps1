#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([switch] $RemoveAll)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\installer.ps1')
$summary = [Collections.Generic.List[string]]::new()
$planned = [Collections.Generic.List[string]]::new()

function Remove-OwnedPath([string] $Path, [switch] $PrivateData) {
    if (!(Test-Path -LiteralPath $Path)) { return }
    try {
        Assert-SafeRemovalPath $Path -PrivateData:$PrivateData
        if ($PSCmdlet.ShouldProcess($Path, 'Remove')) {
            if ((Get-Item -LiteralPath $Path -Force).PSIsContainer) {
                Remove-Item -LiteralPath $Path -Recurse -Force
            } else {
                Remove-Item -LiteralPath $Path -Force
            }
            $summary.Add("Removed: $Path")
        } elseif ($WhatIfPreference) {
            $planned.Add($Path)
        } else {
            throw 'Removal was declined.'
        }
    } catch {
        $summary.Add("Kept ${Path}: $($_.Exception.Message)")
        Write-Warning $summary[$summary.Count - 1]
        $script:cleanupFailed = $true
    }
}

function Complete-Phase([string] $Name) {
    if ($WhatIfPreference) { return }
    $state.$Name = $true
    Save-InstallManifest $manifest
}

function Get-RestoreCandidate([string] $Path) {
    if (!$Path) { return }
    try {
        Assert-SafeRemovalPath $Path
        $parent = [IO.Path]::GetDirectoryName($Path)
        if ($parent -ine $modules -or [IO.Path]::GetFileName($Path) -notlike 'LightroomMCP-backup-*' -or
            !(Test-Path -LiteralPath $Path -PathType Container) -or (Test-OurHook $Path)) {
            throw 'Backup is missing or is ineligible for automatic restoration.'
        }
        return $Path
    } catch {
        $summary.Add("Skipped restore of ${Path}: $($_.Exception.Message)")
        Write-Warning $summary[$summary.Count - 1]
    }
}

function Test-HoldingRemainder([string] $Path, $Recorded) {
    if (!$Recorded -or !@($Recorded.files).Count) { return $false }
    $hashes = @{}
    $directories = @{}
    foreach ($file in $Recorded.files) {
        if (!$file.path -or $hashes.ContainsKey($file.path) -or $file.sha256 -notmatch '^[a-f0-9]{64}$') { return $false }
        $hashes[$file.path] = $file.sha256
        $parent = [IO.Path]::GetDirectoryName($file.path)
        while ($parent) {
            $directories[$parent.Replace('\','/')] = $true
            $parent = [IO.Path]::GetDirectoryName($parent)
        }
    }
    Assert-NoLinkedPath $Path
    foreach ($item in Get-PlainTree $Path) {
        $relative = $item.FullName.Substring($Path.Length + 1).Replace('\','/')
        if ($item.PSIsContainer) {
            if (!$directories.ContainsKey($relative)) { return $false }
        } elseif (!$hashes.ContainsKey($relative) -or
            (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash -ine $hashes[$relative]) { return $false }
    }
    return $true
}

function Complete-PluginRemoval([string] $BackupPath) {
    if ($BackupPath) { $summary.Add("Replaced our Lightroom plugin with $BackupPath") }
    else { $summary.Add("Removed our Lightroom plugin: $plugin") }
    Complete-Phase 'pluginDone'
}

function Restore-OrRemovePlugin {
    $pending = $state.pendingPlugin
    if (!$pending) {
        if (!(Test-PluginIsOurs $plugin $manifest.plugin)) {
            if (Test-Path -LiteralPath $plugin) { $summary.Add('Kept Lightroom plugin: plugin was changed after our install; not removed.') }
            Complete-Phase 'pluginDone'
            return
        }
        $candidate = $manifest.pluginBackups | Where-Object {
            $_.origin -ceq 'external' -and $_.hasOurHook -is [bool] -and !$_.hasOurHook
        } | Sort-Object createdAt -Descending | Select-Object -First 1
        $backupPath = [string](Get-RestoreCandidate $candidate.path)
        $pending = [pscustomobject]@{
            holding = Join-Path $modules ('LightroomMCP-stage-' + [Guid]::NewGuid().ToString('N'))
            backup = $backupPath
            backupFiles = @(if ($backupPath) { Get-PluginFiles $backupPath })
        }
    }
    if ([IO.Path]::GetDirectoryName($pending.holding) -ine $modules -or
        [IO.Path]::GetFileName($pending.holding) -notlike 'LightroomMCP-stage-*') { throw 'Unexpected plugin holding directory.' }
    Assert-SafeRemovalPath $pending.holding
    Assert-SafeRemovalPath $plugin
    if ($pending.backup -and !($manifest.pluginBackups | Where-Object {
        $_.path -ieq $pending.backup -and $_.origin -ceq 'external' -and $_.hasOurHook -is [bool] -and !$_.hasOurHook
    })) { throw 'The pending backup does not match the recorded external backup.' }
    $held = Test-Path -LiteralPath $pending.holding
    $present = Test-Path -LiteralPath $plugin
    if ($pending.holdingRemovalStarted -eq $true) {
        if ($pending.backup) {
            if (!$present -or (Test-Path -LiteralPath $pending.backup) -or
                !(Test-PluginIsOurs $plugin @{ files = $pending.backupFiles })) { throw 'Restored Lightroom plugin changed during uninstall.' }
        } elseif ($present) { throw 'Lightroom plugin appeared during uninstall.' }
        if ($held) {
            if (!(Test-HoldingRemainder $pending.holding $manifest.plugin)) {
                throw "Holding folder changed. Review $($pending.holding) before retrying."
            }
            Remove-OwnedPath $pending.holding
            if ($script:cleanupFailed) { throw 'Plugin cleanup is incomplete. Rerun uninstall.ps1 to resume.' }
            if ($WhatIfPreference) { return }
        }
        Complete-PluginRemoval $pending.backup
        return
    }
    if ($held -and !(Test-PluginIsOurs $pending.holding $manifest.plugin)) {
        throw "Holding folder changed. Review $($pending.holding) before retrying."
    }
    if (!$held -and !$present -and $pending.backup) {
        throw "Plugin recovery requires inspection: $($pending.holding), $($pending.backup)"
    }
    if ($held -and $present -and (!$pending.backup -or (Test-Path -LiteralPath $pending.backup))) {
        throw "Plugin restore destination is occupied. Holding folder kept: $($pending.holding)"
    }
    if ($held -and $present -and !(Test-PluginIsOurs $plugin @{ files = $pending.backupFiles })) {
        throw "Restored plugin could not be verified. Holding folder kept: $($pending.holding)"
    }
    if (!$held -and $present -and !(Test-PluginIsOurs $plugin $manifest.plugin)) {
        if (!$pending.backup -or (Test-Path -LiteralPath $pending.backup) -or
            !(Test-PluginIsOurs $plugin @{ files = $pending.backupFiles })) { throw 'Lightroom plugin changed during uninstall.' }
        Complete-PluginRemoval $pending.backup
        return
    }
    $restorePath = if (!$present -or !$held) { Get-RestoreCandidate $pending.backup }
    if ($held -and !$present -and $pending.backup -and !$restorePath) {
        throw "Previously selected backup is unavailable. Holding folder kept: $($pending.holding)"
    }
    if (!$PSCmdlet.ShouldProcess($plugin, 'Remove the installed Lightroom plugin')) {
        if ($WhatIfPreference) {
            if ($restorePath) { [void]$PSCmdlet.ShouldProcess($restorePath, "Restore to $plugin") }
            return
        }
        throw 'Lightroom plugin removal was declined.'
    }
    if ($restorePath -and !$PSCmdlet.ShouldProcess($restorePath, "Restore to $plugin")) { throw 'Plugin restoration was declined.' }
    if (!$state.pendingPlugin) {
        $pending.backup = [string]$restorePath
        if (!$restorePath) { $pending.backupFiles = @() }
        $state.pendingPlugin = $pending
        Save-InstallManifest $manifest
    }
    if (!$held -and $present) {
        [IO.Directory]::Move($plugin, $pending.holding)
        $held = $true
        $present = $false
    }
    if ($held -and !$present -and $restorePath) {
        try {
            if (!(Test-PluginIsOurs $restorePath @{ files = $pending.backupFiles })) {
                throw 'The selected backup changed after it was recorded.'
            }
            [IO.Directory]::Move($restorePath, $plugin)
        }
        catch {
            $restoreError = $_
            try { [IO.Directory]::Move($pending.holding, $plugin) }
            catch { throw "Restore failed and the plugin could not be put back. Kept $($pending.holding) and $restorePath." }
            throw "Restore failed, our plugin kept in place: $($restoreError.Exception.Message)"
        }
        $summary.Add("Restored: $restorePath -> $plugin")
    }
    $pending | Add-Member -NotePropertyName holdingRemovalStarted -NotePropertyValue $true -Force
    Save-InstallManifest $manifest
    if ($held) { Remove-OwnedPath $pending.holding }
    if ($script:cleanupFailed) { throw 'Plugin cleanup is incomplete. Rerun uninstall.ps1 to resume.' }
    Complete-PluginRemoval $pending.backup
}

$lock = [Threading.Mutex]::new($false, $mutexName)
$locked = $false
$cleanupFailed = $false
try {
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Installation or removal is already in progress.' }
    Assert-AdobeClosed
    Assert-NoLinkedPath $manifestPath
    if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "Install manifest missing: $manifestPath" }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-InstallManifest $manifest
    if (!$manifest.uninstall) {
        $manifest | Add-Member -NotePropertyName uninstall -NotePropertyValue ([pscustomobject]@{ pluginDone = $false; pendingPlugin = $null; runtimeDone = $false })
    }
    $state = $manifest.uninstall

    $task = Get-WatcherTask
    if ($task -and (@($task.Actions).Count -ne 1 -or $task.Actions.Execute -ine $watcher)) {
        throw 'Runtime kept: the scheduled task has a different action.'
    }
    if ($task -and $PSCmdlet.ShouldProcess("\$taskName", 'Stop and unregister scheduled task')) {
        Stop-WatcherTask
        Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
        $summary.Add("Removed task: \$taskName")
    }
    if (!$WhatIfPreference -and (Get-WatcherTask)) { throw 'Runtime kept: the scheduled task still exists.' }
    foreach ($process in @(Get-OurBridgeProcesses | Where-Object Name -ne 'node.exe')) {
        if ($PSCmdlet.ShouldProcess("$($process.Name) ($($process.ProcessId))", 'Stop launcher')) {
            $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.ProcessId)"
            if ($live -and $live.CreationDate -eq $process.CreationDate -and $live.ExecutablePath -ieq $process.ExecutablePath) {
                Stop-Process -Id $process.ProcessId
            }
        }
    }
    if (!$WhatIfPreference) { Wait-ForBridgeExit }
    Assert-AdobeClosed
    if (!$state.pluginDone) { Restore-OrRemovePlugin }

    if (!$state.runtimeDone) {
        if (!$WhatIfPreference) { Wait-ForBridgeExit }
        Remove-OwnedPath $runtime
        if (!$cleanupFailed) { Complete-Phase 'runtimeDone' }
    }
    foreach ($dir in Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object Name -match '^runtime-(stage|backup)-') {
        Remove-OwnedPath $dir.FullName
    }
    if ($cleanupFailed) { throw 'Uninstall incomplete. Manifest kept for retry.' }
    if ($RemoveAll) {
        foreach ($item in Get-ChildItem -LiteralPath $root -Force | Where-Object Name -match '^(settings\.json|mcp_config\.generated\.json|[^:]+-app-(output|error)\.log[^:]*|cep|after-effects)$') {
            Remove-OwnedPath $item.FullName -PrivateData
        }
    }
    if ($cleanupFailed) { throw 'Uninstall incomplete. Manifest kept for retry.' }
    Remove-OwnedPath $manifestPath -PrivateData
    if ($cleanupFailed) { throw 'Manifest could not be removed. Rerun uninstall.ps1 to retry.' }
    $leftovers = @(Get-ChildItem -LiteralPath $root -Force | Where-Object FullName -notin $planned)
    if ($RemoveAll -and !$leftovers.Count -and $PSCmdlet.ShouldProcess($root, 'Remove empty installation directory')) {
        Assert-NoLinkedPath $root
        [IO.Directory]::Delete($root, $false)
        $summary.Add("Removed: $root")
    }
    foreach ($item in $leftovers) { $summary.Add("Kept: $($item.FullName)") }
} catch {
    $summary.Add("Stopped: $($_.Exception.Message)")
    throw
} finally {
    if ($manifest) {
        foreach ($backup in $manifest.pluginBackups) {
            if ($backup.path -and (Test-Path -LiteralPath $backup.path -ErrorAction SilentlyContinue)) {
                $summary.Add("Kept backup ($($backup.origin)): $($backup.path)")
            }
        }
    }
    foreach ($line in $summary) { Write-Host $line }
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
