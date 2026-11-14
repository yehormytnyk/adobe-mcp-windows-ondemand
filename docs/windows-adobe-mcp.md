---
trigger: always_on
description: Work with Adobe MCP and Windows UI tools.
---

# Windows and Adobe MCP

The frontmatter is specific to Antigravity.

- Use `premiere_pro` for Premiere Pro and After Effects, and `lightroom_classic` for Lightroom Classic. Give the bridge time to start after Adobe opens, then reconnect the MCP client if needed.
- Verify the target before editing. In Premiere use `verify_premiere_connection` and confirm the project and sequence. In After Effects use `verify_after_effects_connection` and confirm the composition. In Lightroom use `get_selected_photos` and confirm the catalog and selection.
- Prefer Adobe MCP tools for document operations. Use Windows MCP for menus, focus and dialogs. Refresh the window snapshot after navigation or focus changes. Verify the result of each click.
- When using the optional Windows MCP tool, take a fresh `Snapshot` before acting and after a window change, scroll or dialog opening. Prefer the `label` from the current snapshot. For `loc`, use the actual `Screenshot Coordinate Scale` from the response and account for the selected monitor or region bounds. Use `clicks: 1` to select or focus and `clicks: 2` to open an item; verify the result after each click.
- If the user takes control, check `ControlStatus`. Before waiting for the user and when finished with Windows MCP UI work, call `ControlStatus` with `release: true`.
- Before editing in Premiere, verify the source, sequence, tracks, timecode and frame rate. Use a copy of the sequence for trial edits.
- In After Effects, verify the active project and composition. For MOGRT work, verify the saved project, the output file and its import into Premiere.
- Run write commands sequentially. In Lightroom, wait for Develop operations such as Denoise and masking to finish before starting another change.
- Many bridge commands have an internal timeout around 30 seconds. Some long Lightroom and MOGRT operations allow up to 300 seconds. A client can time out earlier. Inspect the project or output file before retrying a write.
- Report the port and error when diagnosing a connection. Keep HTTP and UXP tokens private and out of logs, messages and screenshots.
- Tokens are in `%LOCALAPPDATA%\AdobeMcp-Premiere\settings.json`; launcher logs are in the same folder. Report the connection state, port and error type when diagnosing, never the keys.
