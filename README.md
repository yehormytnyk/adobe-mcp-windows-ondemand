# Adobe MCP on demand for Windows

Run local Model Context Protocol (MCP) servers for Adobe Premiere Pro, After Effects and Lightroom Classic when you open those apps. Antigravity, Codex, Cursor and other Streamable HTTP clients can share the same two endpoints without launching their own copy of either Adobe server.

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

The installer runs `npm ci`, prepares the pinned Premiere HTTP entry point, compiles both launchers with Windows' .NET Framework `csc.exe`, copies the pinned Lightroom plug-in and applies the Lua hook, registers `\AdobeMCP-Premiere-AppWatcher` and starts it. Keep the printed client JSON private. The installer preserves existing valid tokens and keeps copies of the previous runtime and Lightroom plug-in when reinstalling.

### Finish setup inside Adobe

Use the installed dependencies in the following examples:

```powershell
$base = Join-Path $env:LOCALAPPDATA 'AdobeMcp-Premiere'
$cli = Join-Path $base 'runtime\node_modules\premiere-pro-mcp\dist\index.js'
```

1. **Premiere Pro 25.6+.** Install the signed `.ccx` from the [Premiere MCP v1.30.0 release](https://github.com/leancoderkavy/premiere-pro-mcp/releases/tag/v1.30.0) using Creative Cloud. In Premiere, open **Window → UXP Plugins → MCP for Adobe Premiere Pro**. Connect to `ws://127.0.0.1:7777/uxp` with `uxpToken` from the local settings file. Choose the workspace folder when prompted.
2. **Premiere CEP.** Use the signed `MCPBridgeCEP.zxp` from the release or follow the [upstream CEP installation instructions](https://github.com/leancoderkavy/premiere-pro-mcp#cep-connector). Open **Window → Extensions → MCP for Adobe Premiere Pro** and set the bridge directory to `%LOCALAPPDATA%\AdobeMcp-Premiere\cep`, expanding the variable before entering it. Save and start the connector. Use this for CEP-only tools or Premiere versions without UXP.
3. **After Effects.** Follow the [upstream After Effects connector instructions](https://github.com/leancoderkavy/premiere-pro-mcp#after-effects-mogrt-studio), including the CEP requirements for your host. With After Effects closed, the bundled installer command is `node $cli --install-after-effects-cep`. Version 1.30.0 installs the upstream development CEP bundle for this host and enables Adobe CEP's per-user `PlayerDebugMode` to load it. If you already have a working signed connector, use it. Launch After Effects, open **Window → Extensions → MCP for Adobe After Effects**, and set the bridge directory to the expanded `%LOCALAPPDATA%\AdobeMcp-Premiere\after-effects`. Save and start the connector. Check **Preferences → Scripting & Expressions → Allow Scripts to Write Files and Access Network** if the panel cannot write files. Keep the panel available if it does not reconnect by itself.
4. **Lightroom Classic.** In **File → Plug-in Manager**, check that **Lightroom MCP** is installed and enabled, with its server auto-start enabled. If the plug-in is missing, click **Add** and select `%APPDATA%\Adobe\Lightroom\Modules\LightroomMCP.lrplugin` with the variable expanded. Reload or reopen Lightroom after enabling the plug-in.

### Configure the MCP clients

Open Adobe before reconnecting the corresponding server in your client. Merge the installer's printed entries into Antigravity's `mcpServers` object, typically in `%USERPROFILE%\.gemini\config\mcp_config.json`. The [example JSON](mcp_config.example.json) uses placeholders. In Cursor's MCP JSON, use `url` in place of `serverUrl` and keep the same `headers` object. For Codex, use the following entries in your local `config.toml`, substituting the corresponding keys from settings:

```toml
[mcp_servers.premiere_pro]
url = "http://127.0.0.1:17778/mcp"
http_headers = { Authorization = "Bearer YOUR_GENERATED_TOKEN_HERE" }

[mcp_servers.lightroom_classic]
url = "http://127.0.0.1:17779/mcp"
http_headers = { Authorization = "Bearer YOUR_GENERATED_TOKEN_HERE" }
```

After Effects uses the `premiere_pro` entry. Windows MCP is optional for UI interaction and is installed separately. The [Windows and Adobe working rules](docs/windows-adobe-mcp.md) can be installed as an Antigravity rule.

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

## Credentials and license

Both HTTP endpoints bind to loopback and require separate bearer tokens. The Premiere UXP socket uses a third token. The installer generates each from 32 cryptographically random bytes. Lightroom also manages its own plug-in socket token. Keep the generated settings, client configs and console output private. Anyone with access to a client token on this computer can invoke the tools allowed by that server.

The Windows integration is [MIT licensed](LICENSE). The copied Lightroom Lua files retain their [upstream MIT notice](lightroom/LICENSE.upstream); the installed dependencies and Adobe connectors have their own license notices.
