"""Exercise the real guest archive parser without requiring KVM or Podman."""
import importlib.machinery
import importlib.util
import io
import pathlib
import tarfile
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'guest' / 'export'
loader = importlib.machinery.SourceFileLoader('sim_guest_export', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


def archive(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w') as target:
        for name, content, kind in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.size = len(content) if kind == tarfile.REGTYPE else 0
            if kind == tarfile.SYMTYPE:
                info.linkname = '/etc/passwd'
            target.addfile(info, io.BytesIO(content))
    stream.seek(0)
    return stream


class ExportTests(unittest.TestCase):
    def test_baseline_ignored_files_survive_and_dependencies_are_skipped(self):
        stream = archive([('./tracked.txt', b'updated', tarfile.REGTYPE),
                          ('./node_modules/big', b'dependency', tarfile.REGTYPE),
                          ('./.git/config', b'untrusted', tarfile.REGTYPE)])
        result = module.read_candidate(stream, {'tracked.txt'}, lambda p: True)
        self.assertEqual([f['path'] for f in result['files']], ['tracked.txt'])

    def test_traversal_links_and_size_are_rejected(self):
        for entries in [[('../escape', b'bad', tarfile.REGTYPE)],
                        [('link', b'', tarfile.SYMTYPE)]]:
            with self.assertRaises(ValueError):
                module.read_candidate(archive(entries), set(), lambda p: False)
        with self.assertRaises(ValueError):
            module.read_candidate(archive([('large', b'1234', tarfile.REGTYPE)]), set(), lambda p: False, limit=3)


if __name__ == '__main__':
    unittest.main()
