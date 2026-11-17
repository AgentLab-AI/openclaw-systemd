import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// kubelet fsGroup can add group-write on each PVC attach. Reapply before
// systemd starts Doctor. Keep sharing/setgid; add sticky, never recursive chmod.
export function prepareTempAncestors(home, uid = 1000) {
  const targets = ['', '.cache', '.cache/openclaw', '.openclaw', '.openclaw/tmp'];
  for (const relative of targets) {
    const directory = path.join(home, relative);
    // Walk in parent-first order; never follow a symlink from persisted state.
    if (!fs.existsSync(directory)) {
      // lstat also catches dangling symlinks, which existsSync does not.
      try { fs.lstatSync(directory); throw new Error(`Refusing non-directory ${directory}`); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      fs.mkdirSync(directory, { mode: 0o700 });
      fs.chownSync(directory, uid, uid);
    }
    const before = fs.lstatSync(directory);
    if (!before.isDirectory() || ![0, uid].includes(before.uid)) {
      throw new Error(`Refusing unexpected directory type/owner: ${directory}`);
    }
    const fd = fs.openSync(directory, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW);
    try {
      const current = fs.fstatSync(fd);
      if (before.dev !== current.dev || before.ino !== current.ino) throw new Error(`Directory changed: ${directory}`);
      if ((current.mode & 0o022) && !(current.mode & 0o1000)) {
        fs.fchmodSync(fd, (current.mode & 0o7777) | 0o1000);
        console.log(`temp permissions: added sticky protection to ${directory}`);
      }
    } finally { fs.closeSync(fd); }
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  prepareTempAncestors('/home/openclaw');
}
