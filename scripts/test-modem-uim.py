#!/usr/bin/env python3
"""Exercise the real UIM script with fake QMI/systemd; never access a device."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "glue/scripts/sirius-modem-uim"
SCRATCH = REPO / "workspace/build/tmp"

MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ["MODEM_TEST_ROOT"])
c = json.loads((p / "case.json").read_text())
cmd = Path(sys.argv[0]).name
args = sys.argv[1:]
with (p / "calls.jsonl").open("a") as f:
    f.write(json.dumps([cmd, args]) + "\n")
if cmd == "qmicli":
    if "--uim-get-card-status" in args:
        if c.get("unready"):
            now = int((p / "uptime").read_text().split(".")[0])
            (p / "uptime").write_text(f"{now + 9}.00 0.00\n")
            print("error: QMI Internal"); sys.exit(1)
        primary = "session doesn't exist" if c.get("new_session") else "slot '1', application '2'"
        state = "absent" if c.get("absent") else "present"
        print(f"Primary GW:   {primary}\nSlot [1]:\n\tCard state: '{state}'")
        print("\tApplication type:  'usim (2)'\n\tApplication ID:\n\t\tA0:00:00:00:87:10:02:FF")
    elif "--dms-get-operating-mode" in args:
        if c.get("mode_error"): sys.exit(1)
        print("Mode: 'online'")
elif cmd == "systemctl":
    if args[0] == "is-active": sys.exit(0 if c.get("active", True) else 3)
    if "SubState" in args: print(c.get("sub", "running"))
    elif "ActiveEnterTimestampMonotonic" in args: print(c.get("started", 10000000))
elif cmd == "mmcli":
    if "-L" in args:
        if c.get("list_error"): sys.exit(1)
        if c.get("object"):
            print("/org/freedesktop/ModemManager1/Modem/3 [QUALCOMM] 0")
        else: print("No modems were found")
    else:
        if c.get("info_error"): sys.exit(1)
        print("modem.generic.state-failed-reason : " + c.get("failure", "--"))
elif cmd == "uimsel": print("SUCCESS")
elif cmd == "sleep":
    now = int((p / "uptime").read_text().split(".")[0])
    (p / "uptime").write_text(f"{now + int(args[0])}.00 0.00\n")
elif cmd == "date":
    print("wall-clock access is forbidden in this test", file=sys.stderr); sys.exit(99)
'''


class RecoveryTests(unittest.TestCase):
    def run_case(self, config, *, twice=False):
        with tempfile.TemporaryDirectory(prefix="test-modem-", dir=SCRATCH) as name:
            p = Path(name)
            (p / "bin").mkdir()
            (p / "run").mkdir()
            (p / "case.json").write_text(json.dumps(config))
            (p / "uptime").write_text(f"{config.get('now', 30)}.00 0.00\n")
            mock = p / "mock.py"
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for cmd in ["qmicli", "systemctl", "mmcli", "uimsel", "sleep", "date"]:
                (p / "bin" / cmd).symlink_to(mock)
            if "stamp" in config:
                (p / "run/sirius-modem-uim.monotonic").write_text(str(config["stamp"]))
            # Redirect paths in a temporary copy, keeping test-only switches
            # out of the installed helper.
            isolated_script = p / "sirius-modem-uim"
            isolated_script.write_text(
                SCRIPT.read_text()
                .replace("/mnt/sysmod/glue/bin/uimsel", str(p / "bin/uimsel"))
                .replace("/run/sirius-modem-uim", str(p / "run/sirius-modem-uim"))
                .replace("/proc/uptime", str(p / "uptime")))
            env = {
                **os.environ,
                "PATH": f"{p / 'bin'}:{os.environ['PATH']}",
                "MODEM_TEST_ROOT": str(p),
            }
            for _ in range(2 if twice else 1):
                result = subprocess.run(["sh", str(isolated_script)], env=env, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            calls = [json.loads(line) for line in (p / "calls.jsonl").read_text().splitlines()]
            self.assertFalse(any(cmd == "date" for cmd, _ in calls))
            return calls, result.stdout

    def assert_restarts(self, config, expected, **kwargs):
        calls, output = self.run_case(config, **kwargs)
        restarts = [args for cmd, args in calls if cmd == "systemctl" and args[0] == "try-restart"]
        self.assertEqual(len(restarts), expected, output)
        for args in restarts:
            self.assertIn("--no-block", args)
        return calls, output

    def test_initialization_grace_and_service_states(self):
        for case in [
            {}, {"now": 99}, {"sub": "start-pre"}, {"sub": "stop-sigterm"},
            {"active": False}, {"started": 0}, {"started": "unknown"},
            {"now": 200, "list_error": True},
        ]:
            with self.subTest(case=case): self.assert_restarts(case, 0)

    def test_missing_modem_after_grace(self):
        self.assert_restarts({"now": 100}, 1)

    def test_existing_objects_do_not_need_restart(self):
        for case in [
            {"object": True}, {"object": True, "info_error": True},
            {"object": True, "failure": "sim-error"},
        ]:
            with self.subTest(case=case): self.assert_restarts({"now": 200, **case}, 0)

    def test_confirmed_missing_sim_needs_reprobe(self):
        self.assert_restarts({"object": True, "failure": "sim-missing"}, 1)

    def test_hotplug_during_initialization_is_not_a_restart(self):
        calls, _ = self.assert_restarts({"new_session": True}, 0)
        self.assertTrue(any(cmd == "uimsel" for cmd, _ in calls))

    def test_hotplug_after_missing_sim_failure(self):
        self.assert_restarts({"new_session": True, "object": True, "failure": "sim-missing"}, 1)

    def test_cooldown_and_corrupt_or_legacy_stamps(self):
        for stamp, expected in [(180, 0), (140, 1), ("invalid", 1), (1700000000, 1)]:
            with self.subTest(stamp=stamp): self.assert_restarts({"now": 200, "stamp": stamp}, expected)

    def test_repeated_events_share_cooldown(self):
        self.assert_restarts({"now": 200}, 1, twice=True)

    def test_absent_card_does_not_restart(self):
        self.assert_restarts({"now": 200, "absent": True, "object": True, "failure": "sim-missing"}, 0)

    def test_failed_mode_query_does_not_blindly_change_radio(self):
        calls, _ = self.assert_restarts({"mode_error": True}, 0)
        self.assertFalse(any("--dms-set-operating-mode=online" in args for _, args in calls))

    def test_unready_uim_has_a_monotonic_deadline(self):
        calls, output = self.assert_restarts({"unready": True}, 0)
        polls = [args for cmd, args in calls if cmd == "qmicli"]
        self.assertLessEqual(len(polls), 5)
        self.assertIn("40s", output)


if __name__ == "__main__":
    SCRATCH.mkdir(parents=True, exist_ok=True)
    unittest.main()
