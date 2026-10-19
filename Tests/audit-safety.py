"""Exercise emitted Bash with real Linux flock; not SBX/PTY qualification."""
import fcntl
import hashlib
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = pathlib.Path('Sources/AgentCore/GuestBootstrap.swift').read_text()

class AuditSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = pathlib.Path(self.temp.name)
        self.root = self.base / 'audit'
        self.root.mkdir()
        for name in ['session', 'verify']:
            script = SOURCE.split('public static let ' + name + 'Script = #"""')[1].split('"""#')[0]
            (self.base / name).write_text(script.replace('/var/lib/agent-audit', str(self.root)))

    def run_script(self, name, *args):
        return subprocess.run(['bash', str(self.base / name), *args], capture_output=True, text=True, timeout=5)

    def ledger(self, phases):
        previous = '0' * 64
        records = []
        for seq, (session, phase) in enumerate(phases, 1):
            directory = self.root / 'sessions' / 'worker' / session
            directory.mkdir(parents=True, exist_ok=True)
            for name in ['start', 'end', 'exit-code']:
                (directory / name).write_text('0\n')
            names = ['start'] if phase == 'start' else ['start', 'end', 'exit-code']
            manifest = ''.join(hashlib.sha256((directory / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in names)
            prefix = 'start.' if phase == 'start' else ''
            (directory / (prefix + 'manifest.sha256')).write_text(manifest)
            data = f'sequence={seq}\nprevious={previous}\nworker=worker\nsession={session}\nphase={phase}\n' + manifest
            previous = hashlib.sha256(data.encode()).hexdigest()
            (directory / ('start.input' if phase == 'start' else 'chain.input')).write_text(data)
            (directory / (prefix + 'HEAD')).write_text(previous + '\n')
            records.append(f'{seq}\t{previous}\tsessions/worker/{session}\t{phase}\n')
        (self.root / 'chain.log').write_text(''.join(records))
        (self.root / 'HEAD').write_text(previous + '\n')
        (self.root / 'sequence').write_text(str(len(records)) + '\n')

    def test_lock_symlink_never_clobbers_target(self):
        outside = self.base / 'sentinel'
        outside.write_text('unchanged')
        (self.root / 'chain.lock').symlink_to(outside)
        for name, args in [('verify', ['--snapshot']), ('session', ['worker', '/usr/bin/true'])]:
            result = self.run_script(name, *args)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(outside.read_text(), 'unchanged', name)

    def test_empty_worker_rejected(self):
        (self.root / 'sessions' / 'empty').mkdir(parents=True)
        self.assertNotEqual(self.run_script('verify', '--snapshot').returncode, 0)
        self.ledger([('a', 'start'), ('a', 'complete')])
        self.assertNotEqual(self.run_script('verify', '--snapshot').returncode, 0)

    def test_correctly_hashed_overlap_rejected(self):
        self.ledger([('a', 'start'), ('a', 'complete'), ('b', 'start'), ('b', 'complete')])
        self.assertEqual(self.run_script('verify', '--snapshot').returncode, 0)
        self.ledger([('a', 'start'), ('b', 'start'), ('a', 'complete'), ('b', 'complete')])
        self.assertNotEqual(self.run_script('verify', '--snapshot').returncode, 0)

    def test_writer_refuses_existing_directory_lock(self):
        import os
        fd = os.open(self.root, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script('session', 'worker', '/usr/bin/true')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / 'sessions').exists())
        finally:
            os.close(fd)

if __name__ == '__main__':
    unittest.main()
