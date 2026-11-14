#requires -Version 5.1
[CmdletBinding()]
param([switch] $PrintConfig)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\installer.ps1')
$settingsPath = Join-Path $root 'settings.json'
$node = (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (!$node) { throw 'Install Node.js 24 LTS or newer and make sure node.exe is on PATH.' }
$npm = Join-Path (Split-Path -Parent $node) 'npm.cmd'
if (!(Test-Path -LiteralPath $npm -PathType Leaf)) { throw 'Install Node.js with npm in the same directory.' }
$nodeVersion = & $node --version
if ($LASTEXITCODE -ne 0 -or $nodeVersion -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 24) {
    throw 'Install Node.js 24 LTS or newer.'
}
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $csc -PathType Leaf)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (!(Test-Path -LiteralPath $csc -PathType Leaf)) { throw 'The Windows .NET Framework C# compiler was not found.' }

function Invoke-Rollback([scriptblock] $Step) {
    try { & $Step | Out-Null; return $true }
    catch { Write-Warning "Rollback step failed: $($_.Exception.Message)"; return $false }
}

function Remove-InstallDirectory([string] $Path) {
    try {
        Assert-SafeRemovalPath $Path
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    } catch { Write-Warning "Kept ${Path}: $($_.Exception.Message)" }
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

Assert-AdobeClosed
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$lock = [Threading.Mutex]::new($false, $mutexName)
try {
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'Installation or removal is already in progress.' }
    foreach ($path in $root,$modules,$runtime,$plugin,$settingsPath,$manifestPath) { Assert-NoLinkedPath $path }
    $previousManifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $previousManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-InstallManifest $previousManifest
        if ($previousManifest.uninstall) { throw 'An uninstall is pending. Finish it before reinstalling.' }
    }
    $stamp = [Guid]::NewGuid().ToString('N')
    $stage = Join-Path $root "runtime-stage-$stamp"
    $pluginStage = Join-Path $modules "LightroomMCP-stage-$stamp"
    $runtimeBackup = Join-Path $root "runtime-backup-$stamp"
    $pluginBackup = Join-Path $modules "LightroomMCP-backup-$stamp"
    $createdSettings = $false
    $movedRuntime = $false
    $movedPlugin = $false
    $installedRuntime = $false
    $installedPlugin = $false
    $attemptedRegistration = $false
    $stoppedTask = $false
    $keepStages = $false
    $previousTask = Get-WatcherTask
    if ($previousTask -and (@($previousTask.Actions).Count -ne 1 -or $previousTask.Actions.Execute -ine $watcher)) {
        throw 'The existing task has a different action. Review it before reinstalling.'
    }
    $previousTaskWasRunning = $previousTask.State -eq 'Running'
    if ($previousTask) { $previousTaskXml = Export-ScheduledTask -TaskName $taskName -TaskPath '\' }
    try {
        foreach ($directory in $stage, $modules, (Join-Path $root 'cep'), (Join-Path $root 'after-effects')) {
            Assert-NoLinkedPath $directory
            [void][IO.Directory]::CreateDirectory($directory)
        }
        foreach ($file in 'package.json','package-lock.json','premiere-shared.mjs','lightroom-hosted.mjs') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage
        }
        [IO.File]::WriteAllText((Join-Path $stage 'node-path.txt'), $node)
        Push-Location -LiteralPath $stage
        try {
            & $npm ci --no-audit --no-fund --ignore-scripts | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "npm ci failed ($LASTEXITCODE)." }
            & $node .\premiere-shared.mjs --prepare
            if ($LASTEXITCODE -ne 0) { throw 'Preparing the Premiere HTTP entry point failed.' }
        } finally { Pop-Location }

        $source = Join-Path $PSScriptRoot 'src\AdobeMcpAppLauncher.cs'
        $watcherName = 'AdobeMcpProcessWatcher.exe'
        $launcherName = 'LightroomMcpApp.exe'
        & $csc /nologo /target:winexe /optimize+ /define:WATCH /reference:System.Management.dll "/out:$stage\$watcherName" $source | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Compiling the Premiere/After Effects watcher failed.' }
        & $csc /nologo /target:winexe /optimize+ /define:LIGHTROOM "/out:$stage\$launcherName" $source | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Compiling the Lightroom launcher failed.' }

        $pluginSource = Join-Path $stage 'node_modules\@mskalski\lightroom-mcp\LightroomMCP.lrplugin'
        Copy-Item -LiteralPath $pluginSource -Destination $pluginStage -Recurse
        foreach ($file in 'PluginInit.lua','PluginShutdown.lua','Info.lua') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "lightroom\$file") -Destination $pluginStage -Force
        }
        $luaPath = Join-Path $pluginStage 'PluginInit.lua'
        $lua = [IO.File]::ReadAllText($luaPath)
        $placeholder = '__LIGHTROOM_LAUNCHER_LUA_LITERAL__'
        if ([regex]::Matches($lua, $placeholder).Count -ne 1) { throw 'Unexpected Lightroom hook template.' }
        $equals = '='
        while ($launcher.Contains("]$equals]")) { $equals += '=' }
        [IO.File]::WriteAllText($luaPath, $lua.Replace($placeholder, "[$equals[$launcher]$equals]"))

        if (Test-Path -LiteralPath $settingsPath) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
            foreach ($field in 'httpToken','uxpToken','lightroomHttpToken') {
                if ($settings.$field -cnotmatch '^[a-f0-9]{64}$') { throw "Invalid $field in existing settings.json." }
            }
        } else {
            $settings = [ordered]@{ httpToken = New-Token; uxpToken = New-Token; lightroomHttpToken = New-Token }
            [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json))
            $createdSettings = $true
        }

        Assert-AdobeClosed
        if ($previousTaskWasRunning) {
            $stoppedTask = $true
            Stop-WatcherTask
        }
        Wait-ForBridgeExit
        $backups = @($previousManifest.pluginBackups | Where-Object { $_ })
        $known = @{}
        foreach ($entry in $backups) { if ($entry.path) { $known[[string]$entry.path] = $true } }
        foreach ($folder in Get-ChildItem -LiteralPath $modules -Directory -Force -Filter 'LightroomMCP-backup-*') {
            if ($known.ContainsKey($folder.FullName)) { continue }
            $hasHook = $true
            try { $hasHook = Test-OurHook $folder.FullName }
            catch { Write-Warning "Cannot inspect backup hook: $($folder.FullName)" }
            $backups += [ordered]@{ path = $folder.FullName; origin = 'unknown'; hasOurHook = $hasHook; createdAt = $folder.LastWriteTimeUtc.ToString('o') }
        }
        if (Test-Path -LiteralPath $runtime) {
            [IO.Directory]::Move($runtime, $runtimeBackup)
            $movedRuntime = $true
        }
        [IO.Directory]::Move($stage, $runtime)
        $installedRuntime = $true
        if (Test-Path -LiteralPath $plugin) {
            $hasHook = Test-OurHook $plugin
            $origin = 'external'
            if (Test-PluginIsOurs $plugin $previousManifest.plugin) { $origin = 'ours' }
            elseif (!$previousManifest -and $hasHook) { $origin = 'legacy-ours' }
            [IO.Directory]::Move($plugin, $pluginBackup)
            $movedPlugin = $true
            $backups += [ordered]@{ path = $pluginBackup; origin = $origin; hasOurHook = $hasHook; createdAt = [DateTime]::UtcNow.ToString('o') }
        }
        [IO.Directory]::Move($pluginStage, $plugin)
        $installedPlugin = $true

        $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.User.Value
        $action = New-ScheduledTaskAction -Execute (Join-Path $runtime $watcherName) -WorkingDirectory $runtime
        $options = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $attemptedRegistration = $true
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $options -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName -TaskPath '\'
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') { break }
            Start-Sleep -Milliseconds 250
        }
        if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Running') { throw 'The watcher task did not start.' }
        $manifest = [ordered]@{
            schemaVersion = 1
            installedAt = [DateTime]::UtcNow.ToString('o')
            runtimePath = $runtime
            watcherExe = $watcher
            launcherExe = $launcher
            taskName = $taskName
            plugin = [ordered]@{ path = $plugin; files = @(Get-PluginFiles $plugin) }
            pluginBackups = @($backups)
        }
        Save-InstallManifest $manifest
    } catch {
        $installError = $_
        $rollbackComplete = $true
        if ($attemptedRegistration -and !(Invoke-Rollback { Stop-WatcherTask; Wait-ForBridgeExit })) {
            $rollbackComplete = $false
        } else {
            if ($installedPlugin -and !(Invoke-Rollback { [IO.Directory]::Move($plugin, $pluginStage) })) { $rollbackComplete = $false }
            if ($movedPlugin -and !(Invoke-Rollback { [IO.Directory]::Move($pluginBackup, $plugin) })) { $rollbackComplete = $false }
            if ($installedRuntime -and !(Invoke-Rollback { [IO.Directory]::Move($runtime, $stage) })) { $rollbackComplete = $false }
            if ($movedRuntime -and !(Invoke-Rollback { [IO.Directory]::Move($runtimeBackup, $runtime) })) { $rollbackComplete = $false }
            if ($createdSettings -and $rollbackComplete -and !(Invoke-Rollback { [IO.File]::Delete($settingsPath) })) { $rollbackComplete = $false }
            if ($attemptedRegistration -and !(Invoke-Rollback {
                if ($previousTask) {
                    Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $previousTaskXml -Force | Out-Null
                } elseif (Get-WatcherTask) {
                    Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
                }
            })) { $rollbackComplete = $false }
            if ($stoppedTask -and $rollbackComplete -and !(Invoke-Rollback { Start-ScheduledTask -TaskName $taskName -TaskPath '\' })) { $rollbackComplete = $false }
        }
        $keepStages = !$rollbackComplete -and ($movedRuntime -or $movedPlugin -or $installedRuntime -or $installedPlugin)
        if ($keepStages) {
            Write-Warning "Stop the watcher and Adobe MCP processes before recovering these paths: $runtime, $plugin, $stage, $pluginStage, $runtimeBackup, $pluginBackup"
        }
        throw $installError
    } finally {
        if (!$keepStages) {
            Remove-InstallDirectory $stage
            Remove-InstallDirectory $pluginStage
        }
    }

    Write-Host "Installed runtime: $runtime"
    Write-Host "Lightroom plugin: $plugin"
    if ($movedRuntime) { Write-Host "Previous runtime: $runtimeBackup" }
    if ($movedPlugin) { Write-Host "Previous Lightroom plugin: $pluginBackup" }
    Write-Host 'Complete the Adobe connector setup in README.md.'
    try {
        $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mcp_config.example.json') -Raw | ConvertFrom-Json
        $config.mcpServers.premiere_pro.headers.Authorization = 'Bearer ' + $settings.httpToken
        $config.mcpServers.lightroom_classic.headers.Authorization = 'Bearer ' + $settings.lightroomHttpToken
        $json = $config | ConvertTo-Json -Depth 6
        if ($PrintConfig) { $json }
        Write-AtomicText $configPath $json
        Write-Host "MCP config: $configPath (keep this private)."
    } catch { Write-Warning 'Could not write the client config. The installation is complete. Rerun with -PrintConfig to print it.' }
    try {
        Get-ChildItem -LiteralPath $root -Directory -Force -Filter 'runtime-backup-*' |
            Sort-Object @{ Expression = { $_.FullName -ieq $runtimeBackup }; Descending = $true },
                @{ Expression = { $_.LastWriteTimeUtc }; Descending = $true } |
            Select-Object -Skip 2 | ForEach-Object { Remove-InstallDirectory $_.FullName }
        $preserved = @($backups | Where-Object { $_.origin -cne 'ours' } | ForEach-Object { $_.path })
        $backups | Where-Object {
            $_.origin -ceq 'ours' -and $_.path -notin $preserved -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($_.path)) -ieq $modules -and
            [IO.Path]::GetFileName($_.path) -like 'LightroomMCP-backup-*' -and
            (Test-Path -LiteralPath $_.path -PathType Container)
        } | Sort-Object @{ Expression = { $_.path -ieq $pluginBackup }; Descending = $true },
            @{ Expression = { ([DateTimeOffset]$_.createdAt).UtcTicks }; Descending = $true } |
            Select-Object -Skip 2 | ForEach-Object { Remove-InstallDirectory $_.path }
    } catch { Write-Warning "Backup pruning skipped: $($_.Exception.Message)" }
} finally {
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
