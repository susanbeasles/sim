import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

// Platform commands are doubled: this suite must never install or require sudo.
for (const kind of ['team', 'bundle', 'valid', 'swap', 'seal', 'destination', 'stage', 'installed', 'symlink', 'config', 'acl', 'staging-private', 'umask'] as const) {
  test(`installer ${['valid', 'staging-private', 'umask'].includes(kind) ? `accepts ${kind}` : `rejects ${kind}`}`, () => {
    const dir = mkdtempSync(join(tmpdir(), 'sim-install-'));
    try {
      const bin = join(dir, 'bin');
      const root = join(dir, 'repo');
      mkdirSync(bin);
      const oldUmask = process.umask(kind === 'umask' ? 0o077 : process.umask());
      for (const path of ['scripts', 'config', 'release/Sim.app/Contents/MacOS', 'release/Sim.app/Contents/_CodeSignature']) mkdirSync(join(root, path), { recursive: true });
      writeFileSync(join(root, 'config/release.env'), kind === 'config' ? 'AGENT_BUNDLE_ID=com.example.sim\n' : 'AGENT_BUNDLE_ID=com.example.sim\nAGENT_TEAM_ID=ABCDEFGHIJ\n');
      writeFileSync(join(root, 'release/Sim.app/Contents/MacOS/sim'), '#!/bin/bash\nexit 0\n');
      chmodSync(join(root, 'release/Sim.app/Contents/MacOS/sim'), 0o755);
      writeFileSync(join(root, 'release/Sim.app/Contents/_CodeSignature/CodeResources'), 'sealed resources');
      process.umask(oldUmask);
      const source = readFileSync(resolve('scripts/install'), 'utf8')
        .replaceAll('/usr/local', join(dir, 'local'));
      writeFileSync(join(root, 'scripts/install'), source);
      const command = (name: string, body: string) => {
        const path = join(bin, name);
        writeFileSync(path, `#!/bin/bash\nset -eu\n${body}\n`);
        chmodSync(path, 0o755);
      };
      command('uname', 'echo Darwin');
      command('codesign', `
if [[ "$*" == *--verify* && "$*" == *--test-requirement* ]]; then
  [[ "$*" == *'identifier "com.example.sim"'* && "$*" == *'subject.OU] = "ABCDEFGHIJ"'* ]] || exit 2
  if [[ "$KIND" == umask && "\${@: -1}" == */libexec/sim/Sim.app ]]; then
    node -e 'const fs=require("fs"), p=process.argv[1]; for (const n of ["", "/Contents", "/Contents/MacOS"]) if ((fs.statSync(p+n).mode & 5)!==5) process.exit(1)' "\${@: -1}"
  fi
  [[ "$KIND" != team && "$KIND" != bundle ]] || exit 1
  if [[ "$KIND" == stage && ( "\${@: -1}" == */.Sim.app.new.* || "\${@: -1}" == */.stage.*/Sim.app ) ]]; then exit 1; fi
  if [[ "$KIND" == installed && "\${@: -1}" == */libexec/sim/Sim.app ]]; then exit 1; fi
fi
`);
      command('xcrun', 'exit 0');
      command('spctl', 'exit 0');
      command('sudo', `
cmd="$1"; shift
case "$cmd" in
  install) /bin/mkdir -p "\${@: -1}"; /bin/chmod 750 "\${@: -1}" ;;
  mkdir) /bin/mkdir "$@" ;;
  ditto) if [[ "$KIND" == staging-private ]]; then
      [[ "$(node -e 'console.log((require("fs").statSync(process.argv[1]).mode & 511).toString(8))' "$(dirname "$2")")" == 700 ]] || exit 97
    fi
    /bin/cp -R "$1" "$2"; if [[ "$KIND" == swap ]]; then echo replacement > "$2/Contents/MacOS/sim"; fi
    if [[ "$KIND" == seal ]]; then echo replacement > "$2/Contents/_CodeSignature/CodeResources"; fi
    if [[ "$KIND" == symlink ]]; then /bin/rm "$2/Contents/MacOS/sim"; /bin/ln -s "$1/Contents/MacOS/sim" "$2/Contents/MacOS/sim"; fi ;;
  chown) exit 0 ;;
  chmod) if [[ "$1" == -RN ]]; then echo stripped >> "$LOG"; else if [[ "$1" == 0755 && "$2" == */.stage.* ]]; then echo exposed >> "$LOG"; fi; /bin/chmod "$@"; fi ;;
  mv) /bin/mv "$@"; if [[ "$KIND" == destination && "$2" == */libexec/sim/Sim.app ]]; then echo replacement > "$2/Contents/MacOS/sim"; fi ;;
  ln) echo promoted >> "$LOG"; /bin/ln "$@" ;;
  rm) /bin/"$cmd" "$@" ;;
  *) exit 98 ;;
esac
`);
      command('ls', 'echo directory; if [[ "$KIND" == acl ]]; then echo " 0: user:fixture allow add_file,delete_child"; fi');
      command('stat', 'if [[ "$2" == %Lp ]]; then echo 755; else echo 0; fi');
      const result = spawnSync('/bin/bash', [join(root, 'scripts/install')], {
        env: { ...process.env, AGENT_RELEASE_ENV: join(root, "config/release.env"), AGENT_BUNDLE_ID: "", AGENT_TEAM_ID: "", PATH: `${bin}:${process.env.PATH}`, KIND: kind, LOG: join(dir, 'log') }, encoding: 'utf8',
      });
      const promoted = (() => { try { return readFileSync(join(dir, 'log'), 'utf8').includes('promoted'); } catch { return false; } })();
      if (['valid', 'staging-private', 'umask'].includes(kind)) { assert.equal(result.status, 0, result.stderr); assert.equal(promoted, true);
        const events = readFileSync(join(dir, 'log'), 'utf8').trim().split('\n');
        assert.ok(events.indexOf('stripped') >= 0);
        assert.ok(events.indexOf('exposed') > events.indexOf('stripped'));
        assert.ok(events.indexOf('promoted') > events.indexOf('exposed'));
      }
      else {
        assert.notEqual(result.status, 0);
        assert.equal(promoted, false, result.stderr);
      }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
