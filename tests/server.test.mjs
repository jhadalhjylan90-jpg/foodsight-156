import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
test('local server serves app, protects APIs and does not serve configuration files',async()=>{
 const proc=spawn(process.execPath,[fileURLToPath(new URL('../server.mjs',import.meta.url))],{env:{...process.env,PORT:'34567',SUPABASE_SECRET_KEY:''},stdio:['ignore','pipe','pipe']});
 try{
 await new Promise((resolve,reject)=>{const t=setTimeout(()=>reject(Error('Server start timeout')),8000);proc.stdout.once('data',()=>{clearTimeout(t);resolve();});proc.once('error',reject);proc.once('exit',c=>{if(c)reject(Error('Server exited '+c));});});
 const base='http://127.0.0.1:34567';const status=await fetch(base+'/api/status').then(r=>r.json());assert.equal(status.configured,false);
 assert.equal((await fetch(base+'/')).status,200);
 for(const p of ['/.env','/config.json','/server.mjs','/database/01-schema.sql'])assert.equal((await fetch(base+p)).status,404);
 assert.equal((await fetch(base+'/api/dashboard',{method:'POST',body:'{}'})).status,403);
 assert.equal((await fetch(base+'/api/dashboard',{method:'POST',headers:{'x-foodsight-token':status.token},body:'{}'})).status,503);
 assert.equal((await fetch(base+'/api/dashboard',{method:'POST',headers:{'x-foodsight-token':status.token,origin:'https://example.com'},body:'{}'})).status,403);
 }finally{proc.kill();}
});
