import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { registerHooks } from 'node:module';
import { toNodeHandler } from '@modelcontextprotocol/node';
import { createMcpHandler } from '@modelcontextprotocol/server';

const host = '127.0.0.1';
const port = 17779;
const settings = new URL('../settings.json', import.meta.url);
const { lightroomHttpToken } = JSON.parse(await readFile(settings, 'utf8'));
if (!/^[a-f0-9]{64}$/.test(lightroomHttpToken)) throw new Error('Missing Lightroom MCP HTTP token');
const expectedAuthorization = Buffer.from('Bearer ' + lightroomHttpToken);

function authorized(header) {
    const supplied = Buffer.from(header ?? '');
    return supplied.length === expectedAuthorization.length && timingSafeEqual(supplied, expectedAuthorization);
}

globalThis.startLightroomHttp = async (serverFactory) => {
    const handler = createMcpHandler(serverFactory);
    const handleRequest = toNodeHandler(handler);
    const server = createServer((req, res) => {
        res.setHeader('Cache-Control', 'no-store');
        if (req.headers.host !== `${host}:${port}` ||
            (req.headers.origin && req.headers.origin !== `http://${host}:${port}`)) {
            res.writeHead(403).end();
        } else if (req.url !== '/mcp') {
            res.writeHead(404).end();
        } else if (!authorized(req.headers.authorization)) {
            res.writeHead(401, { 'WWW-Authenticate': 'Bearer' }).end();
        } else {
            void handleRequest(req, res).catch((error) => {
                console.error('[Lightroom MCP]', error.message);
                if (!res.headersSent) res.writeHead(500);
                res.end();
            });
        }
    });
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(port, host, resolve);
    });
    process.stdin.once('end', () => {
        server.close();
        server.closeAllConnections();
        void handler.close();
    });
    process.stdin.resume();
};

// Keep the upstream bridge, timeouts and tool definitions. Swap its stdio
// transport at the entry point without modifying the installed npm package.
const entry = new URL('./node_modules/@mskalski/lightroom-mcp/dist/index.js', import.meta.url).href;
const hooks = registerHooks({
    load(url, context, nextLoad) {
        const loaded = nextLoad(url, context);
        if (url !== entry) return loaded;
        const source = Buffer.from(loaded.source).toString('utf8').replaceAll('\r\n', '\n');
        const stdioSetup = [
            '    const server = createMcpServer({ callTool: (name, args, options) => bridge.callTool(name, args, options) }, { toolsets, readOnly });',
            '    server.oninitialized = () => void bridge.start();',
            '    const transport = new StdioServerTransport();',
            '    await server.connect(transport);'
        ].join('\n');
        if (source.split(stdioSetup).length !== 2) throw new Error('Unexpected Lightroom MCP entry point');
        const httpSetup = [
            '    await globalThis.startLightroomHttp(() => createMcpServer(',
            '        { callTool: (name, args, options) => bridge.callTool(name, args, options) },',
            '        { toolsets, readOnly }));',
            '    void bridge.start();'
        ].join('\n');
        return {
            ...loaded,
            source: source.replace(stdioSetup, httpSetup)
                .replace('running on stdio', 'listening on 127.0.0.1:17779')
        };
    }
});
process.env.LIGHTROOM_MCP_TOOLSETS = 'all';
if (process.argv[2] === '--with-app') process.argv.splice(2, 1);
await import(entry);
hooks.deregister();
