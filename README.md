# Adobe MCP on demand for Windows

[![Adobe MCP servers run only when Adobe is open](https://img.shields.io/badge/%F0%9F%8C%B1_Adobe_MCP-Runs_only_when_Adobe_is_open-2e7d32)](#how-it-works)

Run local Model Context Protocol (MCP) servers for Adobe Premiere Pro, After Effects and Lightroom Classic when you open those apps. Antigravity, Codex, Cursor and other Streamable HTTP clients can share the same two endpoints without launching their own copy of either Adobe server.

## Quick Start

1. Clone the repository and enter its directory.

   ```powershell
   git clone https://github.com/yehormytnyk/adobe-mcp-windows-ondemand.git
   cd adobe-mcp-windows-ondemand
   ```

2. Close Premiere Pro, After Effects and Lightroom Classic, then run `.\install.ps1` in PowerShell. See [Install](#install) for prerequisites and [Finish setup inside Adobe](#finish-setup-inside-adobe) for the in-app connectors.
3. Merge the entries and tokens from the generated private JSON file into Antigravity's MCP configuration. In Cursor, rename `serverUrl` to `url`. In Codex, put the same URLs and tokens in `config.toml` using the [client examples](#configure-the-mcp-clients).

This independent Windows integration builds on [Premiere Pro MCP](https://github.com/leancoderkavy/premiere-pro-mcp) 1.30.0 and [Lightroom MCP](https://github.com/Automaat/lightroom-mcp) 0.27.0, distributed as [`@mskalski/lightroom-mcp`](https://www.npmjs.com/package/@mskalski/lightroom-mcp). It requires a local Adobe installation and the corresponding in-app connectors.

## How it works

| When you open | What starts | What the client uses |
| --- | --- | --- |
| Premiere Pro or interactive After Effects | One shared Node.js server | `http://127.0.0.1:17778/mcp` |
| Lightroom Classic | The Lua plug-in launches its own Node.js server | `http://127.0.0.1:17779/mcp` |

Windows Task Scheduler starts a small, hidden, per-user C# watcher at logon. It listens for Windows process-start events and also checks periodically to handle delayed window creation and systems where WMI subscriptions are restricted. Closing Premiere and After Effects stops their shared server. Closing Lightroom stops its server and its launcher. With all three apps closed, only the watcher remains.

The watcher checks the interactive session and requires a main window for `AfterFX.exe`. Dynamic Link processes such as `aerendercore.exe` and `dynamiclinkmanager.exe` do not start or keep the shared server alive. The upstream After Effects CEP connector also checks the render-engine state before consuming commands.

Premiere UXP connects over `ws://127.0.0.1:7777/uxp`. Premiere CEP and After Effects CEP use separate local folders. Lightroom's Lua plug-in uses loopback sockets on ports 58763 and 58764. Multiple MCP clients can connect, but they share the open Adobe documents. Coordinate document changes and run Lightroom Develop operations sequentially.

## Install

Use an interactive Windows 10 or 11 session with .NET Framework, PowerShell 5.1 or later, Node.js 24 LTS or later with npm on PATH, and the Adobe apps you use. Extract or clone this repository, close the Adobe apps, and run from the repository directory:

```powershell
.\install.ps1
```

The installer runs `npm ci --ignore-scripts`, prepares the pinned Premiere HTTP entry point, compiles both launchers with Windows' .NET Framework `csc.exe`, copies the pinned Lightroom plug-in and applies the Lua hook, registers `\AdobeMCP-Premiere-AppWatcher` and starts it. Client configuration is saved to `%LOCALAPPDATA%\AdobeMcp-Premiere\mcp_config.generated.json`. Keep it private. Use `-PrintConfig` to also print it. The installer preserves existing valid tokens and keeps copies of the previous runtime and Lightroom plug-in when reinstalling.

The generated tokens are also in `%LOCALAPPDATA%\AdobeMcp-Premiere\settings.json`, so if the client config could not be written you can still read them there.

If script execution is restricted, run `powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1`. For a downloaded ZIP you trust, run `Unblock-File` on it before extracting.

### Finish setup inside Adobe

Use the installed dependencies in the following examples:

```powershell
$base = Join-Path $env:LOCALAPPDATA 'AdobeMcp-Premiere'
$cli = Join-Path $base 'runtime\node_modules\premiere-pro-mcp\dist\index.js'
```

1. **Premiere Pro 25.6+.** Install the signed `.ccx` from the [Premiere MCP v1.30.0 release](https://github.com/leancoderkavy/premiere-pro-mcp/releases/tag/v1.30.0) using Creative Cloud. In Premiere, open **Window → UXP Plugins → MCP for Adobe Premiere Pro**. Connect to `ws://127.0.0.1:7777/uxp` with `uxpToken` from the local settings file. Choose the workspace folder when prompted.
2. **Premiere CEP.** Use the signed `MCPBridgeCEP.zxp` from the release or follow the [upstream CEP installation instructions](https://github.com/leancoderkavy/premiere-pro-mcp#2-install-the-premiere-bridge). Open **Window → Extensions → MCP for Adobe Premiere Pro** and set the bridge directory to `%LOCALAPPDATA%\AdobeMcp-Premiere\cep`, expanding the variable before entering it. Save and start the connector. Use this for CEP-only tools or Premiere versions without UXP.
3. **After Effects.** Follow the [upstream After Effects connector instructions](https://github.com/leancoderkavy/premiere-pro-mcp#after-effects-mogrt-studio), including the CEP requirements for your host. With After Effects closed, the bundled installer command is `node $cli --install-after-effects-cep`. Version 1.30.0 installs the upstream development CEP bundle for this host and enables Adobe CEP's per-user `PlayerDebugMode` to load it. If you already have a working signed connector, use it. Launch After Effects, open **Window → Extensions → MCP for Adobe After Effects**, and set the bridge directory to the expanded `%LOCALAPPDATA%\AdobeMcp-Premiere\after-effects`. Save and start the connector. Check **Preferences → Scripting & Expressions → Allow Scripts to Write Files and Access Network** if the panel cannot write files. Keep the panel available if it does not reconnect by itself.
4. **Lightroom Classic.** In **File → Plug-in Manager**, check that **Lightroom MCP** is installed and enabled, with its server auto-start enabled. If the plug-in is missing, click **Add** and select `%APPDATA%\Adobe\Lightroom\Modules\LightroomMCP.lrplugin` with the variable expanded. Reload or reopen Lightroom after enabling the plug-in.

### Configure the MCP clients

Open Adobe before reconnecting the corresponding server in your client. Merge the generated entries into Antigravity's `mcpServers` object, typically in `%USERPROFILE%\.gemini\config\mcp_config.json`. The [example JSON](mcp_config.example.json) uses placeholders. In Cursor's MCP JSON, use `url` in place of `serverUrl` and keep the same `headers` object. For Codex, use the following entries in your local `config.toml`, substituting the corresponding keys from settings:

```toml
[mcp_servers.premiere_pro]
url = "http://127.0.0.1:17778/mcp"
http_headers = { Authorization = "Bearer YOUR_GENERATED_TOKEN_HERE" }

[mcp_servers.lightroom_classic]
url = "http://127.0.0.1:17779/mcp"
http_headers = { Authorization = "Bearer YOUR_GENERATED_TOKEN_HERE" }
```

After Effects uses the `premiere_pro` entry. Windows MCP is optional for UI interaction and is installed separately. The [Windows and Adobe working rules](docs/windows-adobe-mcp.md) can be installed as an Antigravity rule.

### Claude Code (not yet verified against this server)

```powershell
claude mcp add --transport http premiere_pro http://127.0.0.1:17778/mcp --header "Authorization: Bearer YOUR_GENERATED_TOKEN_HERE"
claude mcp add --transport http lightroom_classic http://127.0.0.1:17779/mcp --header "Authorization: Bearer YOUR_GENERATED_TOKEN_HERE"
```

## Uninstall

Close Adobe and preview with `.\uninstall.ps1 -WhatIf`. Run `.\uninstall.ps1` to remove the recorded installation. The script compares the full Lightroom plug-in file list with the install manifest before removing the plug-in or restoring an eligible external backup. If the task was changed or a bridge is still running, the runtime stays in place. Resolve the reported problem and rerun to resume.

By default, settings, generated client JSON and logs are kept. `-RemoveAll` also removes those files and the bridge exchange directories, and removes the installation directory if empty. Other files and unused Lightroom backups are kept. CEP, UXP and Adobe's `PlayerDebugMode` are managed separately. Remove the Adobe MCP entries from your client configs separately if desired.

## Verify and recover

| Check | What to look for |
| --- | --- |
| Premiere | Run `verify_premiere_connection`. Confirm the connector, project and active sequence. For CEP specifically, pass `backend: "cep"`. |
| After Effects | Open the interactive app and run `verify_after_effects_connection` via `premiere_pro`. For a standalone test, close Premiere first. |
| Lightroom | Select photos and run `get_selected_photos`. An empty selection is valid. |
| Idle behavior | Quit Premiere and After Effects and check that 17778 and 7777 stop listening. Quit Lightroom and check 17779, 58763 and 58764. |

After an Adobe update, confirm the corresponding UXP, CEP or Lightroom plug-in is still installed and enabled. Restore the release's signed Premiere packages if necessary, reinstall the After Effects connector from the pinned dependency and reselect the corresponding bridge directory in each CEP panel. Re-enter the existing UXP token if its configuration was reset. If Lightroom loses its hook or the runtime needs repair, close the Adobe apps and rerun `install.ps1`. Reopen each app and repeat the read-only checks.

Use Task Scheduler to inspect `\AdobeMCP-Premiere-AppWatcher` and confirm its action points to the installed runtime. `Connection refused` is expected while a host is closed. If it persists after launch, check the watcher (Premiere/After Effects) or the Lua plug-in (Lightroom). HTTP 401 means the client credentials need checking. When HTTP connects but the Adobe tool fails, check the in-app connector and the active document.

| Location | Contents |
| --- | --- |
| `%LOCALAPPDATA%\AdobeMcp-Premiere\runtime` | JS wrappers, npm packages, the locally built EXEs and the recorded Node.js executable path |
| `%LOCALAPPDATA%\AdobeMcp-Premiere` | Private `settings.json`, launcher output and error logs, `cep` and `after-effects` exchange folders |
| `%APPDATA%\Adobe\CEP\extensions` | Per-user CEP panels when installed to the user scope |
| `%APPDATA%\Adobe\Lightroom\Modules\LightroomMCP.lrplugin` | Lightroom Classic plug-in with the installed Lua hook |

## Repository structure

```text
.
|-- .gitignore                  Keeps generated binaries, logs and private configs out of Git
|-- LICENSE                     MIT license for this integration
|-- README.md                   Installation, client configuration and recovery
|-- install.ps1                 Installs packages, builds launchers and registers the watcher
|-- uninstall.ps1               Removes the recorded installation
|-- package.json                Declares pinned Node.js dependencies
|-- package-lock.json           Locks the dependency tree for npm ci
|-- premiere-shared.mjs         Runs the shared Premiere Pro and After Effects HTTP server
|-- lightroom-hosted.mjs        Serves the Lightroom Classic bridge over HTTP
|-- mcp_config.example.json     Client endpoint and authorization template
|-- settings.example.json       Local HTTP and UXP token template
|-- src/
|   `-- AdobeMcpAppLauncher.cs   Source for the watcher and the Lightroom launcher
|-- lib/
|   `-- installer.ps1           Shared safety and ownership checks
|-- docs/
|   `-- windows-adobe-mcp.md     Antigravity rules for Adobe work and Windows UI control
`-- lightroom/
    |-- Info.lua                Lightroom plug-in manifest
    |-- PluginInit.lua          Installs the bridge startup hook when the plug-in loads
    |-- PluginShutdown.lua      Closes the Lua plug-in bridge
    `-- LICENSE.upstream        Upstream MIT notice for the Lua files
```

## Privacy

Both HTTP endpoints bind to loopback and require separate bearer tokens. The Premiere UXP socket uses a third token. The installer generates each from 32 cryptographically random bytes. Lightroom also manages its own plug-in socket token. Keep the generated settings, client configs and console output private. Anyone with access to a client token on this computer can invoke the tools allowed by that server.

The Premiere server's PostHog telemetry is disabled because the wrapper clears `POSTHOG_API_KEY`, which the pinned upstream server requires to enable it. The upstream Lightroom plug-in stores its socket token at `%USERPROFILE%\.config\lightroom-mcp\token` and its log at `Documents\LrClassicLogs\LightroomMCP.log`. Uninstall keeps these upstream files. If no other Lightroom MCP installation needs them, close Lightroom and delete them manually from those locations.

## Tested on

### Installer verified in isolation

- Windows PowerShell 5.1 with redirected AppData directories and a temporary scheduled task. Verified installation, reinstallation, rollback, uninstall preview, backup restoration and uninstall retry.

### Verified inside Adobe (Premiere / After Effects / Lightroom Classic)

- Windows 11 Pro, build 26300; Windows PowerShell 5.1. Verified an upgrade over the previous installation, preserving existing tokens and client configs.
- Premiere Pro 27.0.0 (build 88): opening the app started the shared bridge; the read-only UXP connection check confirmed an open project and active sequence.
- After Effects 27.0x78: opening AE with Premiere closed started the shared bridge; the read-only connection check succeeded with an empty, unsaved project.
- Lightroom Classic 16.0: opening the app started its bridge; `get_selected_photos` returned the current selection.
- Closing AE and Lightroom stopped their servers and freed ports 17778, 7777, 17779, 58763 and 58764. A separate Premiere open/close cycle also stopped its server. Only the watcher remained while all three apps were closed.
- These checks cover startup, read-only connectivity and shutdown. Editing, rendering, a Windows reboot and production uninstallation were not tested in this pass.

## Known limitations

- Installations created before the manifest require reinstalling before the uninstaller can verify ownership.
- Interactive After Effects needs a main window. Adobe panels and MCP client configuration are set up separately.

## Contributing

Keep PowerShell scripts compatible with Windows PowerShell 5.1 and the launcher source compatible with C# 5 for the in-box `csc.exe`.

## License

The Windows integration is [MIT licensed](LICENSE). The copied Lightroom Lua files retain their [upstream MIT notice](lightroom/LICENSE.upstream); the installed dependencies and Adobe connectors have their own license notices.
