import {securityHeaders} from './web-security-policy.mjs';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
const args=process.argv.slice(2),environment=args[0],port=Number(args[1]??7357);
if(!['live','emulator'].includes(environment)||!Number.isInteger(port)||port<1024||port>65535||args.length>2)throw new Error('Use node scripts/serve-web.mjs live|emulator [port].');
const root=path.resolve('build',environment,'web');
if(!fs.existsSync(path.join(root,'index.html')))throw new Error(`Build the explicit ${environment} web application first with scripts/build-app.ps1.`);
const mime={'.html':'text/html; charset=utf-8','.js':'application/javascript; charset=utf-8','.json':'application/json','.wasm':'application/wasm','.css':'text/css','.png':'image/png','.svg':'image/svg+xml','.ico':'image/x-icon','.woff2':'font/woff2','.ttf':'font/ttf'};
http.createServer((req,res)=>{
 if(!['GET','HEAD'].includes(req.method)){res.writeHead(405);res.end();return;}
 let relative;try{relative=decodeURIComponent(new URL(req.url,'http://localhost').pathname);}catch{res.writeHead(400);res.end();return;}
 let file=path.resolve(root,'.'+relative);
 if(file!==root&&!file.startsWith(root+path.sep)){res.writeHead(403);res.end();return;}
 if(!fs.existsSync(file)||fs.statSync(file).isDirectory())file=path.join(root,'index.html');
 res.writeHead(200,{'Content-Type':mime[path.extname(file)]??'application/octet-stream',...securityHeaders(environment)});
 if(req.method==='HEAD'){res.end();return;}fs.createReadStream(file).pipe(res);
}).listen(port,'127.0.0.1',()=>console.log(`${environment} application: http://localhost:${port} — loopback only; Ctrl+C stops this server.`));
