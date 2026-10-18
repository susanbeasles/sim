import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

// Platform commands are doubled: this suite must never install or require sudo.
for (const kind of ['team', 'bundle', 'valid', 'swap', 'seal', 'destination', 'stage', 'installed', 'symlink', 'config'] as const) {
  test(`installer ${kind === 'valid' ? 'accepts expected identity' : `rejects ${kind}`}`, () => {
    const dir = mkdtempSync(join(tmpdir(), 'sim-install-'));
    try {
      const bin = join(dir, 'bin');
      const root = join(dir, 'repo');
      mkdirSync(bin);
      for (const path of ['scripts', 'config', 'release/Sim.app/Contents/MacOS', 'release/Sim.app/Contents/_CodeSignature']) mkdirSync(join(root, path), { recursive: true });
      writeFileSync(join(root, 'config/release.env'), kind === 'config' ? 'AGENT_BUNDLE_ID=com.example.sim\n' : 'AGENT_BUNDLE_ID=com.example.sim\nAGENT_TEAM_ID=ABCDEFGHIJ\n');
      writeFileSync(join(root, 'release/Sim.app/Contents/MacOS/sim'), '#!/bin/bash\nexit 0\n');
      chmodSync(join(root, 'release/Sim.app/Contents/MacOS/sim'), 0o755);
      writeFileSync(join(root, 'release/Sim.app/Contents/_CodeSignature/CodeResources'), 'sealed resources');
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
  [[ "$KIND" != team && "$KIND" != bundle ]] || exit 1
  if [[ "$KIND" == stage && "\${@: -1}" == */.Sim.app.new.* ]]; then exit 1; fi
  if [[ "$KIND" == installed && "\${@: -1}" == */libexec/sim/Sim.app ]]; then exit 1; fi
fi
`);
      command('xcrun', 'exit 0');
      command('spctl', 'exit 0');
      command('sudo', `
cmd="$1"; shift
case "$cmd" in
  install) /bin/mkdir -p "\${@: -1}" ;;
  ditto) /bin/cp -R "$1" "$2"; if [[ "$KIND" == swap ]]; then echo replacement > "$2/Contents/MacOS/sim"; fi
    if [[ "$KIND" == seal ]]; then echo replacement > "$2/Contents/_CodeSignature/CodeResources"; fi
    if [[ "$KIND" == symlink ]]; then /bin/rm "$2/Contents/MacOS/sim"; /bin/ln -s "$1/Contents/MacOS/sim" "$2/Contents/MacOS/sim"; fi ;;
  chown|chmod) exit 0 ;;
  mv) /bin/mv "$@"; if [[ "$KIND" == destination && "$2" == */libexec/sim/Sim.app ]]; then echo replacement > "$2/Contents/MacOS/sim"; fi ;;
  ln) echo promoted >> "$LOG"; /bin/ln "$@" ;;
  rm) /bin/"$cmd" "$@" ;;
  *) exit 98 ;;
esac
`);
      command('stat', 'if [[ "$2" == %Lp ]]; then echo 755; else echo 0; fi');
      const result = spawnSync('/bin/bash', [join(root, 'scripts/install')], {
        env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, KIND: kind, LOG: join(dir, 'log') }, encoding: 'utf8',
      });
      const promoted = (() => { try { return readFileSync(join(dir, 'log'), 'utf8').includes('promoted'); } catch { return false; } })();
      if (kind === 'valid') { assert.equal(result.status, 0, result.stderr); assert.equal(promoted, true); }
      else {
        assert.notEqual(result.status, 0);
        assert.equal(promoted, false, result.stderr);
      }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
}
