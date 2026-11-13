import {readFile, writeFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';

const upstream = new URL('./node_modules/premiere-pro-mcp/dist/http-server.js', import.meta.url);
const target = new URL('http-server-shared-local.js', upstream);

if (process.argv.includes('--prepare')) {
    let source = await readFile(upstream, 'utf8');
    function replaceOnce(before, after) {
        if (source.split(before).length !== 2) {
            throw new Error('Unexpected Premiere MCP HTTP entry point. Review the installed version.');
        }
        source = source.replace(before, after);
    }
    replaceOnce('import http from "node:http";', [
        'import http from "node:http";',
        'import { UxpWebSocketBridge } from "./bridge/uxp-websocket-bridge.js";'
    ].join('\n'));
    replaceOnce('const mediaWatchRegistry = new MediaWatchRegistry();', [
        'const mediaWatchRegistry = new MediaWatchRegistry();',
        'const uxpBridge = new UxpWebSocketBridge({ token: process.env.PREMIERE_UXP_TOKEN, tempDir: bridgeOptions.tempDir });'
    ].join('\n'));
    replaceOnce('{ telemetry, contextRepository: projectContextRepository, mediaWatchRegistry, statelessHttp: true }',
        '{ telemetry, contextRepository: projectContextRepository, mediaWatchRegistry, uxpBridge, statelessHttp: true }');
    replaceOnce('httpServer.listen(PORT, HTTP_HOST, () => {',
        'await uxpBridge.start();\nhttpServer.listen(PORT, HTTP_HOST, () => {');
    replaceOnce('await mcpHandler.close();', 'await mcpHandler.close();\n    await uxpBridge.stop();');
    replaceOnce('process.on("SIGTERM", () => void shutdown("SIGTERM"));', [
        'process.on("SIGTERM", () => void shutdown("SIGTERM"));',
        'if (process.argv.includes("--with-app")) {',
        '    process.stdin.once("end", () => void shutdown("Adobe closed"));',
        '    process.stdin.resume();',
        '}'
    ].join('\n'));
    await writeFile(target, source);
} else {
    const {httpToken, uxpToken} = JSON.parse(await readFile(new URL('../settings.json', import.meta.url), 'utf8'));
    if (![httpToken, uxpToken].every(token => typeof token === 'string' && /^[a-f0-9]{64}$/.test(token))) {
        throw new Error('Missing or invalid Premiere MCP credentials');
    }

    Object.assign(process.env, {
        MCP_HTTP_HOST: '127.0.0.1',
        PORT: '17778',
        MCP_AUTH_TOKEN: httpToken,
        PREMIERE_UXP_TOKEN: uxpToken,
        PREMIERE_BRIDGE_MODE: 'auto',
        AFTER_EFFECTS_MCP_TEMP_DIR: fileURLToPath(new URL('../after-effects', import.meta.url)),
        PREMIERE_TEMP_DIR: fileURLToPath(new URL('../cep', import.meta.url))
    });
    delete process.env.POSTHOG_API_KEY;
    for (const key of Object.keys(process.env)) {
        if (key.startsWith('MCP_OAUTH_')) delete process.env[key];
    }
    await import(target.href);
}
