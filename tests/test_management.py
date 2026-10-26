#!/usr/bin/env python3
"""Unprivileged fixtures only: no real /etc, service or network is modified."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest

REPO = Path(__file__).resolve().parents[1]
OLD = "11111111-1111-4111-8111-111111111111"
NEW = "22222222-2222-4222-8222-222222222222"

PRELUDE = r'''
source "$REPO/install.sh"
is_core_dir=$FIXTURE/etc/sing-box
is_sh_dir=$is_core_dir/sh
is_core_bin=$is_core_dir/bin/sing-box
is_config_json=$is_core_dir/config.json
is_conf_dir=$is_core_dir/conf
is_sh_bin=$FIXTURE/usr/local/bin/sing-box
is_systemd=1
is_openrc=
is_log_dir=$FIXTURE/log
is_tls_key=$is_core_dir/bin/tls.key
is_tls_cer=$is_core_dir/bin/tls.cer
is_core_ver=1.12.0
ip=192.0.2.1
systemctl() {
    printf '%s\n' "$*" >>"$FIXTURE/service.calls"
    case $1 in
      show) printf '{ path=%s ; argv[]=%s run -c %s -C %s %s ; ignore_errors=no ; }\n' \
          "$is_core_bin" "$is_core_bin" "$is_config_json" "$is_conf_dir" "${EXTRA_ARGS:-}" ;;
      cat) printf '[Service]\nExecStart=%s run -c %s -C %s\n' "$is_core_bin" "$is_config_json" "$is_conf_dir" ;;
      *) return 99 ;;
    esac
}
source "$REPO/src/manager.sh"
source "$REPO/src/core.sh"
manage() { printf '%s\n' "$*" >>"$FIXTURE/restarts"; }
is_port_used() { return 1; }
'''

MOCK_CORE = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a=sys.argv[1:]
if a[0] == 'version': print('sing-box version 1.12.0'); sys.exit(0)
if a[:2] == ['generate','reality-keypair']:
    print('PrivateKey: generated-private\nPublicKey: generated-public'); sys.exit(0)
if a[0] != 'check': sys.exit(2)
with open(os.environ['FIXTURE']+'/checks','a') as f: f.write(json.dumps(a)+'\n')
try:
    c=Path(a[a.index('-c')+1]); d=Path(a[a.index('-C')+1])
    objects=[json.loads(c.read_text())]+[json.loads(p.read_text()) for p in d.glob('*.json')]
    for obj in objects:
        for inbound in obj.get('inbounds',[]):
            h=inbound.get('tls',{}).get('reality',{}).get('handshake',{})
            if h.get('server') == 'fail.example': sys.exit(1)
    if os.environ.get('FAIL_FINAL') and '.config-' not in str(c): sys.exit(1)
except Exception: sys.exit(1)
'''


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="sing-box-tests-")
        self.root = Path(self.tmp.name)
        self.core = self.root / "etc/sing-box"
        self.conf = self.core / "conf"
        self.conf.mkdir(parents=True)
        (self.core / "bin").mkdir()
        self.commands = self.root / "usr/local/bin"
        self.commands.mkdir(parents=True)
        shutil.copytree(REPO / "src", self.core / "sh/src")
        for f in ("install.sh", "sing-box.sh"):
            shutil.copy(REPO / f, self.core / "sh" / f)
        # An actual upstream identity, plus opaque installation/subscription data.
        (self.core / "sh/src/init.sh").write_text("author=233boy\n")
        (self.core / "sh/subscription.txt").write_text("opaque subscription data\n")
        for f in ("sing-box", "sb"):
            (self.commands / f).symlink_to(self.core / "sh/sing-box.sh")
        (self.core / "config.json").write_text('{"log":{"level":"warn"},"outbounds":[{"type":"direct","tag":"direct"}]}\n')
        (self.core / "bin/sing-box").write_text(MOCK_CORE)
        (self.core / "bin/sing-box").chmod(0o755)
        (self.core / "bin/tls.key").write_text("existing-certificate-key")
        self.node("VLESS-REALITY-39149.json")
        self.node("VLESS-HTTP2-REALITY-34138.json", h2=True, port=34138)
        (self.conf / "Shadowsocks-45678.json").write_text(json.dumps({
            "inbounds": [{"type": "shadowsocks", "tag": "ss-custom", "listen": "::", "listen_port": 45678,
                          "method": "aes-128-gcm", "password": "fixture-password", "network": "tcp"}]}))

    def tearDown(self):
        self.tmp.cleanup()

    def node(self, name, h2=False, port=39149):
        node = {"type": "vless", "tag": name, "listen": "::", "listen_port": port,
                "users": [{"uuid": OLD, **({} if h2 else {"flow": "xtls-rprx-vision"}), "name": "retained"},
                          {"uuid": NEW, "name": "extra-user"}],
                "tcp_fast_open": True,
                "tls": {"enabled": True, "server_name": "node.cetaceang.de",
                        "reality": {"enabled": True, "private_key": "fixture-private", "short_id": ["12345678"],
                                    "handshake": {"server": "node.cetaceang.de", "server_port": 443, "connect_timeout": "5s"}}}}
        if h2:
            node["transport"] = {"type": "http", "path": "/retained"}
        (self.conf / name).write_text(json.dumps({"inbounds": [node], "outbounds": [
            {"type": "direct"}, {"type": "direct", "tag": "public_key_fixture-public"},
            {"type": "direct", "tag": "keep-this-outbound"}]}))

    def run_bash(self, code, ok=True, **env):
        result = subprocess.run(["bash", "-c", PRELUDE + "\n" + code + "\n"], cwd=REPO,
                                env={**os.environ, "REPO": str(REPO), "FIXTURE": str(self.root), **env},
                                text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def protected(self):
        paths = [self.core / "config.json", *self.conf.glob("*"), *self.core.joinpath("bin").glob("*")]
        return {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}

    def read_node(self, h2=False, port=None):
        port = port or (34138 if h2 else 39149)
        name = f"VLESS-{'HTTP2-' if h2 else ''}REALITY-{port}.json"
        return json.loads((self.conf / name).read_text())

    def test_adopt_repeat_update_and_rollback(self):
        before = self.protected()
        result = self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install')
        self.assertIn("未重启服务", result.stdout)
        self.assertEqual(before, self.protected())
        self.assertFalse((self.root / "restarts").exists())
        self.assertIn("cetaceang/sing-box", (self.core / "sh/src/init.sh").read_text())
        self.assertEqual((self.core / "sh/subscription.txt").read_text(), "opaque subscription data\n")
        self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install')
        self.assertEqual(before, self.protected())
        backups = sorted((self.core / "backups").glob("scripts-*"))
        self.assertEqual(len(backups), 2)
        subprocess.run(["bash", str(backups[0] / "rollback.sh")], check=True, capture_output=True)
        self.assertEqual((self.core / "sh/src/init.sh").read_text(), "author=233boy\n")
        self.assertEqual(before, self.protected())
        self.assertTrue((self.commands / "sb").is_symlink())

    def test_adopt_missing_sb_is_added_and_rollback_removes_it(self):
        (self.commands / "sb").unlink()
        self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install')
        self.assertTrue((self.commands / "sb").exists())
        backup = next((self.core / "backups").glob("scripts-*/rollback.sh"))
        subprocess.run(["bash", str(backup)], check=True, capture_output=True)
        self.assertFalse((self.commands / "sb").exists())

    def test_adopt_failure_after_switch_restores_scripts_and_links(self):
        before = self.protected()
        self.run_bash(r'''
checks=0
check_current_config() { ((checks+=1)); [[ $checks -lt 2 ]]; }
replace_scripts "$REPO"
''', ok=False)
        self.assertEqual((self.core / "sh/src/init.sh").read_text(), "author=233boy\n")
        self.assertEqual(before, self.protected())
        self.assertTrue((self.commands / "sb").exists())

    def test_adopt_rejects_incompatible_layout_and_args(self):
        before = self.protected()
        self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install', ok=False, EXTRA_ARGS="--unknown")
        self.assertEqual(before, self.protected())
        self.assertFalse((self.core / "backups").exists())
        (self.commands / "sing-box").unlink()
        (self.commands / "sing-box").symlink_to("/nonexistent/foreign-command")
        self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install', ok=False)
        self.assertEqual(before, self.protected())

    def test_service_arguments_preserve_supported_options_and_reject_multiple_commands(self):
        self.run_bash('check_current_config', EXTRA_ARGS=f"--disable-color -D {self.root}")
        args = json.loads((self.root / "checks").read_text().splitlines()[-1])
        self.assertEqual(args[-3:], ["--disable-color", "-D", str(self.root)])
        self.run_bash(r'''
systemctl() {
    printf '{ argv[]=%s run -c %s -C %s ; } ; { argv[]=/other ; }\n' \
        "$is_core_bin" "$is_config_json" "$is_conf_dir"
}
service_check_args
''', ok=False)

    def test_no_adoption_without_flag_or_with_core_replacement(self):
        before = self.protected()
        self.run_bash('unset is_core_ver; install_main --local-install', ok=False)
        self.run_bash('unset is_core_ver; install_main --adopt-existing --core-version v1.14.4', ok=False)
        self.assertEqual(before, self.protected())

    def test_legacy_info_and_handshake_both_transports(self):
        for port, h2 in ((39149, False), (34138, True)):
            info = self.run_bash(f'main info {port}')
            self.assertIn("node.cetaceang.de:443", info.stdout)
            old = self.read_node(h2)
            self.run_bash(f'main handshake {port} 127.0.0.1 8443')
            new = self.read_node(h2)
            old["inbounds"][0]["tls"]["reality"]["handshake"].update(server="127.0.0.1", server_port=8443)
            self.assertEqual(old, new)
            self.run_bash(f'main handshake {port} "" 9443')
            self.assertEqual(self.read_node(h2)["inbounds"][0]["tls"]["reality"]["handshake"]["server"], "127.0.0.1")

    def test_changes_preserve_handshake_and_unedited_fields(self):
        for port, h2 in ((39149, False), (34138, True)):
            self.run_bash(f'main handshake {port} 127.0.0.1 8443')
            self.run_bash(f'main sni {port} changed.example')
            self.run_bash(f'main uuid {port} {NEW}')
            self.run_bash(f'main key {port} changed-private changed-public')
            self.run_bash(f'main port {port} {port + 1}')
            obj = self.read_node(h2, port + 1)
            node = obj["inbounds"][0]
            self.assertEqual(node["tls"]["reality"]["handshake"], {"server": "127.0.0.1", "server_port": 8443, "connect_timeout": "5s"})
            self.assertEqual(node["tls"]["reality"]["short_id"], ["12345678"])
            self.assertEqual(node["tls"]["server_name"], "changed.example")
            self.assertEqual(node["tls"]["reality"]["private_key"], "changed-private")
            self.assertEqual(node["users"][0]["uuid"], NEW)
            self.assertEqual(node["users"][0]["name"], "retained")
            self.assertEqual(len(node["users"]), 2)
            self.assertTrue(node["tcp_fast_open"])
            self.assertEqual(obj["outbounds"][2]["tag"], "keep-this-outbound")
            if h2:
                self.assertEqual(node["transport"], {"type": "http", "path": "/retained"})
            before = self.protected()
            self.run_bash(f'main fix {port + 1}')
            self.run_bash('main fix-all')
            self.assertEqual(before, self.protected())

    def test_invalid_handshake_and_failed_checks_never_change_config(self):
        for args in ('127.0.0.1 0', '127.0.0.1 65536', '127.0.0.1 0080', 'https://example.com 443', 'fail.example 443'):
            before = self.protected()
            self.run_bash('main handshake 39149 ' + args, ok=False)
            self.assertEqual(before, self.protected())
        before = self.protected()
        self.run_bash('main handshake 39149 127.0.0.1 8443', ok=False, FAIL_FINAL="1")
        self.assertEqual(before, self.protected())
        self.assertFalse((self.root / "restarts").exists())

    def test_menu_prompt_and_reality_protocol_switch_keep_handshake(self):
        self.run_bash("printf '127.0.0.1\\n8443\\n' | main change 39149 handshake")
        self.run_bash('main new 39149 rh2')
        obj = self.read_node(h2=True, port=39149)
        self.assertEqual(obj["inbounds"][0]["tls"]["reality"]["handshake"],
                         {"server": "127.0.0.1", "server_port": 8443, "connect_timeout": "5s"})

    def test_main_config_changes_are_backed_up_and_rolled_back(self):
        nodes = {p.name: p.read_bytes() for p in self.conf.glob("*.json")}
        self.run_bash('main dns none')
        self.run_bash('main log debug')
        before = self.protected()
        self.run_bash('main log none', ok=False, FAIL_FINAL="1")
        self.assertEqual(before, self.protected())
        self.assertEqual(nodes, {p.name: p.read_bytes() for p in self.conf.glob("*.json")})

    def test_non_reality_rejects_handshake_and_retains_extensions(self):
        before = self.protected()
        self.run_bash('main handshake 45678 127.0.0.1 8443', ok=False)
        self.assertEqual(before, self.protected())
        self.run_bash('main port 45678 45679')
        node = json.loads((self.conf / "Shadowsocks-45679.json").read_text())["inbounds"][0]
        self.assertEqual(node["network"], "tcp")
        self.assertEqual(node["password"], "fixture-password")

    def test_new_reality_defaults_and_custom_handshake(self):
        self.run_bash('main add reality 49100 auto node.example')
        obj = json.loads((self.conf / "VLESS-REALITY-49100.json").read_text())
        self.assertEqual(obj["inbounds"][0]["tls"]["reality"]["handshake"], {"server": "node.example", "server_port": 443})
        self.run_bash('main add rh2 49101 auto node.example 127.0.0.1 8443')
        obj = json.loads((self.conf / "VLESS-HTTP2-REALITY-49101.json").read_text())
        self.assertEqual(obj["inbounds"][0]["tls"]["reality"]["handshake"], {"server": "127.0.0.1", "server_port": 8443})

    def test_download_is_pinned_to_fork_without_a_release(self):
        sha = "a" * 40
        with tarfile.open(self.root / "package.tar.gz", "w:gz") as archive:
            for file in [REPO / "install.sh", REPO / "sing-box.sh", *REPO.glob("src/*.sh")]:
                archive.add(file, arcname=f"sing-box-{sha}/{file.relative_to(REPO)}")
        before = self.protected()
        self.run_bash(r'''
_wget() {
    printf '%s\n' "$*" >>"$FIXTURE/download.calls"
    case ${*: -1} in
        https://api.github.com/repos/cetaceang/sing-box/commits/main)
            printf '  "sha": "%s",\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        https://codeload.github.com/cetaceang/sing-box/tar.gz/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
            cp "$FIXTURE/package.tar.gz" "$tmpdir/source.tar.gz" ;;
        *) return 1 ;;
    esac
}
unset is_core_ver
install_main --adopt-existing
''')
        self.assertEqual(before, self.protected())
        receipt = (self.core / "sh/.source").read_text()
        self.assertIn("commit=" + sha, receipt)
        calls = (self.root / "download.calls").read_text()
        self.assertNotIn("233boy", calls)
        self.assertNotIn("releases", calls)

    def test_update_sh_uses_adoption_and_no_service_restart(self):
        self.run_bash(r'''
bash() { printf '%s\n' "$*" >"$FIXTURE/update.calls"; }
main update.sh
''')
        self.assertEqual((self.root / "update.calls").read_text().strip(),
                         f"{self.core}/sh/install.sh --adopt-existing")
        self.assertFalse((self.root / "restarts").exists())

    def test_fresh_local_install_creates_one_default_node(self):
        with tarfile.open(self.root / "kernel.tar.gz", "w:gz") as archive:
            archive.add(self.core / "bin/sing-box", arcname="kernel/sing-box")
        shutil.rmtree(self.core)
        for f in self.commands.iterdir():
            f.unlink()
        self.run_bash(r'''
is_shell_rc=$FIXTURE/bashrc
is_log_dir=$FIXTURE/log
is_wget=1
unset is_core_ver
clear() { :; }
timedatectl() { :; }
get_ip() { ip=192.0.2.1; }
install_pkg() { touch "$is_pkg_ok"; }
install_service() { printf '%s\n' "$*" >"$FIXTURE/new-service"; }
load() { :; } # Definitions are already loaded; no real systemd script is run.
_wget() { return 1; } # Fresh local install must not need the network.
install_main --local-install --core-file "$FIXTURE/kernel.tar.gz"
''')
        self.assertEqual(len(list(self.conf.glob("*.json"))), 1)
        obj = json.loads(next(self.conf.glob("*.json")).read_text())
        node = obj["inbounds"][0]
        self.assertEqual(node["tls"]["reality"]["handshake"],
                         {"server": node["tls"]["server_name"], "server_port": 443})
        self.assertTrue((self.core / "config.json").exists())
        self.assertTrue((self.commands / "sb").exists())

    @unittest.skipUnless(os.environ.get("SING_BOX_TEST_CORE"), "set SING_BOX_TEST_CORE for real kernel checks")
    def test_official_kernel_integration(self):
        shutil.copyfile(os.environ["SING_BOX_TEST_CORE"], self.core / "bin/sing-box")
        binary = str(self.core / "bin/sing-box")
        for file in self.conf.glob("*REALITY*.json"):
            pair = subprocess.check_output([binary, "generate", "reality-keypair"], text=True).splitlines()
            obj = json.loads(file.read_text())
            obj["inbounds"][0]["tls"]["reality"]["private_key"] = pair[0].split(": ")[1]
            obj["outbounds"][1]["tag"] = "public_key_" + pair[1].split(": ")[1]
            obj["outbounds"][2]["tag"] += "-" + str(obj["inbounds"][0]["listen_port"])
            if "HTTP2" not in file.name:
                obj["inbounds"][0]["users"][1]["flow"] = "xtls-rprx-vision"
            file.write_text(json.dumps(obj))
        before = self.protected()
        self.run_bash('unset is_core_ver; install_main --adopt-existing --local-install')
        self.assertEqual(before, self.protected())
        for cmd in ("main handshake 39149 127.0.0.1 8443", "main sni 39149 changed.example",
                    f"main uuid 39149 {NEW}", "main port 39149 39150",
                    "main handshake 34138 127.0.0.1 8443", "main fix-all"):
            self.run_bash(cmd)


if __name__ == "__main__":
    unittest.main(verbosity=2)
