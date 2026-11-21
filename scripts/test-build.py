#!/usr/bin/env python3
"""Test build paths and failure cleanup without apt, sudo privileges or mounts."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRATCH = REPO / "workspace/build/tmp"

BUILD_STUB = '''#!/bin/bash
set -eu
flavor=${0##*build-}
flavor=${flavor%.sh}
mkdir -p "$SIRIUS_WORK/debian-trixie-$flavor"
echo "$SIRIUS_WORK" > "$TEST_TRACE/work"
echo "${TMPDIR-unset}" > "$TEST_TRACE/build-tmpdir"
echo "build-$flavor"
[ "${TEST_FAIL-}" != build ] || exit 42
'''
PACK_STUB = '''#!/bin/bash
set -eu
test -d "$1"
echo "$TMPDIR" > "$TEST_TRACE/pack-tmpdir"
echo "pack"
[ "${TEST_FAIL-}" != pack ] || exit 43
echo image > "$2/$3.simg"
'''
PACK_TOOL = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
trace = Path(os.environ['TEST_TRACE'])
with (trace / 'calls').open('a') as f:
    f.write(json.dumps([name, args]) + '\\n')
if name == 'truncate':
    Path(args[-1]).write_text('raw')
elif name == 'mount':
    (trace / 'mounted').write_text(args[-1])
elif name == 'umount':
    if os.environ.get('TEST_FAIL') == 'umount': sys.exit(9)
    (trace / 'mounted').unlink()
elif name == 'cp' and os.environ.get('TEST_FAIL') == 'copy':
    sys.exit(7)
elif name == 'img2simg':
    if os.environ.get('TEST_FAIL') == 'image': sys.exit(8)
    Path(args[1]).write_text('image')
'''


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class BuildTests(unittest.TestCase):
    def run_build(self, *args, fail='', mount='', as_root=False):
        with tempfile.TemporaryDirectory(prefix='build-cli-', dir=SCRATCH) as name:
            root = Path(name)
            bin_dir = root / 'bin'
            trace = root / 'trace'
            for d in (bin_dir, trace, root / 'rootfs', root / 'scratch/base'):
                d.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / 'build.sh', root / 'build.sh')
            for flavor in ('gnome', 'server'):
                executable(root / f'rootfs/build-{flavor}.sh', BUILD_STUB)
            executable(root / 'rootfs/pack-image.sh', PACK_STUB)
            executable(bin_dir / 'sudo', '#!/bin/sh\nexec "$@"\n')
            executable(bin_dir / 'uname', '#!/bin/sh\necho aarch64\n')
            executable(bin_dir / 'id', '''#!/bin/sh
if [ "$1" = -u ] && [ "$TEST_AS_ROOT" = 1 ]; then echo 0
else exec /usr/bin/id "$@"; fi
''')
            executable(bin_dir / 'findmnt', '''#!/bin/sh
case "$TEST_MOUNT" in
  child) echo "$SIRIUS_WORK/debian-trixie-gnome/dev" ;;
  root) echo "$SIRIUS_WORK" ;;
  error) exit 1 ;;
  *) echo / ;;
esac
''')
            env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}',
                       SCRATCH=str(root / 'scratch'), OUT_DIR=str(root / 'images'),
                       SIRIUS_BASE=str(root / 'scratch/base'), TAG='test',
                       TEST_TRACE=str(trace), TEST_FAIL=fail, TEST_MOUNT=mount,
                       TEST_AS_ROOT=str(int(as_root)))
            for key in ('SIRIUS_WORK', 'TMPDIR', 'SUDO_UID', 'SUDO_GID'):
                env.pop(key, None)
            result = subprocess.run(['bash', str(root / 'build.sh'), *args], env=env,
                                    capture_output=True, text=True, timeout=10)
            work_file = trace / 'work'
            work = Path(work_file.read_text().strip()) if work_file.exists() else None
            log_files = list((root / 'scratch').glob('logs/*.log'))
            report = dict(result=result, work=work,
                          retained=work.exists() if work else False,
                          build_tmp=(trace / 'build-tmpdir').read_text().strip() if work else None,
                          pack_tmp=(trace / 'pack-tmpdir').read_text().strip()
                          if (trace / 'pack-tmpdir').exists() else None,
                          logs=[p.read_text() for p in log_files],
                          images=[p.name for p in (root / 'images').glob('*.simg')])
            # Failure/leftover-mount tests deliberately retain a directory;
            # mocks never mount anything, so only our own fixture is removed.
            if work and work.parent == Path('/tmp') and work.name.startswith('sirius-rootfs.'):
                if work.exists():
                    shutil.rmtree(work)
            return report

    def test_default_tmp_builds_both_flavors_and_cleans_work(self):
        for flavor in ('gnome', 'server'):
            with self.subTest(flavor=flavor):
                r = self.run_build(f'rootfs-{flavor}')
                self.assertEqual(r['result'].returncode, 0, r['result'].stderr)
                self.assertEqual(r['work'].parent, Path('/tmp'))
                self.assertFalse(r['retained'])
                self.assertEqual(r['build_tmp'], 'unset')
                self.assertEqual(r['pack_tmp'], str(r['work'] / 'tmp'))
                self.assertEqual(r['images'], [f'debian-trixie-sirius-{flavor}-test.simg'])
                self.assertIn('pack', r['logs'][0])

    def test_no_tmp_before_or_after_target_retains_workspace(self):
        for args in [('--no-tmp', 'rootfs-gnome'), ('rootfs-server', '--no-tmp')]:
            with self.subTest(args=args):
                r = self.run_build(*args)
                self.assertEqual(r['result'].returncode, 0, r['result'].stderr)
                self.assertEqual(r['work'].name, 'rootfs')
                self.assertEqual(r['work'].parent.name, 'scratch')
                self.assertTrue(r['retained'])

    def test_explicit_tmp_overrides_previous_option(self):
        r = self.run_build('--no-tmp', 'rootfs-gnome', '--tmp')
        self.assertEqual(r['result'].returncode, 0, r['result'].stderr)
        self.assertEqual(r['work'].parent, Path('/tmp'))
        self.assertFalse(r['retained'])

    def test_failure_retains_work_and_logs(self):
        for failure, code in [('build', 42), ('pack', 43)]:
            with self.subTest(failure=failure):
                r = self.run_build('rootfs-gnome', fail=failure)
                self.assertEqual(r['result'].returncode, code, r['result'].stderr)
                self.assertTrue(r['retained'])
                self.assertTrue(r['logs'])
                self.assertEqual(r['images'], [])
                self.assertIn(str(r['work']), r['result'].stderr)

    def test_mount_or_unreadable_mount_table_prevents_cleanup(self):
        for mount in ('child', 'root', 'error'):
            with self.subTest(mount=mount):
                r = self.run_build('rootfs-gnome', mount=mount)
                self.assertEqual(r['result'].returncode, 0, r['result'].stderr)
                self.assertTrue(r['retained'])
                self.assertIn('保留', r['result'].stderr)

    def test_sudo_entry_drops_host_tmpdir(self):
        r = self.run_build('rootfs-gnome', as_root=True)
        self.assertEqual(r['result'].returncode, 0, r['result'].stderr)
        self.assertEqual(r['build_tmp'], 'unset')

    def test_help_and_invalid_arguments_do_not_start_build(self):
        for args, code in [(('--help',), 0), (('--invalid',), 2),
                           (('rootfs-gnome', 'rootfs-server'), 2)]:
            with self.subTest(args=args):
                r = self.run_build(*args)
                self.assertEqual(r['result'].returncode, code)
                self.assertIsNone(r['work'])


class PackTests(unittest.TestCase):
    def test_pack_paths_and_cleanup_on_failures(self):
        for failure, code in [('', 0), ('copy', 7), ('image', 8), ('umount', 9)]:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(
                    prefix='build-pack-', dir=SCRATCH) as name:
                root = Path(name)
                for d in ('bin', 'tree', 'output', 'tmp', 'trace'):
                    (root / d).mkdir()
                for tool in ('truncate', 'mkfs.f2fs', 'mount', 'umount', 'cp',
                             'fsck.f2fs', 'img2simg'):
                    executable(root / 'bin' / tool, PACK_TOOL)
                executable(root / 'bin/sudo', '#!/bin/sh\nexec "$@"\n')
                env = dict(os.environ, PATH=f'{root / "bin"}:{os.environ["PATH"]}',
                           TMPDIR=str(root / 'tmp'), TEST_TRACE=str(root / 'trace'),
                           TEST_FAIL=failure)
                result = subprocess.run(['bash', str(REPO / 'rootfs/pack-image.sh'),
                                         str(root / 'tree'), str(root / 'output'), 'test'],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, code, result.stderr)
                calls = [json.loads(line) for line in (root / 'trace/calls').read_text().splitlines()]
                raw = Path(next(args[-1] for cmd, args in calls if cmd == 'truncate'))
                self.assertEqual(raw.parent.parent, root / 'tmp')
                self.assertEqual((root / 'output/test.simg').exists(), not failure)
                if failure == 'umount':
                    self.assertTrue(raw.exists())
                    self.assertTrue((root / 'trace/mounted').exists())
                else:
                    self.assertFalse(raw.parent.exists())
                    self.assertFalse((root / 'trace/mounted').exists())


if __name__ == '__main__':
    SCRATCH.mkdir(parents=True, exist_ok=True)
    unittest.main()
