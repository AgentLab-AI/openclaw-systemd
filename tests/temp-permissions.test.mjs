import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { prepareTempAncestors } from '../rootfs/usr/local/libexec/openclaw-systemd/prepare-temp-ancestors.mjs';
const uid = process.getuid();
function fixture(fn) {
 const root = fs.mkdtempSync(path.join(os.tmpdir(), 'oc-temp-test-'));
 try { fn(root); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}
const mode = p => fs.statSync(p).mode & 0o7777;
test('repairs fsGroup 2775 ancestors; preserves private directories and content; repeatable', () => fixture(home => {
 fs.mkdirSync(path.join(home,'.cache/openclaw'),{recursive:true});
 fs.mkdirSync(path.join(home,'.openclaw/tmp'),{recursive:true});
 for (const p of [home,path.join(home,'.cache'),path.join(home,'.openclaw/tmp')]) fs.chmodSync(p,0o2775);
 fs.chmodSync(path.join(home,'.openclaw'),0o700);
 fs.chmodSync(path.join(home,'.cache/openclaw'),0o700);
 const data=path.join(home,'.openclaw','keep'); fs.writeFileSync(data,'retained'); fs.chmodSync(data,0o640);
 prepareTempAncestors(home,uid); prepareTempAncestors(home,uid);
 for (const p of [home,path.join(home,'.cache'),path.join(home,'.openclaw/tmp')]) assert.equal(mode(p),0o3775);
 assert.equal(mode(path.join(home,'.openclaw')),0o700);
 assert.equal(mode(path.join(home,'.cache/openclaw')),0o700);
 assert.equal(fs.readFileSync(data,'utf8'),'retained'); assert.equal(mode(data),0o640);
 // Simulate another kubelet fsGroup pass.
 fs.chmodSync(home,0o2775); prepareTempAncestors(home,uid); assert.equal(mode(home),0o3775);
}));
test('creates private missing temp directories',()=>fixture(home=>{
 prepareTempAncestors(home,uid);
 for(const p of ['.cache','.cache/openclaw','.openclaw','.openclaw/tmp']) assert.equal(mode(path.join(home,p)),0o700);
}));
test('rejects symlink and dangling symlink without changing target',()=>fixture(home=>{
 const outside=path.join(home,'outside'); fs.mkdirSync(outside); fs.chmodSync(outside,0o775);
 fs.symlinkSync(outside,path.join(home,'.cache'));
 assert.throws(()=>prepareTempAncestors(home,uid),/Refusing/); assert.equal(mode(outside),0o775);
 fs.unlinkSync(path.join(home,'.cache')); fs.symlinkSync(path.join(home,'missing'),path.join(home,'.cache'));
 assert.throws(()=>prepareTempAncestors(home,uid),/Refusing/);
}));
test('rejects non-directory',()=>fixture(home=>{
 fs.writeFileSync(path.join(home,'.cache'),'keep'); assert.throws(()=>prepareTempAncestors(home,uid),/Refusing/);
}));
