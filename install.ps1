#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'AdobeMcp-Premiere'
$runtime = Join-Path $root 'runtime'
$settingsPath = Join-Path $root 'settings.json'
$modules = Join-Path $env:APPDATA 'Adobe\Lightroom\Modules'
$plugin = Join-Path $modules 'LightroomMCP.lrplugin'
$taskName = 'AdobeMCP-Premiere-AppWatcher'
$node = (Get-Command node.exe -CommandType Application | Select-Object -First 1).Source
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

function Assert-AdobeClosed {
    $session = (Get-Process -Id $PID).SessionId
    $hosts = Get-Process -Name 'Adobe Premiere Pro','AfterFX','Lightroom' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session -and ($_.ProcessName -ne 'AfterFX' -or $_.MainWindowHandle -ne 0) }
    if ($hosts) { throw 'Close Premiere Pro, After Effects and Lightroom Classic before installing.' }
}

function New-Token {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
}

Assert-AdobeClosed
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$lock = [Threading.Mutex]::new($false, 'Local\AdobeMcpWindowsOnDemand-Install')
try {
    try { $locked = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (!$locked) { throw 'An installation is already in progress.' }
    $stamp = [Guid]::NewGuid().ToString('N')
    $stage = Join-Path $root "runtime-stage-$stamp"
    $pluginStage = Join-Path $modules "LightroomMCP-stage-$stamp"
    $runtimeBackup = Join-Path $root "runtime-backup-$stamp"
    $pluginBackup = Join-Path $modules "LightroomMCP-backup-$stamp"
    foreach ($directory in $stage, $modules, (Join-Path $root 'cep'), (Join-Path $root 'after-effects')) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $createdSettings = $false
    $movedRuntime = $false
    $movedPlugin = $false
    $installedRuntime = $false
    $installedPlugin = $false
    $registeredTask = $false
    $stoppedTask = $false
    $previousTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $previousTaskWasRunning = $previousTask.State -eq 'Running'
    if ($previousTask) { $previousTaskXml = Export-ScheduledTask -TaskName $taskName -TaskPath '\' }
    try {
        foreach ($file in 'package.json','package-lock.json','premiere-shared.mjs','lightroom-hosted.mjs') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $stage
        }
        [IO.File]::WriteAllText((Join-Path $stage 'node-path.txt'), $node)
        Push-Location -LiteralPath $stage
        try {
            & $npm ci --no-audit --no-fund | Out-Host
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
        $launcher = Join-Path $runtime $launcherName
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
            Stop-ScheduledTask -TaskName $taskName -TaskPath '\'
            $stoppedTask = $true
            for ($attempt = 0; $attempt -lt 40; $attempt++) {
                if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Running') { break }
                Start-Sleep -Milliseconds 250
            }
            if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') { throw 'The previous watcher task did not stop.' }
        }
        if (Test-Path -LiteralPath $runtime) {
            [IO.Directory]::Move($runtime, $runtimeBackup)
            $movedRuntime = $true
        }
        [IO.Directory]::Move($stage, $runtime)
        $installedRuntime = $true
        if (Test-Path -LiteralPath $plugin) {
            [IO.Directory]::Move($plugin, $pluginBackup)
            $movedPlugin = $true
        }
        [IO.Directory]::Move($pluginStage, $plugin)
        $installedPlugin = $true

        $principal = New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.User.Value
        $action = New-ScheduledTaskAction -Execute (Join-Path $runtime $watcherName) -WorkingDirectory $runtime
        $options = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $options -Force | Out-Null
        $registeredTask = $true
        Start-ScheduledTask -TaskName $taskName -TaskPath '\'
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') { break }
            Start-Sleep -Milliseconds 250
        }
        if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Running') { throw 'The watcher task did not start.' }
    } catch {
        if ($registeredTask) { Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue }
        if ($installedPlugin) { [IO.Directory]::Move($plugin, $pluginStage) }
        if ($movedPlugin) { [IO.Directory]::Move($pluginBackup, $plugin) }
        if ($installedRuntime) { [IO.Directory]::Move($runtime, $stage) }
        if ($movedRuntime) { [IO.Directory]::Move($runtimeBackup, $runtime) }
        if ($createdSettings) { [IO.File]::Delete($settingsPath) }
        if ($registeredTask) {
            if ($previousTask) {
                Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Xml $previousTaskXml -Force | Out-Null
            } else {
                Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false
            }
        }
        if ($stoppedTask) { Start-ScheduledTask -TaskName $taskName -TaskPath '\' }
        throw
    }

    Write-Host "Installed runtime: $runtime"
    Write-Host "Lightroom plugin: $plugin"
    if ($movedRuntime) { Write-Host "Previous runtime: $runtimeBackup" }
    if ($movedPlugin) { Write-Host "Previous Lightroom plugin: $pluginBackup" }
    Write-Host 'Complete the Adobe connector setup in README.md.'
    Write-Host 'Private MCP config follows. Merge these entries into the existing mcpServers object.'
    $config = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mcp_config.example.json') -Raw | ConvertFrom-Json
    $config.mcpServers.premiere_pro.headers.Authorization = 'Bearer ' + $settings.httpToken
    $config.mcpServers.lightroom_classic.headers.Authorization = 'Bearer ' + $settings.lightroomHttpToken
    $config | ConvertTo-Json -Depth 6
} finally {
    if ($locked) { $lock.ReleaseMutex() }
    $lock.Dispose()
}
