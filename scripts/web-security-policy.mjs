// Reviewed FlutterFire script hashes for the pinned JS SDK. No unsafe-inline
// script permission. Re-run browser acceptance after changing SDK/import code.
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const sdkVersion='12.19.0';
const services={core:'app',auth:'auth',firestore:'firestore-pipelines',app_check:'app-check'};
export function flutterFireHashes(){
 return Object.entries(services).flatMap(([name,file])=>{
  const windowVar=`firebase_${name}`,url=`https://www.gstatic.com/firebasejs/${sdkVersion}/firebase-${file}.js`;
  return [
   `            window.ff_trigger_${windowVar} = async (callback) => {\n              console.debug("Initializing Firebase ${windowVar}");\n              callback(await import("${url}"));\n            };\n          `,
   `      window.ff_trigger_${windowVar} = async (callback) => {\n        console.debug("Initializing Firebase ${windowVar}");\n        callback(await import("${url}"));\n      };\n    `,
  ].map(s=>`'sha256-${createHash('sha256').update(s.replaceAll('\\n','\n')).digest('base64')}'`);
 });
}
export function webSecurityPolicy(environment){
 if(!['live','emulator'].includes(environment))throw Error('Explicit web environment required.');
 const services=environment==='emulator'?'http://127.0.0.1:9099 http://127.0.0.1:8080':'https://identitytoolkit.googleapis.com https://securetoken.googleapis.com https://firestore.googleapis.com https://firebaseinstallations.googleapis.com https://firebaseappcheck.googleapis.com';
 return `default-src 'none'; base-uri 'self'; object-src 'none'; script-src 'self' 'wasm-unsafe-eval' ${flutterFireHashes().join(' ')} https://www.gstatic.com/firebasejs/; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data: https://fonts.gstatic.com; worker-src 'self' blob:; frame-src 'none'; form-action 'none'; manifest-src 'self'; connect-src 'self' ${services} https://www.gstatic.com/firebasejs/ https://fonts.gstatic.com;`;
}
export function securityHeaders(environment){return {'Content-Security-Policy':webSecurityPolicy(environment)+" frame-ancestors 'none';",'X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-Frame-Options':'DENY','Permissions-Policy':'camera=(), microphone=(), geolocation=(), payment=()','Cache-Control':'no-store'};}
function verifySdk(){
 const config=JSON.parse(readFileSync(new URL('../.dart_tool/package_config.json',import.meta.url)));
 const pkg=config.packages.find(p=>p.name==='firebase_core_web');
 if(!pkg)throw Error('Resolve Flutter dependencies before preparing CSP.');
 const root=new URL(pkg.rootUri,new URL('../.dart_tool/package_config.json',import.meta.url));
 const source=readFileSync(new URL('lib/src/firebase_sdk_version.dart',root.href.endsWith('/')?root:new URL(root.href+'/')),'utf8');
 if(!source.includes(`supportedFirebaseJsSdkVersion = '${sdkVersion}'`))throw Error('FlutterFire JS SDK changed. Review import templates/hashes and repeat CSP browser acceptance.');
 const implementation=readFileSync(new URL('lib/src/firebase_core_web.dart',root.href.endsWith('/')?root:new URL(root.href+'/')),'utf8');
 const templates=[...implementation.matchAll(/'''([^]*?ff_trigger_\$windowVar[^]*?)'''/g)].map(m=>m[1].replace(/^\r?\n/,'').replaceAll('\r\n','\n').replaceAll('$windowVar','firebase_core').replaceAll('$stringUrl',`https://www.gstatic.com/firebasejs/${sdkVersion}/firebase-app.js`));
 const expected=flutterFireHashes().slice(0,2);
 if(templates.length!==2 || templates.some((s,i)=>`'sha256-${createHash('sha256').update(s).digest('base64')}'`!==expected[i]))throw Error('FlutterFire inline loader changed. Review CSP hashes and repeat browser acceptance.');
}
if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 verifySdk();console.log(webSecurityPolicy(process.argv[2]));
}
