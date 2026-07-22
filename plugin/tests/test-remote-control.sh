#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"

PYTHONPATH="$SCRIPTS" python3 - <<'PY'
import json
import os
import tempfile
import textwrap
import threading
import time
import unittest
from pathlib import Path

from marina_remote import RemoteController, RemoteControlError, canonical_fingerprint


class RemoteControlTests(unittest.TestCase):
    def make_fake(self, root, status=None, serve=None, funnel=None):
        root.mkdir()
        (root / "status.json").write_text(json.dumps(status or {}), encoding="utf-8")
        (root / "serve.json").write_text(json.dumps(serve or {}), encoding="utf-8")
        (root / "funnel.json").write_text(json.dumps(funnel or {}), encoding="utf-8")
        executable = root / "tailscale"
        executable.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json
            import sys
            from pathlib import Path

            root = Path(__file__).parent
            args = sys.argv[1:]
            with (root / "calls.log").open("a", encoding="utf-8") as log:
                log.write(json.dumps(args) + "\\n")
            if args == ["version", "--json"]:
                print(json.dumps({"long": "1.90.0"}))
            elif args == ["status", "--json"]:
                print((root / "status.json").read_text(encoding="utf-8"))
            elif args == ["serve", "status", "--json"]:
                print((root / "serve.json").read_text(encoding="utf-8"))
            elif args == ["funnel", "status", "--json"]:
                print((root / "funnel.json").read_text(encoding="utf-8"))
            elif len(args) == 4 and args[0] in ("serve", "funnel") and args[1:3] == ["--bg", "--https=443"]:
                mode = args[0]
                backend = args[3]
                if (root / ("consent-" + mode)).exists():
                    print("Enable this feature at https://login.tailscale.com/admin/" + mode + "?node=marina", file=sys.stderr)
                    raise SystemExit(1)
                if (root / ("fail-" + mode + "-on")).exists():
                    print(mode + " activation failed", file=sys.stderr)
                    raise SystemExit(1)
                if (root / ("wrong-" + mode + "-on")).exists():
                    backend = "http://127.0.0.1:1"
                status = json.loads((root / "status.json").read_text(encoding="utf-8"))
                host = status.get("Self", {}).get("DNSName", "marina.tailnet.ts.net.").rstrip(".")
                config = {
                    "TCP": {"443": {"HTTPS": True}},
                    "Web": {host + ":443": {"Handlers": {"/": {"Proxy": backend}}}},
                }
                if mode == "funnel":
                    config["AllowFunnel"] = {host + ":443": True}
                (root / "serve.json").write_text(json.dumps(config), encoding="utf-8")
                (root / "funnel.json").write_text(json.dumps(config), encoding="utf-8")
            elif len(args) == 3 and args[0] in ("serve", "funnel") and args[1:] == ["--https=443", "off"]:
                mode = args[0]
                if (root / ("fail-" + mode + "-off")).exists():
                    print(mode + " shutdown failed", file=sys.stderr)
                    raise SystemExit(1)
                (root / "serve.json").write_text("{}", encoding="utf-8")
                (root / "funnel.json").write_text("{}", encoding="utf-8")
            else:
                print("unexpected command: " + " ".join(args), file=sys.stderr)
                raise SystemExit(64)
        """), encoding="utf-8")
        executable.chmod(0o755)
        return executable

    def test_missing_tailscale_reports_unavailable_without_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "marina"
            controller = RemoteController(
                marina_home=home,
                tailscale_bin=Path(tmp) / "missing-tailscale",
            )

            status = controller.status()

            self.assertEqual("unavailable", status["state"])
            self.assertFalse(status["installed"])
            self.assertFalse(status["online"])
            self.assertEqual("tailscale_not_found", status["error"]["code"])
            self.assertFalse((home / "remote-state.json").exists())

    def test_offline_daemon_preserves_status_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Stopped",
                "TailscaleIPs": ["100.64.0.8"],
                "Self": {
                    "DNSName": "marina.tailnet.ts.net.",
                    "Online": False,
                },
            })
            controller = RemoteController(root / "marina", fake)

            status = controller.status()

            self.assertEqual("offline", status["state"])
            self.assertTrue(status["installed"])
            self.assertFalse(status["online"])
            self.assertEqual("1.90.0", status["version"])
            self.assertEqual("marina.tailnet.ts.net", status["dnsName"])
            self.assertEqual(["100.64.0.8"], status["ips"])
            self.assertEqual("tailscale_offline", status["error"]["code"])

    def test_status_parses_private_https_serve_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            host = "marina.tailnet.ts.net"
            backend = "http://127.0.0.1:3900"
            serve = {
                "Web": {
                    host + ":443": {
                        "Handlers": {"/": {"Proxy": backend}},
                    },
                },
                "TCP": {"443": {"HTTPS": True}},
            }
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "TailscaleIPs": ["100.64.0.8", "fd7a:115c:a1e0::8"],
                "MagicDNSSuffix": "tailnet.ts.net",
                "CertDomains": [host],
                "Self": {"DNSName": host + ".", "Online": True},
            }, serve=serve)
            controller = RemoteController(root / "marina", fake)

            status = controller.status()

            self.assertEqual("serve", status["state"])
            self.assertEqual("serve", status["mode"])
            self.assertEqual("https://" + host, status["url"])
            self.assertEqual(backend, status["backend"])
            self.assertTrue(status["httpsReady"])
            self.assertTrue(status["magicDNSReady"])
            self.assertFalse(status["owned"])
            self.assertTrue(status["conflict"])
            self.assertRegex(status["configFingerprint"], r"^[0-9a-f]{64}$")
            self.assertEqual(serve, status["configuration"]["serve"])

    def test_status_is_cached_for_fifteen_seconds_and_refresh_bypasses_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            now = [100.0]
            controller = RemoteController(root / "marina", fake, clock=lambda: now[0])

            first = controller.status()
            now[0] = 114.999
            second = controller.status()
            calls = (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()

            self.assertIs(first, second)
            self.assertEqual(4, len(calls))

            now[0] = 115.0
            controller.status()
            self.assertEqual(8, len((fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()))

            controller.status(refresh=True)
            self.assertEqual(12, len((fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()))

    def test_serve_activation_on_empty_config_persists_verified_ownership(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "MagicDNSSuffix": "tailnet.ts.net",
                "CertDomains": ["marina.tailnet.ts.net"],
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            home = root / "marina"
            controller = RemoteController(home, fake)

            result = controller.activate("serve", 3900)

            self.assertEqual("serve", result["state"])
            self.assertTrue(result["owned"])
            self.assertFalse(result["conflict"])
            state = json.loads((home / "remote-state.json").read_text(encoding="utf-8"))
            self.assertEqual("serve", state["mode"])
            self.assertEqual("http://127.0.0.1:3900", state["backend"])
            self.assertEqual(443, state["httpsPort"])
            self.assertEqual("/", state["path"])
            self.assertEqual(result["configFingerprint"], state["configFingerprint"])
            self.assertEqual(0o600, (home / "remote-state.json").stat().st_mode & 0o777)
            calls = [json.loads(line) for line in (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()]
            self.assertIn(["serve", "--bg", "--https=443", "http://127.0.0.1:3900"], calls)
            self.assertFalse(any("reset" in call for call in calls))

    def test_consent_url_is_returned_as_action_required_without_state_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            (fake.parent / "consent-funnel").touch()
            home = root / "marina"
            controller = RemoteController(home, fake)

            result = controller.activate("funnel", 3900)

            self.assertEqual("action_required", result["state"])
            self.assertEqual("consent_required", result["error"]["code"])
            self.assertEqual(
                "https://login.tailscale.com/admin/funnel?node=marina",
                result["actionUrl"],
            )
            self.assertFalse((home / "remote-state.json").exists())
            self.assertEqual({}, json.loads((fake.parent / "funnel.json").read_text(encoding="utf-8")))

    def test_off_removes_only_the_owned_listener_and_persists_off(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            home = root / "marina"
            controller = RemoteController(home, fake)
            controller.activate("serve", 3900)
            (fake.parent / "calls.log").write_text("", encoding="utf-8")

            result = controller.off()

            self.assertEqual("off", result["state"])
            self.assertEqual("off", result["mode"])
            self.assertFalse(result["conflict"])
            state = json.loads((home / "remote-state.json").read_text(encoding="utf-8"))
            self.assertEqual("off", state["mode"])
            self.assertIsNone(state["backend"])
            self.assertIsNone(state["configFingerprint"])
            calls = [json.loads(line) for line in (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()]
            self.assertIn(["serve", "--https=443", "off"], calls)
            self.assertFalse(any("reset" in call for call in calls))

    def test_serve_to_funnel_transition_disables_old_listener_first(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            controller = RemoteController(root / "marina", fake)
            controller.activate("serve", 3900)
            (fake.parent / "calls.log").write_text("", encoding="utf-8")

            result = controller.activate("funnel", 3900)

            self.assertEqual("funnel", result["mode"])
            self.assertTrue(result["owned"])
            calls = [json.loads(line) for line in (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()]
            old_off = calls.index(["serve", "--https=443", "off"])
            new_on = calls.index(["funnel", "--bg", "--https=443", "http://127.0.0.1:3900"])
            self.assertLess(old_off, new_on)
            state = json.loads((root / "marina" / "remote-state.json").read_text(encoding="utf-8"))
            self.assertEqual("funnel", state["mode"])

    def test_failed_transition_rolls_back_and_preserves_persisted_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            home = root / "marina"
            controller = RemoteController(home, fake)
            controller.activate("serve", 3900)
            state_before = (home / "remote-state.json").read_bytes()
            (fake.parent / "calls.log").write_text("", encoding="utf-8")
            (fake.parent / "fail-funnel-on").touch()

            with self.assertRaises(RemoteControlError) as raised:
                controller.activate("funnel", 3900)

            self.assertEqual("transition_failed", raised.exception.code)
            self.assertEqual("succeeded", raised.exception.details["rollback"])
            self.assertEqual(state_before, (home / "remote-state.json").read_bytes())
            restored = controller.status(refresh=True)
            self.assertEqual("serve", restored["mode"])
            self.assertTrue(restored["owned"])
            calls = [json.loads(line) for line in (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()]
            self.assertLess(calls.index(["serve", "--https=443", "off"]), calls.index([
                "funnel", "--bg", "--https=443", "http://127.0.0.1:3900",
            ]))
            self.assertIn(["serve", "--bg", "--https=443", "http://127.0.0.1:3900"], calls)

    def test_failed_verification_reports_cleanup_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            (fake.parent / "wrong-serve-on").touch()
            (fake.parent / "fail-serve-off").touch()
            home = root / "marina"
            controller = RemoteController(home, fake)

            with self.assertRaises(RemoteControlError) as raised:
                controller.activate("serve", 3900)

            self.assertEqual("verification_failed", raised.exception.code)
            self.assertEqual("failed", raised.exception.details["rollback"])
            self.assertIn("shutdown failed", raised.exception.details["rollbackError"])
            self.assertFalse((home / "remote-state.json").exists())
            self.assertEqual("serve", controller.status(refresh=True)["mode"])

    def test_mutations_are_serialized_across_controller_instances(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp) / "marina"
            active = 0
            max_active = 0
            guard = threading.Lock()
            errors = []

            class ProbeController(RemoteController):
                def _activate_unlocked(self, mode, port):
                    nonlocal active, max_active
                    with guard:
                        active += 1
                        max_active = max(max_active, active)
                    time.sleep(0.05)
                    with guard:
                        active -= 1
                    return {"mode": mode, "port": port}

            def run(controller):
                try:
                    controller.activate("serve", 3900)
                except Exception as exc:
                    errors.append(exc)

            missing = Path(tmp) / "missing-tailscale"
            threads = [threading.Thread(target=run, args=(ProbeController(home, missing),)) for _ in range(2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()

            self.assertEqual([], errors)
            self.assertEqual(1, max_active)

    def test_status_parses_funnel_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            host = "marina.tailnet.ts.net"
            funnel = {
                "AllowFunnel": {host + ":443": True},
                "TCP": {"443": {"HTTPS": True}},
                "Web": {host + ":443": {"Handlers": {
                    "/": {"Proxy": "http://127.0.0.1:3900"},
                }}},
            }
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": host + ".", "Online": True},
            }, funnel=funnel)

            result = RemoteController(root / "marina", fake).status()

            self.assertEqual("funnel", result["state"])
            self.assertEqual("funnel", result["routes"][0]["mode"])
            self.assertEqual(funnel, result["configuration"]["funnel"])

    def test_identical_status_documents_use_allow_funnel_as_authority(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            host = "marina.tailnet.ts.net"
            private = {
                "TCP": {"443": {"HTTPS": True}},
                "Web": {host + ":443": {"Handlers": {
                    "/": {"Proxy": "http://127.0.0.1:3900"},
                }}},
            }
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": host + ".", "Online": True},
            }, serve=private, funnel=private)

            result = RemoteController(root / "marina", fake).status()

            self.assertEqual("serve", result["mode"])
            self.assertEqual("serve", result["routes"][0]["mode"])

    def test_unowned_and_mismatched_nonempty_configs_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            host = "marina.tailnet.ts.net"
            route = {
                "TCP": {"443": {"HTTPS": True}},
                "Web": {host + ":443": {"Handlers": {
                    "/": {"Proxy": "http://127.0.0.1:8123"},
                }}},
            }
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": host + ".", "Online": True},
            }, serve=route)
            home = root / "marina"
            controller = RemoteController(home, fake)

            with self.assertRaises(RemoteControlError) as unowned:
                controller.activate("serve", 3900)
            self.assertEqual("config_conflict", unowned.exception.code)
            self.assertFalse((home / "remote-state.json").exists())

            home.mkdir(exist_ok=True)
            state = {
                "version": 1,
                "mode": "serve",
                "backend": "http://127.0.0.1:8123",
                "httpsPort": 443,
                "path": "/",
                "configFingerprint": "0" * 64,
            }
            state_path = home / "remote-state.json"
            state_path.write_text(json.dumps(state), encoding="utf-8")
            before = state_path.read_bytes()
            with self.assertRaises(RemoteControlError) as mismatched:
                RemoteController(home, fake).off()
            self.assertEqual("config_conflict", mismatched.exception.code)
            self.assertEqual(before, state_path.read_bytes())
            self.assertEqual(route, json.loads((fake.parent / "serve.json").read_text(encoding="utf-8")))

    def test_off_failure_preserves_configuration_and_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            home = root / "marina"
            controller = RemoteController(home, fake)
            controller.activate("serve", 3900)
            persisted = (home / "remote-state.json").read_bytes()
            configured = (fake.parent / "serve.json").read_bytes()
            (fake.parent / "fail-serve-off").touch()

            with self.assertRaises(RemoteControlError) as raised:
                controller.off()

            self.assertEqual("tailscale_command_failed", raised.exception.code)
            self.assertEqual(persisted, (home / "remote-state.json").read_bytes())
            self.assertEqual(configured, (fake.parent / "serve.json").read_bytes())

    def test_transition_consent_rolls_back_before_returning_action_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            home = root / "marina"
            controller = RemoteController(home, fake)
            controller.activate("serve", 3900)
            persisted = (home / "remote-state.json").read_bytes()
            (fake.parent / "consent-funnel").touch()

            result = controller.activate("funnel", 3900)

            self.assertEqual("action_required", result["state"])
            self.assertEqual("succeeded", result["error"]["rollback"])
            self.assertEqual(persisted, (home / "remote-state.json").read_bytes())
            self.assertEqual("serve", controller.status(refresh=True)["mode"])

    def test_funnel_to_serve_transition_is_targeted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = self.make_fake(root / "fake", {
                "BackendState": "Running",
                "Self": {"DNSName": "marina.tailnet.ts.net.", "Online": True},
            })
            controller = RemoteController(root / "marina", fake)
            controller.activate("funnel", 3900)
            (fake.parent / "calls.log").write_text("", encoding="utf-8")

            result = controller.activate("serve", 3900)

            self.assertEqual("serve", result["mode"])
            calls = [json.loads(line) for line in (fake.parent / "calls.log").read_text(encoding="utf-8").splitlines()]
            self.assertLess(calls.index(["funnel", "--https=443", "off"]), calls.index([
                "serve", "--bg", "--https=443", "http://127.0.0.1:3900",
            ]))
            self.assertFalse(any("reset" in call for call in calls))

    def test_canonical_fingerprint_ignores_json_key_order_only(self):
        left = {"Web": {"host:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3900"}}}}, "TCP": {"443": {"HTTPS": True}}}
        right = {"TCP": {"443": {"HTTPS": True}}, "Web": {"host:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:3900"}}}}}

        self.assertEqual(canonical_fingerprint(left), canonical_fingerprint(right))
        right["TCP"]["443"]["HTTPS"] = False
        self.assertNotEqual(canonical_fingerprint(left), canonical_fingerprint(right))


if __name__ == "__main__":
    unittest.main()
PY
