$root = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'AdobeMcp-Premiere'))
$modules = [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'Adobe\Lightroom\Modules'))
$runtime = Join-Path $root 'runtime'
$plugin = Join-Path $modules 'LightroomMCP.lrplugin'
$watcher = Join-Path $runtime 'AdobeMcpProcessWatcher.exe'
$launcher = Join-Path $runtime 'LightroomMcpApp.exe'
$taskName = 'AdobeMCP-Premiere-AppWatcher'
$manifestPath = Join-Path $root 'install-manifest.json'
$configPath = Join-Path $root 'mcp_config.generated.json'
$mutexName = 'Local\AdobeMcpWindowsOnDemand-Install'

function Assert-AdobeClosed {
    $session = (Get-Process -Id $PID).SessionId
    $hosts = Get-Process -Name 'Adobe Premiere Pro','AfterFX','Lightroom' -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $session -and ($_.ProcessName -ne 'AfterFX' -or $_.MainWindowHandle -ne 0) }
    if ($hosts) { throw 'Close Premiere Pro, After Effects and Lightroom Classic before continuing.' }
}

function Test-PathUnder([string] $Path, [string] $Base) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $basePath = [IO.Path]::GetFullPath($Base).TrimEnd('\','/')
    return $full.Equals($basePath, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($basePath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoLinkedPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $trusted = $null
    foreach ($base in $env:LOCALAPPDATA, $env:APPDATA) {
        if ($base -and (Test-PathUnder $full $base)) {
            $basePath = [IO.Path]::GetFullPath($base).TrimEnd('\','/')
            if (!$trusted -or $basePath.Length -gt $trusted.Length) { $trusted = $basePath }
        }
    }
    for ($current = $full; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if ($null -ne $trusted -and $current.TrimEnd('\','/') -ieq $trusted) { break }
        try { $item = Get-Item -LiteralPath $current -Force }
        catch [System.Management.Automation.ItemNotFoundException] { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $current" }
    }
}

function Get-PlainTree([string] $Path) {
    # Check children before descending, including on Windows PowerShell 5.1.
    foreach ($child in Get-ChildItem -LiteralPath $Path -Force) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $($child.FullName)" }
        $child
        if ($child.PSIsContainer) { Get-PlainTree $child.FullName }
    }
}

function Assert-SafeRemovalPath([string] $Path, [switch] $PrivateData) {
    if (!$Path -or ![IO.Path]::IsPathRooted($Path)) { throw "Expected an absolute path: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    $allowed = ($parent -ieq $root -and $leaf -match '^(runtime|runtime-(stage|backup)-[^:]+)$') -or
        ($parent -ieq $modules -and $leaf -match '^(LightroomMCP\.lrplugin|LightroomMCP-(stage|backup)-[^:]+)$')
    if ($PrivateData -and $parent -ieq $root) {
        $allowed = $allowed -or $leaf -match '^(settings\.json|mcp_config\.generated\.json|install-manifest\.json|[^:]+-app-(output|error)\.log[^:]*|cep|after-effects)$'
    }
    if (!$allowed -or $leaf -match '[. ]$' -or $full -ieq $env:USERPROFILE -or $full -ieq $root -or $full -ieq $modules) {
        throw "Unexpected cleanup path: $Path"
    }
    Assert-NoLinkedPath $full
    if (Test-Path -LiteralPath $full -PathType Container) { Get-PlainTree $full | Out-Null }
}

function Get-PluginFiles([string] $Path) {
    Assert-NoLinkedPath $Path
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in Get-PlainTree $Path) {
            if ($file.PSIsContainer -or $file.Name -in 'desktop.ini','Thumbs.db') { continue }
            $stream = [IO.File]::OpenRead($file.FullName)
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
            finally { $stream.Dispose() }
            [ordered]@{ path = $file.FullName.Substring($Path.Length + 1).Replace('\','/'); sha256 = $hash }
        }
    } finally { $sha.Dispose() }
}

function Test-PluginIsOurs([string] $Path, $Recorded) {
    if (!$Recorded -or !@($Recorded.files).Count -or !(Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    try { $actual = @(Get-PluginFiles $Path) }
    catch { Write-Warning "Cannot verify Lightroom plugin: $($_.Exception.Message)"; return $false }
    if ($actual.Count -ne @($Recorded.files).Count) { return $false }
    $hashes = @{}
    foreach ($file in $Recorded.files) {
        if (!$file.path -or $hashes.ContainsKey($file.path) -or $file.sha256 -notmatch '^[a-f0-9]{64}$') { return $false }
        $hashes[$file.path] = $file.sha256
    }
    foreach ($file in $actual) {
        if ($hashes[$file.path] -ine $file.sha256) { return $false }
    }
    return $true
}

function Test-OurHook([string] $Path) {
    $init = Join-Path $Path 'PluginInit.lua'
    Assert-NoLinkedPath $init
    return (Test-Path -LiteralPath $init -PathType Leaf) -and ([IO.File]::ReadAllText($init) -match 'LightroomMcpApp\.exe')
}

function Assert-InstallManifest($Manifest) {
    if ($Manifest.schemaVersion -ne 1 -or $Manifest.runtimePath -ine $runtime -or
        $Manifest.watcherExe -ine $watcher -or $Manifest.launcherExe -ine $launcher -or
        $Manifest.taskName -cne $taskName -or $Manifest.plugin.path -ine $plugin) {
        throw 'The install manifest does not match this Windows profile.'
    }
}

function Write-AtomicText([string] $Path, [string] $Content) {
    Assert-NoLinkedPath $Path
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, $Content, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        try { [IO.File]::Delete($temp) }
        catch { Write-Warning "Temporary file kept: $temp" }
    }
}

function Save-InstallManifest($Manifest) {
    Write-AtomicText $manifestPath ($Manifest | ConvertTo-Json -Depth 12)
}

function Get-WatcherTask {
    try { Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) { throw }
    }
}

function Stop-WatcherTask {
    $task = Get-WatcherTask
    if ($task.State -ne 'Running') { return }
    Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        if ((Get-WatcherTask).State -ne 'Running') { return }
        Start-Sleep -Milliseconds 250
    }
    throw 'The watcher task did not stop.'
}

function Get-OurBridgeProcesses {
    $WhatIfPreference = $false
    $filter = "Name='node.exe' OR Name='AdobeMcpProcessWatcher.exe' OR Name='LightroomMcpApp.exe'"
    $scriptPattern = '(?i)(?:^|[\s"])' + [regex]::Escape($runtime) +
        '\\(?:premiere-shared|lightroom-hosted)\.mjs(?=$|[\s"])'
    foreach ($process in Get-CimInstance Win32_Process -Filter $filter) {
        $exe = ([string]$process.ExecutablePath).Replace('/','\').Trim('"')
        if ($exe -ieq $watcher -or $exe -ieq $launcher) { $process; continue }
        if ($process.Name -ieq 'node.exe' -and ([string]$process.CommandLine).Replace('/','\') -match $scriptPattern) {
            $process
        } elseif ($process.SessionId -eq (Get-Process -Id $PID).SessionId -and
            (($process.Name -ieq 'node.exe' -and !$process.CommandLine) -or ($process.Name -ine 'node.exe' -and !$exe))) {
            Write-Warning "Unable to identify process $($process.ProcessId) ($($process.Name))."
        }
    }
}

function Wait-ForBridgeExit {
    for ($attempt = 0; $attempt -le 40; $attempt++) {
        $remaining = @(Get-OurBridgeProcesses)
        if (!$remaining.Count) { return }
        if ($attempt -lt 40) { Start-Sleep -Milliseconds 250 }
    }
    throw "Adobe MCP processes still running. PIDs: $($remaining.ProcessId -join ', ')"
}
