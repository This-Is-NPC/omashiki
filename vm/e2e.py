#!/usr/bin/env python3
"""Non-interactive distributed VM E2E for the current Omashiki source tree.

The test is deliberately self-contained and run-scoped. It never edits the
repository configuration, uses only the two owned libvirt domains, and records
cleanup verification in the JSON report before returning success.
"""

from __future__ import annotations

import base64
import fcntl
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
VM_NAMES = ("omashiki-node-1", "omashiki-node-2")
VM_USER = "fedora"
GUEST_RUNTIME_PARENT = Path("/tmp")
HOST_HOME = Path.home()
HOST_GIT_USER = os.environ.get("OMASHIKI_VM_HOST_USER") or pwd.getpwuid(os.getuid()).pw_name
BASE_VOLUME = "fedora44-base.qcow2"
BASE_PATH = Path(os.environ.get(
    "OMASHIKI_VM_BASE",
    str(HOST_HOME / "vms" / "base" / "Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"),
))
POOL = "images"
REMOTE_MIRROR = ".cache/omashiki/mirrors/fixture"
HELLO = b'print("Hello, World!")\n'
VIRT_INSTALL = ["/usr/bin/python3", "/usr/bin/virt-install"]
LOCK_PATH = Path("/tmp/omashiki-vm-e2e.lock")
RUN_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{6}$")
PUBLIC_KEY_RE = re.compile(r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/]+={0,3}(?: [^\s]+)?$")


class E2EError(RuntimeError):
    pass


class Blocker(E2EError):
    pass


def q(value: object) -> str:
    return shlex.quote(str(value))


def now_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)


REMOTE_EDIT_CODE = r'''
import base64, json, os, pathlib, stat, tempfile
payload = json.loads(base64.b64decode("PAYLOAD").decode())
path = pathlib.Path(payload["path"])
parent = path.parent
if parent.is_symlink() or (path.exists() and path.is_symlink()):
    raise SystemExit("refusing symlinked SSH path: " + str(path))
if not parent.exists():
    parent.mkdir(mode=0o700, parents=True)
elif parent.is_symlink():
    raise SystemExit("refusing symlinked SSH directory: " + str(parent))
exists = path.exists()
mode = stat.S_IMODE(path.stat().st_mode) if exists else 0o600
old = path.read_bytes() if exists else b""
lines = old.splitlines(True)
normalized = {line.rstrip(b"\r\n") for line in lines}
added = []
removed = []
for line in payload.get("add", []):
    encoded = line.encode()
    if encoded not in normalized:
        if lines and not lines[-1].endswith((b"\n", b"\r")):
            lines.append(b"\n")
        lines.append(encoded + b"\n")
        normalized.add(encoded)
        added.append(line)
for line in payload.get("remove", []):
    kept = []
    found = False
    for item in lines:
        if item.rstrip(b"\r\n") == line.encode():
            found = True
            continue
        kept.append(item)
    if found:
        removed.append(line)
    lines = kept
new = b"".join(lines)
if new != old:
    fd, temporary = tempfile.mkstemp(prefix=".omashiki-ssh-", dir=str(parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as output:
            output.write(new)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        os.chmod(path, mode)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
print(json.dumps({"added": added, "removed": removed, "mode": mode}))
'''


class Harness:
    def __init__(self) -> None:
        self.previous_umask = os.umask(0o077)
        self.run_id = now_id()
        self.state = ROOT / ".temp" / f"vm-e2e-{self.run_id}"
        self.logs = self.state / "logs"
        self.source = self.state / "source"
        self.runtime = Path("/tmp") / f"omashiki-vm-e2e-{self.run_id}"
        self.guest_root = GUEST_RUNTIME_PARENT / f"omashiki-vm-e2e-{self.run_id}"
        self.guest_source = self.guest_root / "source"
        self.guest_logs = self.guest_root / "logs"
        self.report_path = self.state / "report.json"
        self.image = f"omashiki/agent-jcode:vm-e2e-{self.run_id}"
        self.report: dict = {
            "schema_version": 2,
            "run_id": self.run_id,
            "status": "running",
            "topology": {"qemu_uri": "qemu:///system", "vms": list(VM_NAMES)},
            "evidence": {},
            "cleanup": {},
        }
        self.host_processes: dict[str, subprocess.Popen] = {}
        self.remote_pids: dict[str, dict] = {}
        self.tunnels: list[subprocess.Popen] = []
        self.vm_ips: dict[str, str] = {}
        self.vm_initial_state: dict[str, str | None] = {}
        self.vm_started_by_run: set[str] = set()
        self.vm_created_by_run: set[str] = set()
        self.vm_initial_snapshots: dict[str, dict] = {}
        self.db_container: str | None = None
        self.db_port = 0
        self.vm_db_port = 0
        self.authorized_line: str | None = None
        self.authorized_added = False
        self.host_known_lines: list[str] = []
        self.vm_known_added: dict[str, list[str]] = {name: [] for name in VM_NAMES}
        self.vm_selinux_initial: dict[str, str] = {}
        self.vm_selinux_disabled: set[str] = set()
        self.attempt_ids: list[str] = []
        self.job_ids: list[str] = []
        self.failed = False
        self.created_volumes: set[str] = set()
        self.lock_file = None
        self.lock_acquired = False
        self.signal_reason: str | None = None
        self.in_cleanup = False
        self.cleanup_errors: list[str] = []
        self.remote_log_paths: dict[str, str] = {}
        self.libvirt_base_path = ""

    def log(self, message: str) -> None:
        print(message, flush=True)

    def write_report(self) -> None:
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.state, 0o700)
        self.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.logs, 0o700)
        fd, temporary = tempfile.mkstemp(prefix=".report-", dir=self.state, text=True)
        try:
            with os.fdopen(fd, "w") as output:
                json.dump(self.report, output, indent=2, sort_keys=True)
                output.write("\n")
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.report_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def local(self, args: list[str], *, cwd: Path | None = None, env: dict | None = None,
              check: bool = True, input_data: bytes | None = None, timeout: int | None = None) -> subprocess.CompletedProcess:
        result = subprocess.run(args, cwd=cwd, env=env, input=input_data,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        self.logs.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.logs / "commands.log").open("a") as output:
            output.write("$ " + " ".join(q(a) for a in args) + "\n")
            output.write(result.stdout.decode(errors="replace"))
            output.write("\n")
        if check and result.returncode != 0:
            text = result.stdout.decode(errors="replace").strip()
            raise E2EError(f"command failed ({result.returncode}): {' '.join(args)}\n{text[-2000:]}")
        return result

    def output(self, args: list[str], *, cwd: Path | None = None, env: dict | None = None) -> str:
        return self.local(args, cwd=cwd, env=env).stdout.decode().strip()

    def ssh_args(self, ip: str) -> list[str]:
        return ["ssh", "-i", str(HOST_HOME / ".ssh" / "id_vms"),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                "-o", "ServerAliveInterval=2", "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                f"{VM_USER}@{ip}"]

    def ssh(self, name: str, script: str, *, check: bool = True,
            input_data: bytes | None = None) -> str:
        return self.ssh_result(name, script, check=check, input_data=input_data).stdout.decode(errors="replace").strip()

    def ssh_result(self, name: str, script: str, *, check: bool = True,
                   input_data: bytes | None = None) -> subprocess.CompletedProcess:
        args = self.ssh_args(self.vm_ips[name]) + ["bash", "-lc", q(script)]
        return self.local(args, check=check, input_data=input_data)

    def scp_to(self, name: str, source: Path, destination: str) -> None:
        args = ["scp", "-q", "-i", str(HOST_HOME / ".ssh" / "id_vms"),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o",
                "ServerAliveInterval=2", "-o", "ServerAliveCountMax=3", "-o",
                "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                str(source), f"{VM_USER}@{self.vm_ips[name]}:{destination}"]
        self.local(args)

    def scp_from(self, name: str, source: str, destination: Path) -> bool:
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        args = ["scp", "-q", "-i", str(HOST_HOME / ".ssh" / "id_vms"),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o",
                "ServerAliveInterval=2", "-o", "ServerAliveCountMax=3", "-o",
                "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                f"{VM_USER}@{self.vm_ips[name]}:{source}", str(destination)]
        return self.local(args, check=False).returncode == 0 and destination.is_file()

    def virsh(self, args: list[str], *, check: bool = True) -> str:
        return self.output(["virsh", "-c", "qemu:///system", *args], cwd=ROOT) if check else self.local(
            ["virsh", "-c", "qemu:///system", *args], check=False
        ).stdout.decode().strip()

    def reject_symlink(self, path: Path, label: str) -> None:
        if path.is_symlink():
            raise Blocker(f"refusing symlinked {label}: {path}")

    def validate_ssh_files(self) -> str:
        ssh_dir = HOST_HOME / ".ssh"
        self.reject_symlink(ssh_dir, "host SSH directory")
        if not ssh_dir.is_dir():
            raise Blocker(f"host SSH directory is missing: {ssh_dir}")
        for name in ("id_vms", "id_vms.pub", "authorized_keys", "known_hosts"):
            self.reject_symlink(ssh_dir / name, f"host SSH file {name}")
        public = ssh_dir / "id_vms.pub"
        if not public.is_file():
            raise Blocker(f"VM access key missing: {public}")
        raw = public.read_text()
        lines = raw.splitlines()
        if len(lines) != 1 or raw.endswith("\n\n") or not PUBLIC_KEY_RE.fullmatch(lines[0]):
            raise Blocker("~/.ssh/id_vms.pub must contain exactly one safe OpenSSH public-key line")
        checked = self.local(["ssh-keygen", "-lf", str(public)], check=False)
        if checked.returncode != 0:
            raise Blocker("~/.ssh/id_vms.pub is not accepted by ssh-keygen")
        return lines[0]

    def acquire_lock(self) -> None:
        self.lock_file = LOCK_PATH.open("a+")
        os.chmod(LOCK_PATH, 0o600)
        try:
            fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise Blocker(f"another VM E2E is running; lock is held at {LOCK_PATH}") from error
        self.lock_acquired = True

    def cleanup_old_runtime(self) -> None:
        old = Path("/tmp/omashiki-vm-e2e-20260828-042739-49d410")
        if not old.exists():
            self.report["cleanup"]["prior_runtime_20260828-042739-49d410"] = {"present": False, "removed": True}
            return
        self.reject_symlink(old, "prior E2E runtime")
        st = old.stat()
        if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o700:
            raise Blocker(f"prior runtime ownership/mode is not generated-user private: {old}")
        allowed = {"git_key", "git_key.pub", "seed", "remote.git", "git-ssh-wrapper"}
        if {item.name for item in old.iterdir()} - allowed:
            raise Blocker(f"prior runtime contains unexpected entries: {old}")
        remote = old / "remote.git"
        if not remote.is_dir() or self.local(["git", "--git-dir", str(remote), "rev-parse", "--is-bare-repository"], check=False).stdout.strip() != b"true":
            raise Blocker(f"prior runtime remote is not the expected bare repository: {remote}")
        for item in old.iterdir():
            if item.is_symlink() or item.stat().st_uid != os.getuid():
                raise Blocker(f"prior runtime contains an unexpected owner or symlink: {item}")
        shutil.rmtree(old)
        self.report["cleanup"]["prior_runtime_20260828-042739-49d410"] = {
            "present": True, "verified_name": old.name, "verified_owner_uid": os.getuid(), "removed": not old.exists()
        }

    def port_free(self, port: int) -> bool:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False
        finally:
            sock.close()

    def guest_port_free(self, name: str, port: int) -> bool:
        probe = "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('127.0.0.1',PORT)); s.close()".replace("PORT", str(port))
        return self.ssh(name, f"timeout 5s python3 -c {q(probe)} && printf free", check=False) == "free"

    def host_docker_result(self, args: list[str]) -> subprocess.CompletedProcess:
        info = self.local(["docker", "info"], check=False, timeout=10)
        if info.returncode != 0:
            raise E2EError("host Docker daemon is unavailable")
        result = self.local(["docker", *args], check=False, timeout=15)
        if result.returncode != 0:
            raise E2EError(f"host Docker query failed: {' '.join(args)}")
        return result

    def guest_docker_result(self, name: str, args: str) -> subprocess.CompletedProcess:
        info = self.ssh_result(name, "timeout 8s sudo -n docker info >/dev/null 2>&1", check=False)
        if info.returncode != 0:
            raise E2EError(f"{name} Docker daemon is unavailable")
        result = self.ssh_result(name, f"timeout 8s sudo -n docker {args}", check=False)
        if result.returncode != 0:
            raise E2EError(f"{name} Docker query failed: {args}")
        return result

    def host_image_absent(self) -> bool:
        result = self.host_docker_inspect(["image", "inspect", self.image])
        if result.returncode == 0:
            return False
        text = result.stdout.decode(errors="replace").lower()
        if "no such object" in text or "no such image" in text:
            return True
        raise E2EError(f"host Docker image inspection failed: {text[-500:]}")

    def guest_image_absent(self, name: str) -> bool:
        result = self.guest_docker_inspect(name, f"image inspect {q(self.image)}")
        if result.returncode == 0:
            return False
        text = result.stdout.decode(errors="replace").lower()
        if "no such object" in text or "no such image" in text:
            return True
        raise E2EError(f"{name} Docker image inspection failed: {text[-500:]}")

    def host_docker_inspect(self, args: list[str]) -> subprocess.CompletedProcess:
        info = self.local(["docker", "info"], check=False, timeout=10)
        if info.returncode != 0:
            raise E2EError("host Docker daemon is unavailable")
        return self.local(["docker", *args], check=False, timeout=15)

    def guest_docker_inspect(self, name: str, args: str) -> subprocess.CompletedProcess:
        info = self.ssh_result(name, "timeout 8s sudo -n docker info >/dev/null 2>&1", check=False)
        if info.returncode != 0:
            raise E2EError(f"{name} Docker daemon is unavailable")
        return self.ssh_result(name, f"timeout 8s sudo -n docker {args}", check=False)

    def domain_owned(self, name: str, xml: str, volume_xml: str, base_path: str) -> bool:
        try:
            root = ET.fromstring(xml)
        except ET.ParseError:
            return False
        if root.findtext("title") != "Omashiki VM E2E dedicated":
            return False
        memory = root.find("memory")
        current_memory = root.find("currentMemory")
        vcpu = root.find("vcpu")
        if (memory is None or current_memory is None or vcpu is None
                or root.findtext("memory") != "4194304" or memory.get("unit") != "KiB"):
            return False
        if root.findtext("currentMemory") != "4194304" or current_memory.get("unit") != "KiB":
            return False
        if root.findtext("vcpu") != "2" or vcpu.get("placement") != "static":
            return False
        disks = root.findall("./devices/disk[@device='disk']")
        if len(disks) != 1:
            return False
        source = disks[0].find("source")
        driver = disks[0].find("driver")
        target = disks[0].find("target")
        if (source is None or source.get("file") != f"/var/lib/libvirt/images/{name}.qcow2"
                or driver is None or driver.get("name") != "qemu" or driver.get("type") != "qcow2"
                or target is None or target.get("dev") != "vda" or target.get("bus") != "virtio"):
            return False
        try:
            volume = ET.fromstring(volume_xml)
        except ET.ParseError:
            return False
        target = volume.find("./target/path")
        backing = volume.find("./backingStore/path")
        if volume.findtext("name") != f"{name}.qcow2" or target is None or target.text != f"/var/lib/libvirt/images/{name}.qcow2":
            return False
        if backing is None or backing.text != base_path:
            return False
        interfaces = root.findall("./devices/interface")
        if len(interfaces) != 1:
            return False
        network = interfaces[0].find("source")
        model = interfaces[0].find("model")
        console = root.find("./devices/console/target")
        return (network is not None and network.get("network") == "default" and model is not None
                and model.get("type") == "virtio" and not root.findall("./devices/graphics")
                and console is not None and console.get("type") == "serial")

    def domain_snapshot(self, name: str, state: str | None) -> dict:
        xml = self.virsh(["dumpxml", name], check=False) if state is not None else ""
        volume_info = self.virsh(["vol-info", f"{name}.qcow2", "--pool", POOL], check=False)
        volume_xml = self.virsh(["vol-dumpxml", f"{name}.qcow2", "--pool", POOL], check=False)
        volume_path = self.virsh(["vol-path", f"{name}.qcow2", "--pool", POOL], check=False)
        backing_path = ""
        volume_network = ""
        if volume_xml:
            try:
                volume = ET.fromstring(volume_xml)
                backing_path = volume.findtext("./backingStore/path") or ""
                volume_network = volume.findtext("./target/path") or ""
            except ET.ParseError:
                pass
        networks = []
        if xml:
            try:
                root = ET.fromstring(xml)
                for interface in root.findall("./devices/interface"):
                    source = interface.find("source")
                    model = interface.find("model")
                    networks.append({
                        "type": interface.get("type"),
                        "network": source.get("network") if source is not None else None,
                        "model": model.get("type") if model is not None else None,
                    })
            except ET.ParseError:
                pass
        return {
            "present": state is not None,
            "initial_state": state,
            "domain_xml": xml or None,
            "volume": {
                "info": volume_info,
                "xml": volume_xml or None,
                "path": volume_path,
                "backing_path": backing_path,
                "target_path": volume_network,
                "network": networks,
            },
        }

    def preflight(self) -> str:
        self.state.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.logs.mkdir(mode=0o700)
        required = ["docker", "virsh", "virt-install", "qemu-img", "ssh", "ssh-keygen", "rsync", "jq", "mix"]
        missing = [tool for tool in required if subprocess.run(["bash", "-lc", f"command -v {q(tool)}"], stdout=subprocess.DEVNULL).returncode != 0]
        if missing:
            raise Blocker("missing required host tools: " + ", ".join(missing))
        if not (HOST_HOME / ".ssh" / "id_vms").is_file():
            raise Blocker(f"VM private key missing: {HOST_HOME / '.ssh' / 'id_vms'}")
        access_pub = self.validate_ssh_files()
        if not BASE_PATH.is_file() or BASE_PATH.is_symlink():
            raise Blocker(f"Fedora Cloud base is missing or symlinked: {BASE_PATH}")
        if self.local(["docker", "info"], check=False).returncode != 0:
            raise Blocker("host Docker daemon is unavailable")
        if self.output(["virsh", "-c", "qemu:///system", "uri"]) != "qemu:///system":
            raise Blocker("libvirt system URI is unavailable")
        virt = self.local([*VIRT_INSTALL, "--version"], check=False)
        if virt.returncode != 0:
            raise Blocker("virt-install cannot run with the host Python")
        if self.local(["docker", "image", "inspect", "postgres:15-alpine"], check=False).returncode != 0:
            raise Blocker("Docker image postgres:15-alpine is not available locally")
        self.cleanup_old_runtime()
        base_path = self.virsh(["vol-path", BASE_VOLUME, "--pool", POOL], check=False)
        if not base_path or base_path.startswith("error:"):
            raise Blocker(f"base libvirt volume is unavailable: {BASE_VOLUME}")
        self.libvirt_base_path = base_path
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        self.vm_initial_state = {
            name: self.virsh(["domstate", name], check=False) if name in domains else None
            for name in VM_NAMES
        }
        for name in VM_NAMES:
            state = self.vm_initial_state[name]
            snapshot = self.domain_snapshot(name, state)
            self.vm_initial_snapshots[name] = snapshot
            if state is not None:
                volume_path = snapshot["volume"]["path"]
                volume_xml = snapshot["volume"]["xml"] or ""
                if not self.domain_owned(name, snapshot["domain_xml"] or "", volume_xml, base_path) or volume_path != f"/var/lib/libvirt/images/{name}.qcow2":
                    raise Blocker(f"refusing to reuse domain {name}: ownership, disk chain, or network does not match exactly")
                if state not in ("running", "shut off"):
                    raise Blocker(f"domain {name} is in unexpected state: {state}")
            elif snapshot["volume"]["info"] and not snapshot["volume"]["info"].startswith("error:"):
                raise Blocker(f"volume {name}.qcow2 exists without an owned domain")
        if not self.port_free(4010):
            raise Blocker("host port 4010 is already occupied")
        self.report["evidence"]["preflight"] = {
            "required_tools": required, "existing_domains": sorted(domains),
            "host_user": HOST_GIT_USER, "host_home": str(HOST_HOME), "base_path": str(BASE_PATH),
            "validated_vm_public_key": True, "image": self.image, "lock": str(LOCK_PATH),
            "initial_vm_state": self.vm_initial_state,
            "domain_snapshots": self.vm_initial_snapshots,
            "created_by_run": [],
        }
        return access_pub

    def render_config(self, host_ip: str) -> None:
        key = self.runtime / "git_key"
        remote = f"ssh://{HOST_GIT_USER}@{host_ip}:22{self.runtime}/remote.git"
        config = f'''[app]
port = 4010
host = "127.0.0.1"

[db]
port = 5432

[auth]
enabled = false

[limits]
max_concurrent_containers = 2
cpu_per_container = 0.25
memory_per_container = "128MB"
pids_limit = 128

[nodes.core]
[nodes.node-1]
[nodes.node-2]

[repositories.fixture]
base_branch = "master"
remote = "{remote}"
ssh_key = "{key}"

[presets.lt-stub]
plugin = "jcode"
options = {{ timeout_ms = 180000, model = "fake-model" }}

[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:8787/v1"

[environments.lt-jcode]
preset = "lt-stub"
isolation = "docker"
image = "{self.image}"
sink = "git"
packages = []
executables = ["git"]
credentials = ["loadtest-fake"]
caches = []
timeout_ms = 180000
network = "host"
mounts = []
pre_steps = []
post_steps = []

[environments.lt-jcode.policy]
mode = "off"

[environments.lt-jcode.resources]
cpus = 0.25
memory = "128MB"
pids = 128
'''
        (self.source / "omashiki.toml").write_text(config)
        os.chmod(self.source / "omashiki.toml", 0o600)

    def copy_source(self) -> None:
        self.source.mkdir(mode=0o700)
        self.local(["rsync", "-a", "--exclude=.git", "--exclude=.temp", "--exclude=deps",
                    "--exclude=_build", "--exclude=node_modules", "--exclude=vm/__pycache__",
                    f"{ROOT}/", f"{self.source}/"])
        (self.source / "server" / "config" / "vm_e2e.exs").write_text('''import Config

# Server-only E2E config: retain dev database semantics without asset watchers.
import_config "dev.exs"

config :omashiki, OmashikiWeb.Endpoint,
  watchers: nil,
  code_reloader: false,
  live_reload: nil
''')
        os.chmod(self.source / "server" / "config" / "vm_e2e.exs", 0o600)

    def host_ip(self) -> str:
        text = self.output(["ip", "-4", "-o", "addr", "show", "virbr0"])
        match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", text)
        if not match:
            raise Blocker("libvirt virbr0 has no IPv4 address")
        return match.group(1)

    def ensure_vms(self, access_pub: str) -> None:
        userdata = self.state / "cloud-init.yaml"
        userdata.write_text(f'''#cloud-config
hostname: omashiki-node-N
manage_etc_hosts: true
ssh_authorized_keys:
  - {access_pub}
package_update: true
packages:
  - git
  - openssh-clients
  - python3
  - gcc
  - gcc-c++
  - make
  - pkgconf-pkg-config
  - openssl-devel
  - libffi-devel
  - ncurses-devel
  - tar
  - gzip
  - curl
  - erlang
  - elixir
runcmd:
  - [bash, -lc, "dnf install -y moby-engine docker-cli || dnf install -y docker"]
  - [bash, -lc, "systemctl enable --now docker && usermod -aG docker fedora"]
''')
        os.chmod(userdata, 0o600)
        for name in VM_NAMES:
            state = self.vm_initial_state[name]
            created = False
            if state is None:
                volume = self.virsh(["vol-info", f"{name}.qcow2", "--pool", POOL], check=False)
                if volume and not volume.startswith("error:"):
                    raise Blocker(f"volume {name}.qcow2 exists without an owned domain")
                self.created_volumes.add(name)
                self.local(["virsh", "-c", "qemu:///system", "vol-create-as", POOL,
                            f"{name}.qcow2", "20G", "--format", "qcow2",
                            "--backing-vol", BASE_VOLUME, "--backing-vol-format", "qcow2"])
                self.vm_created_by_run.add(name)
                self.local([*VIRT_INSTALL, "--connect", "qemu:///system", "--name", name,
                            "--memory", "4096", "--vcpus", "2", "--cpu", "host-passthrough",
                            "--disk", f"vol={POOL}/{name}.qcow2,format=qcow2,bus=virtio",
                            "--import", "--os-variant", "generic", "--network", "network=default,model=virtio",
                            "--graphics", "none", "--console", "pty,target_type=serial",
                            "--metadata", "title=Omashiki VM E2E dedicated", "--cloud-init",
                            f"user-data={userdata}", "--autoconsole", "none"])
                created = True
                self.vm_started_by_run.add(name)
            elif state not in ("running", "shut off"):
                raise Blocker(f"domain {name} is in unexpected state: {state}")
            if state == "shut off" and not created and self.virsh(["domstate", name], check=False) != "running":
                self.local(["virsh", "-c", "qemu:///system", "start", name])
                self.vm_started_by_run.add(name)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            ready = True
            for name in VM_NAMES:
                text = self.virsh(["domifaddr", name], check=False)
                match = re.search(r"(\d+\.\d+\.\d+\.\d+)/\d+", text)
                if match:
                    self.vm_ips[name] = match.group(1)
                else:
                    ready = False
            if ready:
                break
            time.sleep(3)
        if set(self.vm_ips) != set(VM_NAMES):
            raise Blocker("libvirt did not provide IPv4 leases for both dedicated VMs")
        known = self.state / "vm_known_hosts"
        scan = None
        scan_deadline = time.monotonic() + 180
        while time.monotonic() < scan_deadline:
            scan = self.local(["ssh-keyscan", "-T", "5", "-t", "ed25519", *self.vm_ips.values()], check=False)
            scan_hosts = scan.stdout.decode(errors="replace").splitlines() if scan.stdout else []
            if scan.returncode == 0 and scan.stdout.strip() and all(any(line.startswith(ip + " ") for line in scan_hosts) for ip in self.vm_ips.values()):
                break
            time.sleep(3)
        if scan is None or scan.returncode != 0 or not scan.stdout.strip():
            raise Blocker("ssh-keyscan could not establish strict VM host keys")
        known.write_bytes(scan.stdout)
        os.chmod(known, 0o600)
        self.report["topology"]["vm_ips"] = self.vm_ips
        for name in VM_NAMES:
            self.ssh(name, "for p in ~/.ssh ~/.ssh/known_hosts ~/.ssh/authorized_keys; do test ! -L \"$p\" || exit 71; done")
            self.ssh(name, "sudo -n cloud-init status --wait")
            check = self.ssh(name, "command -v docker && command -v mix && command -v python3 && sudo -n docker info >/dev/null")
            if not check:
                raise Blocker(f"{name} does not have Docker, Mix, Python, or passwordless Docker access")
            self.vm_selinux_initial[name] = self.ssh(name, "getenforce", check=False)
            if self.vm_selinux_initial[name] not in ("Enforcing", "Permissive", "Disabled"):
                raise Blocker(f"{name} returned an unknown SELinux state")
            if self.vm_selinux_initial[name] == "Enforcing":
                self.ssh(name, "sudo -n setenforce 0")
                self.vm_selinux_disabled.add(name)
            for port in (4011, 8787):
                if not self.guest_port_free(name, port):
                    raise Blocker(f"{name} target port {port} is already occupied")
        self.report["evidence"]["selinux"] = {
            "initial": self.vm_selinux_initial, "changed_to_permissive": sorted(self.vm_selinux_disabled),
            "exercised_enforcing_mode": False,
        }
        self.report["evidence"]["preflight"]["created_by_run"] = sorted(self.vm_created_by_run)

    def atomic_line_update(self, path: Path, *, add: list[str] = (), remove: list[str] = ()) -> dict:
        self.reject_symlink(path, "SSH file")
        self.reject_symlink(path.parent, "SSH directory")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        old = path.read_bytes() if path.exists() else b""
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
        lines = old.splitlines(True)
        normalized = {line.rstrip(b"\r\n") for line in lines}
        added, removed = [], []
        for line in add:
            encoded = line.encode()
            if encoded not in normalized:
                if lines and not lines[-1].endswith((b"\n", b"\r")):
                    lines.append(b"\n")
                lines.append(encoded + b"\n")
                normalized.add(encoded)
                added.append(line)
        for line in remove:
            kept = [item for item in lines if item.rstrip(b"\r\n") != line.encode()]
            if len(kept) != len(lines):
                removed.append(line)
            lines = kept
        new = b"".join(lines)
        if new != old:
            fd, temporary = tempfile.mkstemp(prefix=".omashiki-ssh-", dir=path.parent)
            try:
                os.fchmod(fd, mode)
                with os.fdopen(fd, "wb") as output:
                    output.write(new)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, path)
                os.chmod(path, mode)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        return {"added": added, "removed": removed, "mode": mode}

    def remote_line_update(self, name: str, path: str, *, add: list[str] = (), remove: list[str] = ()) -> dict:
        payload = base64.b64encode(json.dumps({"path": path, "add": add, "remove": remove}).encode()).decode()
        code = REMOTE_EDIT_CODE.replace("PAYLOAD", payload)
        return json.loads(self.ssh(name, f"python3 -c {q(code)}"))

    def generate_git_key(self) -> None:
        self.runtime.mkdir(mode=0o700)
        self.local(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                    f"omashiki-vm-e2e-{self.run_id}", "-f", str(self.runtime / "git_key")])
        public = (self.runtime / "git_key.pub").read_text().strip()
        if len(public.splitlines()) != 1 or not PUBLIC_KEY_RE.fullmatch(public):
            raise E2EError("generated Git key is not a safe OpenSSH public-key line")
        wrapper = self.runtime / "git-ssh-wrapper"
        remote = self.runtime / "remote.git"
        wrapper.write_text(f'''#!/bin/sh
set -eu
case "${{SSH_ORIGINAL_COMMAND:-}}" in
  "git-upload-pack '{remote}'"|"git-receive-pack '{remote}'") exec /bin/sh -c "$SSH_ORIGINAL_COMMAND" ;;
  *) exit 1 ;;
esac
''')
        os.chmod(wrapper, 0o700)
        self.authorized_line = (
            f'command="{wrapper}",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty '
            f"{public}"
        )
        result = self.atomic_line_update(HOST_HOME / ".ssh" / "authorized_keys", add=[self.authorized_line])
        self.authorized_added = bool(result["added"])
        self.report["evidence"]["temporary_authorization"] = {
            "forced_command": str(wrapper), "remote": str(remote), "newly_added": self.authorized_added,
            "allows_only": [f"git-upload-pack '{remote}'", f"git-receive-pack '{remote}'"],
        }

    def setup_ssh(self, host_ip: str) -> None:
        scan = self.local(["ssh-keyscan", "-T", "5", "-t", "ed25519", host_ip], check=False)
        if scan.returncode != 0 or not scan.stdout.strip():
            raise Blocker(f"ssh-keyscan could not read the host key for {host_ip}")
        self.host_known_lines = scan.stdout.decode().splitlines()
        known = self.state / "vm_known_hosts"
        existing = known.read_text() if known.exists() else ""
        additions = [line for line in self.host_known_lines if line not in existing.splitlines()]
        known.write_text(existing + ("\n" if existing and not existing.endswith("\n") else "") + "\n".join(additions) + ("\n" if additions else ""))
        os.chmod(known, 0o600)
        for name in VM_NAMES:
            result = self.remote_line_update(name, "/home/fedora/.ssh/known_hosts", add=self.host_known_lines)
            self.vm_known_added[name] = result["added"]
        self.report["evidence"]["known_hosts"] = {
            "shared_host_file_modified": False,
            "run_file": str(known),
            "guest_newly_added": self.vm_known_added,
        }

    def create_remote(self, host_ip: str) -> None:
        remote = self.runtime / "remote.git"
        seed = self.runtime / "seed"
        self.local(["git", "init", "--bare", "--initial-branch=master", str(remote)])
        seed.mkdir(mode=0o700)
        self.local(["git", "init", "-q", "-b", "master", str(seed)])
        self.local(["git", "-C", str(seed), "config", "user.name", "VM E2E"])
        self.local(["git", "-C", str(seed), "config", "user.email", "vm-e2e@example.test"])
        self.local(["git", "-C", str(seed), "commit", "--allow-empty", "-q", "-m", "init"])
        self.local(["git", "-C", str(seed), "remote", "add", "origin", str(remote)])
        self.local(["git", "-C", str(seed), "push", "-q", "origin", "master"])
        self.report["evidence"]["remote"] = {"path": str(remote), "url": f"ssh://{HOST_GIT_USER}@{host_ip}:22{remote}"}

    def start_db(self) -> None:
        self.db_container = f"omashiki-vm-e2e-db-{self.run_id}"
        self.local(["docker", "run", "--detach", "--name", self.db_container,
                    "--label", f"omashiki.vm_e2e={self.run_id}", "-e", "POSTGRES_USER=postgres",
                    "-e", "POSTGRES_PASSWORD=postgres", "-e", "POSTGRES_DB=omashiki_dev",
                    "-p", "127.0.0.1::5432", "postgres:15-alpine"])
        port = self.output(["docker", "inspect", "-f", "{{(index (index .NetworkSettings.Ports \"5432/tcp\") 0).HostPort}}", self.db_container])
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            result = self.local(["docker", "exec", self.db_container, "pg_isready", "-U", "postgres", "-d", "omashiki_dev"], check=False)
            if result.returncode == 0:
                self.db_port = int(port)
                self.report["evidence"]["database"] = {"container": self.db_container, "host_port": self.db_port}
                return
            time.sleep(1)
        raise E2EError("PostgreSQL did not become ready within 60 seconds")

    def db_query(self, sql: str) -> list[list[str]]:
        if not self.db_container:
            return []
        result = self.local(["docker", "exec", self.db_container, "psql", "-U", "postgres", "-d", "omashiki_dev", "-A", "-t", "-F", "\t", "-c", sql], check=False)
        if result.returncode != 0:
            return []
        return [line.split("\t") for line in result.stdout.decode().splitlines() if line]

    def prepare_host(self) -> None:
        env = os.environ.copy()
        env.update({"MIX_ENV": "vm_e2e", "OMASHIKI_DB_PORT": str(self.db_port), "OMASHIKI_AGENT_NETWORK_MODE": "host"})
        server = self.source / "server"
        self.local(["mix", "deps.get"], cwd=server, env=env)
        self.local(["mix", "compile"], cwd=server, env=env)
        self.local(["mix", "ecto.create", "--quiet"], cwd=server, env=env, check=False)
        self.local(["mix", "ecto.migrate", "--quiet"], cwd=server, env=env)

    def sync_workers(self) -> None:
        for name in VM_NAMES:
            self.ssh(name, f'''set -e
test ! -e {q(self.guest_root)} && test ! -L {q(self.guest_root)}
mkdir -m 700 {q(self.guest_root)}
test "$(stat -c %u {q(self.guest_root)})" = "$(id -u)"
mkdir -m 700 {q(self.guest_source)} {q(self.guest_logs)}
test ! -L {q(self.guest_source)} && test ! -L {q(self.guest_logs)}
''')
            rsync_ssh = "ssh -i %s -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s" % (q(HOST_HOME / ".ssh" / "id_vms"), q(self.state / "vm_known_hosts"))
            self.local(["rsync", "-az", "--delete", "--exclude=.git", "--exclude=.temp", "--exclude=deps", "--exclude=_build", "--exclude=node_modules", "--exclude=vm/__pycache__", "-e", rsync_ssh, f"{self.source}/", f"{VM_USER}@{self.vm_ips[name]}:{self.guest_source}/"])
            self.ssh(name, f"test -d {q(self.guest_root)} && test \"$(stat -c %u {q(self.guest_root)})\" = \"$(id -u)\"")
            self.scp_to(name, self.runtime / "git_key", str(self.guest_root / "git_key"))
            self.ssh(name, f"chmod 600 {q(self.guest_root / 'git_key')}")
        self.report["evidence"]["guest_paths"] = {
            "root": str(self.guest_root), "source": str(self.guest_source), "logs": str(self.guest_logs),
        }
        image_tar = self.state / "agent-jcode.tar.gz"
        with image_tar.open("wb") as output:
            save = subprocess.Popen(["docker", "save", self.image], stdout=subprocess.PIPE)
            gzip = subprocess.Popen(["gzip", "-c"], stdin=save.stdout, stdout=output)
            assert save.stdout is not None
            save.stdout.close()
            if gzip.wait() != 0 or save.wait() != 0:
                raise E2EError("docker save failed")
        for name in VM_NAMES:
            destination = self.runtime / "agent-jcode.tar.gz"
            self.scp_to(name, image_tar, str(destination))
            self.ssh(name, f"gzip -dc {q(destination)} | sudo -n docker load >/dev/null && rm -f {q(destination)}")
            remote_id = self.ssh(name, f"sudo -n docker image inspect -f '{{{{.Id}}}}' {q(self.image)}")
            self.report["evidence"].setdefault("image_ids", {})[name] = remote_id
        self.report["evidence"]["image_ids"]["host"] = self.output(["docker", "image", "inspect", "-f", "{{.Id}}", self.image])
        for name in VM_NAMES:
            env = "MIX_ENV=vm_e2e HOME=/home/fedora OMASHIKI_AGENT_NETWORK_MODE=host"
            self.ssh(name, f"cd {q(self.guest_source / 'server')} && {env} mix deps.get && {env} mix compile")

    def start_tunnels(self) -> None:
        self.vm_db_port = 15000 + (int(self.run_id[-6:], 16) % 1000)
        for name in VM_NAMES:
            if not self.guest_port_free(name, self.vm_db_port):
                raise Blocker(f"{name} reverse-tunnel port {self.vm_db_port} is already occupied")
            args = self.ssh_args(self.vm_ips[name])[:-1] + ["-N", "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{self.vm_db_port}:127.0.0.1:{self.db_port}", f"{VM_USER}@{self.vm_ips[name]}"]
            log = (self.logs / f"{name}-db-tunnel.log").open("ab")
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            self.tunnels.append(process)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if all(process.poll() is None for process in self.tunnels):
                good = True
                for name in VM_NAMES:
                    probe = self.ssh(name, f"python3 -c {q(f'import socket;s=socket.create_connection((\'127.0.0.1\',{self.vm_db_port}),2);s.close()')}", check=False)
                    if probe:
                        good = False
                if good:
                    return
            time.sleep(1)
        raise E2EError("SSH reverse database tunnels did not become reachable")

    def host_process_alive(self, name: str) -> bool:
        process = self.host_processes.get(name)
        return process is not None and process.poll() is None

    def remote_process_metadata(self, name: str, pid: str, expected: str) -> dict | None:
        code = (
            "import json,os;pid=int(" + repr(pid) + ");expected=" + repr(expected) + ";"
            "raw=open('/proc/%d/stat'%pid).read();tail=raw[raw.rfind(') ')+2:].split();"
            "cmd=open('/proc/%d/cmdline'%pid,'rb').read().replace(b'\\0',b' ').decode(errors='replace').strip();"
            "data={'pid':pid,'starttime':int(tail[19]),'pgrp':os.getpgid(pid),'session':os.getsid(pid),'proc_pgrp':int(tail[2]),'proc_session':int(tail[3]),'cmdline':cmd};"
            "assert expected in cmd;assert data['pgrp']==data['proc_pgrp'];assert data['session']==data['proc_session'];print(json.dumps(data,sort_keys=True))"
        )
        result = self.ssh_result(name, f"python3 -c {q(code)}", check=False)
        if result.returncode != 0:
            return None
        try:
            value = json.loads(result.stdout.decode(errors="replace").strip())
        except json.JSONDecodeError:
            return None
        return value if isinstance(value, dict) else None

    def register_remote_process(self, name: str, kind: str, pid: str, expected: str) -> str:
        key = f"{name}:{kind}"
        metadata = {"name": name, "expected": expected, "pid": str(pid), "run_root": str(self.guest_root), "pgrp": None}
        self.remote_pids[key] = metadata
        self.report["evidence"].setdefault("remote_processes", {})[key] = metadata.copy()
        return key

    def discover_run_processes(self, name: str, expected: str) -> list[dict]:
        code = (
            "import json,os,pathlib;expected=" + repr(expected) + ";root=" + repr(str(self.guest_root)) + ";found=[]\n"
            "for path in pathlib.Path('/proc').glob('[0-9]*'):\n"
            "  try:\n"
            "    pid=int(path.name);raw=path.joinpath('stat').read_text();tail=raw[raw.rfind(') ')+2:].split();cmd=path.joinpath('cmdline').read_bytes().replace(b'\\0',b' ').decode(errors='replace').strip();cwd=os.readlink(path / 'cwd')\n"
            "    if expected not in cmd or not (cwd == root or cwd.startswith(root + '/')): continue\n"
            "    item={'pid':pid,'starttime':int(tail[19]),'pgrp':os.getpgid(pid),'session':os.getsid(pid),'proc_pgrp':int(tail[2]),'proc_session':int(tail[3]),'cmdline':cmd,'cwd':cwd}\n"
            "    if item['pgrp'] == item['proc_pgrp'] and item['session'] == item['proc_session']: found.append(item)\n"
            "  except (FileNotFoundError,PermissionError,ProcessLookupError,ValueError,IndexError,OSError): pass\n"
            "print(json.dumps(found,sort_keys=True))"
        )
        result = self.ssh_result(name, f"timeout 8s python3 -c {q(code)}", check=False)
        if result.returncode != 0:
            return []
        try:
            found = json.loads(result.stdout.decode(errors="replace").strip())
        except json.JSONDecodeError:
            return []
        return found if isinstance(found, list) and all(isinstance(item, dict) for item in found) else []

    def remote_process_alive(self, key: str) -> bool:
        if key not in self.remote_pids:
            return False
        metadata = self.remote_pids[key]
        current = self.remote_process_metadata(metadata["name"], metadata["pid"], metadata["expected"])
        if current is not None:
            current.update({"name": metadata["name"], "expected": metadata["expected"], "run_root": metadata["run_root"]})
        return current == metadata

    def start_host_process(self, name: str, env_values: dict[str, str], log_name: str) -> None:
        if not self.port_free(4010):
            raise Blocker("host port 4010 became occupied before core start")
        env = os.environ.copy()
        env.update(env_values)
        log = (self.logs / log_name).open("ab")
        process = subprocess.Popen(["mix", "phx.server"], cwd=self.source / "server", env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.host_processes[name] = process

    def start_remote_process(self, name: str, kind: str, env_values: dict[str, str], log_name: str, port: int) -> None:
        if not self.guest_port_free(name, port):
            raise Blocker(f"{name} port {port} became occupied before {kind} start")
        assignments = " ".join(f"{q(k)}={q(v)}" for k, v in env_values.items())
        if kind == "fake":
            command = f"cd {q(self.guest_source)} && exec env {assignments} python3 {q(self.guest_source / 'vm' / 'fake_llm.py')}"
            expected = "fake_llm.py"
        else:
            command = f"cd {q(self.guest_source / 'server')} && exec env {assignments} mix phx.server"
            expected = "mix phx.server"
        remote_log = self.guest_logs / log_name
        self.remote_log_paths[f"{name}:{kind}"] = str(remote_log)
        key = self.register_remote_process(name, kind, "", expected)
        pid_text = self.ssh(name, f"nohup setsid bash -lc {q(command)} > {q(remote_log)} 2>&1 < /dev/null & echo $!")
        match = re.search(r"(\d+)\s*$", pid_text)
        if not match:
            raise E2EError(f"could not capture remote {kind} PID on {name}: {pid_text}")
        pid = match.group(1)
        self.remote_pids[key]["pid"] = pid
        self.report["evidence"].setdefault("remote_processes", {})[key]["pid"] = pid
        metadata = self.remote_process_metadata(name, pid, expected)
        if metadata is None:
            raise E2EError(f"could not verify remote {kind} PID ownership on {name}: {pid}")
        metadata.update({"name": name, "expected": expected, "run_root": str(self.guest_root)})
        self.remote_pids[key] = metadata
        self.report["evidence"].setdefault("remote_processes", {})[key] = metadata.copy()
        if not self.remote_process_alive(key):
            raise E2EError(f"remote {kind} PID {pid} on {name} exited before readiness")

    def stop_remote_processes(self) -> dict[str, bool]:
        result = {}
        for key, metadata in list(self.remote_pids.items()):
            name, pgrp = metadata["name"], metadata["pgrp"]
            current = self.remote_process_metadata(name, str(metadata["pid"]), metadata["expected"])
            if current is not None:
                current.update({"name": name, "expected": metadata["expected"], "run_root": metadata["run_root"]})
            candidates = []
            if current == metadata:
                candidates = [current]
            else:
                candidates = self.discover_run_processes(name, metadata["expected"])
            stopped = True
            for candidate in candidates:
                candidate_pgrp = candidate.get("pgrp")
                if not isinstance(candidate_pgrp, int) or candidate_pgrp <= 0:
                    stopped = False
                    continue
                stopped = self.ssh_result(name, f"timeout 8s kill -TERM -- -{q(candidate_pgrp)}", check=False).returncode == 0 and stopped
            if candidates:
                time.sleep(2)
                remaining = self.discover_run_processes(name, metadata["expected"])
                for candidate in remaining:
                    candidate_pgrp = candidate.get("pgrp")
                    if isinstance(candidate_pgrp, int) and candidate_pgrp > 0:
                        stopped = self.ssh_result(name, f"timeout 8s kill -KILL -- -{q(candidate_pgrp)}", check=False).returncode == 0 and stopped
                time.sleep(1)
            result[key] = stopped and not self.discover_run_processes(name, metadata["expected"])
        return result

    def stop_host_processes(self) -> bool:
        for process in self.host_processes.values():
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for process in self.host_processes.values():
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        return all(process.poll() is not None for process in self.host_processes.values()) and self.port_free(4010)

    def wait_http(self, url: str, *, remote: str | None = None, process_key: str | None = None, timeout: int = 90) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if process_key and not self.remote_process_alive(process_key):
                raise E2EError(f"captured process exited before readiness: {process_key}")
            if remote:
                result = self.ssh(remote, f"curl -fsS {q(url)}", check=False)
                if '"status":"ok"' in result.replace(" ", ""):
                    return
            else:
                if not self.host_process_alive("core"):
                    raise E2EError("captured core process exited before readiness")
                try:
                    with urllib.request.urlopen(url, timeout=3) as response:
                        if response.status == 200 and json.loads(response.read()).get("status") == "ok":
                            return
                except (OSError, urllib.error.URLError, json.JSONDecodeError):
                    pass
            time.sleep(1)
        raise E2EError(f"health endpoint did not become ready: {url}")

    def remote_json(self, name: str, url: str) -> dict:
        raw = self.ssh(name, f"curl -fsS {q(url)}")
        value = json.loads(raw)
        if not isinstance(value, dict):
            raise E2EError(f"expected JSON object from {name} {url}")
        return value

    def api(self, method: str, path: str, payload: dict | None = None, token: str | None = None) -> tuple[int, dict]:
        request = urllib.request.Request("http://127.0.0.1:4010" + path, method=method)
        request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(request, data=json.dumps(payload).encode() if payload is not None else None, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def attempts(self) -> list[dict]:
        sql = """SELECT a.id,a.job_id,a.status,COALESCE(a.machine_id,''),COALESCE(j.status,'')
                 FROM job_attempts a JOIN jobs j ON j.id=a.job_id
                 WHERE j.correlation_id='VM_E2E_%s' ORDER BY a.id""" % self.run_id
        rows = self.db_query(sql)
        return [{"id": row[0], "job_id": row[1], "attempt_status": row[2], "machine_id": row[3], "job_status": row[4]} for row in rows if len(row) >= 5]

    def live_containers(self) -> dict[str, list[dict]]:
        found = {"core": [], **{name: [] for name in VM_NAMES}}
        host = self.host_docker_result(["ps", "--no-trunc", "--filter", "label=omashiki.job_scope_id", "--format", "{{.ID}}\t{{.Label \"omashiki.job_scope_id\"}}"])
        for line in host.stdout.decode(errors="replace").splitlines():
            parts = line.split("\t", 1)
            if len(parts) == 2:
                found["core"].append({"id": parts[0], "scope_id": parts[1]})
        for name in VM_NAMES:
            text = self.guest_docker_result(name, "ps --no-trunc --filter label=omashiki.job_scope_id --format '{{.ID}}\\t{{.Label \"omashiki.job_scope_id\"}}'").stdout.decode(errors="replace")
            for line in text.splitlines():
                parts = line.split("\t", 1)
                if len(parts) == 2:
                    found[name].append({"id": parts[0], "scope_id": parts[1]})
        return found

    def run_jobs(self) -> None:
        self.start_host_process("core", {"MIX_ENV": "vm_e2e", "OMASHIKI_NODE": "core", "OMASHIKI_AGENT_NETWORK_MODE": "host", "OBAN_SCHEDULER_LIMIT": "0", "OMASHIKI_DB_PORT": str(self.db_port), "PORT": "4010"}, "core.log")
        self.wait_http("http://127.0.0.1:4010/api/v1/health")
        for name, node in zip(VM_NAMES, ("node-1", "node-2")):
            self.start_remote_process(name, "fake", {"SCENARIO": "python-hello", "LAT_MS": "10000", "JITTER_PCT": "0", "PORT": "8787", "HOST": "127.0.0.1"}, "fake-llm.log", 8787)
            self.start_remote_process(name, "worker", {"MIX_ENV": "vm_e2e", "OMASHIKI_NODE": node, "OMASHIKI_AGENT_NETWORK_MODE": "host", "OBAN_SCHEDULER_LIMIT": "2", "OMASHIKI_DB_PORT": str(self.vm_db_port), "PORT": "4011"}, "omashiki.log", 4011)
            self.wait_http("http://127.0.0.1:8787/healthz", remote=name, process_key=f"{name}:fake")
            self.wait_http("http://127.0.0.1:4011/api/v1/health", remote=name, process_key=f"{name}:worker")
        username = f"vm_e2e_{self.run_id.replace('-', '_')}"
        password = secrets.token_urlsafe(24)
        status, body = self.api("POST", "/api/v1/sessions/signup", {"email": username + "@example.test", "username": username, "password": password, "name": "VM E2E"})
        if status != 201 or not body.get("data", {}).get("token"):
            raise E2EError(f"API signup failed with HTTP {status}: {body}")
        token = body["data"]["token"]
        correlation = "VM_E2E_" + self.run_id
        jobs = []
        markers = {}
        for index in range(1, 5):
            title = f"vm-e2e-{self.run_id}-{index}"
            marker = f"vm-e2e-marker-{self.run_id}-{index}"
            markers[marker] = index
            jobs.append({"ref": title, "idempotency_key": f"{title}-idempotency", "repo": "fixture", "environment": "lt-jcode", "payload": {"instruction": f'Create hello.py containing exactly print("Hello, World!") followed by a newline, then commit it. Test marker: {marker}', "title": title}, "priority": 1})
        status, body = self.api("POST", "/api/v1/jobs/batch", {"schema_version": 1, "correlation_id": correlation, "jobs": jobs}, token)
        if status != 202 or len(body.get("data", [])) != 4:
            raise E2EError(f"batch admission failed with HTTP {status}: {body}")
        self.job_ids = [item["id"] for item in body["data"]]
        self.report["evidence"]["admission"] = {"http_status": status, "job_ids": self.job_ids, "idempotency_keys": [job["idempotency_key"] for job in jobs]}
        deadline = time.monotonic() + 180
        overlap = None
        while time.monotonic() < deadline:
            rows = self.attempts()
            self.attempt_ids = [row["id"] for row in rows]
            active = [row for row in rows if row["attempt_status"] in ("provisioning", "running")]
            if len(rows) == 4 and len(active) == 4:
                containers = self.live_containers()
                entries = [item for values in containers.values() for item in values]
                expected_scopes = {f"job-{row['id']}" for row in active}
                relevant = [item for item in entries if item["scope_id"] in expected_scopes]
                by_scope = {item["scope_id"]: item for item in relevant}
                ids = [item["id"] for item in relevant]
                if len(relevant) == 4 and len(by_scope) == 4 and len(set(ids)) == 4 and set(by_scope) == expected_scopes:
                    overlap = {"observed_at": time.time(), "active_attempts": active, "containers": {row["id"]: {"vm": next(name for name, values in containers.items() if any(item["id"] == by_scope[f"job-{row['id']}"]["id"] for item in values)), "container_id": by_scope[f"job-{row['id']}"]["id"]} for row in active}, "all_live_containers": containers, "relevant_count": len(relevant)}
                    break
            time.sleep(0.25)
        if overlap is None:
            raise E2EError("the four active attempts never overlapped with exactly four distinct labelled containers")
        self.report["evidence"]["overlap"] = overlap
        counts = {node: sum(row["machine_id"] == node for row in overlap["active_attempts"]) for node in ("node-1", "node-2", "core")}
        if counts != {"node-1": 2, "node-2": 2, "core": 0}:
            raise E2EError(f"unexpected active machine distribution: {counts}")
        per_vm = {name: len(values) for name, values in overlap["all_live_containers"].items()}
        if per_vm != {"core": 0, "omashiki-node-1": 2, "omashiki-node-2": 2}:
            raise E2EError(f"unexpected labelled container distribution: {per_vm}")
        for row in overlap["active_attempts"]:
            if overlap["containers"][row["id"]]["vm"] != "omashiki-" + row["machine_id"]:
                raise E2EError(f"attempt {row['id']} has a container on the wrong VM")
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            rows = self.attempts()
            if len(rows) == 4 and all(row["job_status"] == "succeeded" and row["attempt_status"] == "succeeded" for row in rows):
                break
            time.sleep(1)
        else:
            raise E2EError(f"not all four jobs reached success: {self.attempts()}")
        stats = {}
        all_served_markers = set()
        for name in VM_NAMES:
            value = self.remote_json(name, "http://127.0.0.1:8787/__stats")
            served = value.get("job_markers", [])
            if (
                len(served) != 2
                or value.get("requests") != 4
                or value.get("completions") != 4
                or value.get("tool_call_turns") != 2
                or value.get("stops") != 2
                or value.get("peak_in_flight") != 2
                or value.get("job_marker_peak") != 2
                or len(set(served)) != 2
            ):
                raise E2EError(f"fake provider on {name} did not serve two jobs concurrently: {value}")
            all_served_markers.update(served)
            stats[name] = value
        if all_served_markers != set(markers):
            raise E2EError(f"fake provider markers did not exactly cover this run: {sorted(all_served_markers)}")
        self.report["evidence"]["fake_provider_stats"] = stats
        results = []
        for job_id in self.job_ids:
            status, body = self.api("GET", f"/api/v1/jobs/{job_id}/result", token=token)
            if status != 200 or body.get("data", {}).get("status") != "succeeded":
                raise E2EError(f"job {job_id} result failed with HTTP {status}: {body}")
            result = body["data"]
            branch = result.get("branch")
            if not branch or result.get("worktree_clean") is not True:
                raise E2EError(f"job {job_id} did not return a clean worktree result")
            canonical = self.output(["git", "--git-dir", str(self.runtime / "remote.git"), "rev-parse", f"refs/heads/{branch}"])
            if result.get("head_sha") != canonical:
                raise E2EError(f"job {job_id} head SHA does not match canonical remote SHA")
            content = self.local(["git", "--git-dir", str(self.runtime / "remote.git"), "show", f"refs/heads/{branch}:hello.py"], cwd=ROOT).stdout
            if content != HELLO:
                raise E2EError(f"canonical branch {branch} has non-canonical hello.py content")
            exec_dir = self.state / "executed" / branch
            exec_dir.mkdir(parents=True, mode=0o700)
            archive = subprocess.run(["git", "--git-dir", str(self.runtime / "remote.git"), "archive", branch], stdout=subprocess.PIPE, check=True)
            subprocess.run(["tar", "-x", "-C", str(exec_dir)], input=archive.stdout, check=True)
            run = subprocess.run(["python3", str(exec_dir / "hello.py")], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            if run.returncode != 0 or run.stdout != b"Hello, World!\n" or run.stderr != b"":
                raise E2EError(f"executing {branch}: expected exact Hello, World! output")
            results.append({"job_id": job_id, "branch": branch, "head_sha": result.get("head_sha"), "hello_sha": canonical, "worktree_clean": result.get("worktree_clean")})
        self.report["evidence"]["results"] = results
        if len({result["branch"] for result in results}) != 4:
            raise E2EError("the four results did not produce four unique branches")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and any(self.live_containers().values()):
            time.sleep(1)
        remaining = self.live_containers()
        if any(remaining.values()):
            raise E2EError(f"labelled containers remain after terminal success: {remaining}")
        for name in VM_NAMES:
            worktrees = self.ssh(name, f"git -C {q('/home/fedora/' + REMOTE_MIRROR)} worktree list --porcelain", check=False)
            if ".omashiki-worktrees/" in worktrees:
                raise E2EError(f"worktrees remain on {name}: {worktrees}")
        capacity = self.db_query("SELECT machine_id,capacity,active FROM execution_capacity ORDER BY machine_id")
        capacity_rows = [{"machine_id": row[0], "capacity": int(row[1]), "active": int(row[2])} for row in capacity if len(row) >= 3]
        if {row["machine_id"] for row in capacity_rows} != {"core", "node-1", "node-2"} or any(row["active"] != 0 for row in capacity_rows):
            raise E2EError(f"execution capacity is not drained: {capacity_rows}")
        self.report["evidence"]["capacity"] = capacity_rows

    def cleanup_step(self, key: str, function) -> object | None:
        try:
            value = function()
            self.report["cleanup"][key] = value
            return value
        except Exception as error:
            self.cleanup_errors.append(f"{key}: {error}")
            self.report["cleanup"][key] = False
            self.log(f"cleanup failure ({key}): {error}")
            return None

    def cleanup_is_complete(self, remote_stopped: object) -> bool:
        required = ["host_processes_stopped", "reverse_tunnels_stopped", "evidence_logs_copied", "temporary_auth_removed", "runtime_removed", "database_removed", "labelled_containers_absent", "new_vms_stopped", "vms_definitions_preserved", "guest_known_hosts_additions_removed"]
        required.extend(f"{name}_containers_removed" for name in VM_NAMES)
        required.extend(f"{name}_known_hosts_additions_removed" for name in VM_NAMES)
        complete = not self.cleanup_errors and all(self.report["cleanup"].get(key) is True for key in required)
        image_status = self.report["cleanup"].get("image_removed")
        selinux_status = self.report["cleanup"].get("selinux")
        complete = complete and isinstance(image_status, dict) and all(image_status.values())
        complete = complete and isinstance(selinux_status, dict) and selinux_status.get("all_restored") is True
        complete = complete and (not self.remote_pids or isinstance(remote_stopped, dict) and set(remote_stopped) == set(self.remote_pids) and all(remote_stopped.values()))
        return complete

    def cleanup(self) -> None:
        self.in_cleanup = True
        remote_stopped = self.cleanup_step("remote_process_groups_stopped", self.stop_remote_processes) if self.remote_pids else {}
        self.report["cleanup"]["remote_process_groups_stopped"] = remote_stopped if self.remote_pids else {}
        self.cleanup_step("host_processes_stopped", self.stop_host_processes)
        tunnel_stopped = self.cleanup_step("reverse_tunnels_stopped", self.stop_tunnels)
        self.report["cleanup"]["reverse_tunnels_stopped"] = bool(tunnel_stopped)
        logs_copied = True
        for key, remote_log in self.remote_log_paths.items():
            name, kind = key.split(":", 1)
            try:
                copied = self.scp_from(name, remote_log, self.logs / f"{name}-{kind}.log")
            except Exception as error:
                copied = False
                self.cleanup_errors.append(f"evidence_logs_copied:{key}: {error}")
                self.log(f"cleanup failure (evidence log {key}): {error}")
            self.report["cleanup"][f"evidence_log_{name}_{kind}"] = copied
            logs_copied = copied and logs_copied
        self.report["cleanup"]["evidence_logs_copied"] = logs_copied
        if not logs_copied:
            self.cleanup_errors.append("evidence_logs_copied: one or more remote logs could not be copied")
        for name in VM_NAMES:
            if name in self.vm_ips:
                removed = self.cleanup_step(f"{name}_containers_removed", lambda name=name: self.remove_guest_containers(name))
                self.report["cleanup"][f"{name}_containers_removed"] = bool(removed)
            else:
                self.report["cleanup"][f"{name}_containers_removed"] = False
        self.cleanup_step("core_containers_removed", self.remove_host_containers)
        auth_removed = True
        if self.authorized_line and self.authorized_added:
            result = self.cleanup_step("temporary_authorized_key_removed", lambda: self.atomic_line_update(HOST_HOME / ".ssh" / "authorized_keys", remove=[self.authorized_line]))
            auth_removed = bool(result and self.authorized_line in result.get("removed", []))
        self.report["cleanup"]["temporary_auth_removed"] = auth_removed
        if self.vm_ips:
            known_removed = True
            for name in VM_NAMES:
                if self.vm_known_added[name]:
                    result = self.cleanup_step(f"{name}_known_hosts_additions_removed", lambda name=name: self.remote_line_update(name, "/home/fedora/.ssh/known_hosts", remove=self.vm_known_added[name]))
                    removed = bool(result is not None and set(result.get("removed", [])) == set(self.vm_known_added[name]))
                    self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = removed
                else:
                    removed = True
                    self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = True
                known_removed = known_removed and removed
            self.report["cleanup"]["guest_known_hosts_additions_removed"] = known_removed
        else:
            for name in VM_NAMES:
                self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = False
            self.report["cleanup"]["guest_known_hosts_additions_removed"] = False
        self.report["cleanup"]["host_known_hosts_additions_removed"] = True
        runtime_removed = self.cleanup_step("runtime_removed", self.remove_runtime)
        self.report["cleanup"]["runtime_removed"] = bool(runtime_removed)
        db_removed = self.cleanup_step("database_removed", self.remove_db)
        self.report["cleanup"]["database_removed"] = bool(db_removed)
        image_removed = self.cleanup_step("image_removed", self.remove_images)
        self.report["cleanup"]["image_removed"] = image_removed or False
        selinux = self.cleanup_step("selinux", self.restore_selinux)
        self.report["cleanup"]["selinux"] = selinux or False
        containers_absent = self.cleanup_step("labelled_containers_absent", self.verify_no_labelled_containers)
        self.report["cleanup"]["labelled_containers_absent"] = bool(containers_absent)
        stopped_vms = self.cleanup_step("new_vms_stopped", self.stop_started_vms)
        self.report["cleanup"]["new_vms_stopped"] = bool(stopped_vms)
        vms_preserved = self.cleanup_step("vms_definitions_preserved", self.verify_owned_domains)
        self.report["cleanup"]["vms_definitions_preserved"] = bool(vms_preserved)
        complete = self.cleanup_is_complete(remote_stopped)
        self.report["cleanup"]["complete"] = complete
        self.report["cleanup"]["errors"] = self.cleanup_errors
        self.in_cleanup = False

    def stop_tunnels(self) -> bool:
        for process in self.tunnels:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for process in self.tunnels:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        tunnel_stopped = all(process.poll() is not None for process in self.tunnels)
        if self.vm_ips and self.vm_db_port:
            tunnel_stopped = tunnel_stopped and all(self.guest_port_free(name, self.vm_db_port) for name in VM_NAMES)
        return tunnel_stopped

    def remove_guest_containers(self, name: str) -> bool:
        self.guest_docker_result(name, "ps -aq --filter label=omashiki.job_scope_id")
        for attempt_id in self.attempt_ids:
            ids = self.guest_docker_result(name, f"ps -aq --filter label=omashiki.job_scope_id=job-{q(attempt_id)}").stdout.decode(errors="replace").strip()
            if ids:
                self.guest_docker_result(name, f"rm -f $(sudo -n docker ps -aq --filter label=omashiki.job_scope_id=job-{q(attempt_id)})")
        return not any(item for item in self.live_containers().get(name, []))

    def remove_host_containers(self) -> bool:
        self.host_docker_result(["ps", "-aq", "--filter", "label=omashiki.job_scope_id"])
        for attempt_id in self.attempt_ids:
            ids = self.host_docker_result(["ps", "-aq", "--filter", f"label=omashiki.job_scope_id=job-{attempt_id}"]).stdout.decode(errors="replace").split()
            for container_id in ids:
                self.host_docker_result(["rm", "-f", container_id])
        return not self.live_containers()["core"]

    def stop_started_vms(self) -> bool:
        managed = self.vm_started_by_run | self.vm_created_by_run
        for name in VM_NAMES:
            if name not in managed:
                continue
            initial = self.vm_initial_state.get(name)
            if initial not in (None, "shut off"):
                continue
            if self.virsh(["domstate", name], check=False) == "running":
                self.local(["virsh", "-c", "qemu:///system", "shutdown", name], check=False)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if all(name not in managed or self.vm_initial_state.get(name) not in (None, "shut off") or self.virsh(["domstate", name], check=False) == "shut off" for name in VM_NAMES):
                return True
            time.sleep(1)
        return all(name not in managed or self.vm_initial_state.get(name) not in (None, "shut off") or self.virsh(["domstate", name], check=False) == "shut off" for name in VM_NAMES)

    def verify_owned_domains(self) -> bool:
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        verification = {"created_by_run": sorted(self.vm_created_by_run), "domains": {}, "all_valid": True}
        for name in VM_NAMES:
            if name not in domains:
                verification["domains"][name] = {"valid": False, "reason": "missing domain"}
                verification["all_valid"] = False
                self.report["evidence"]["domain_verification"] = verification
                return False
            current = self.domain_snapshot(name, self.virsh(["domstate", name], check=False))
            initial = self.vm_initial_snapshots.get(name, {})
            if name in self.vm_created_by_run:
                valid = (current["initial_state"] == "shut off"
                         and self.domain_owned(name, current["domain_xml"] or "", current["volume"]["xml"] or "", self.libvirt_base_path)
                         and current["volume"]["path"] == f"/var/lib/libvirt/images/{name}.qcow2")
                comparison = {"mode": "created", "state": current["initial_state"], "expected_state": "shut off", "definition_valid": valid}
            else:
                initial_volume = initial.get("volume", {})
                current_volume = current["volume"]
                valid = (current["initial_state"] == initial.get("initial_state")
                         and current["domain_xml"] == initial.get("domain_xml")
                         and current_volume.get("info") == initial_volume.get("info")
                         and current_volume.get("xml") == initial_volume.get("xml")
                         and current_volume.get("path") == initial_volume.get("path")
                         and current_volume.get("backing_path") == initial_volume.get("backing_path")
                         and current_volume.get("target_path") == initial_volume.get("target_path")
                         and current_volume.get("network") == initial_volume.get("network"))
                comparison = {"mode": "existing", "state": current["initial_state"], "expected_state": initial.get("initial_state"), "definition_exact": valid}
            verification["domains"][name] = {"valid": valid, "initial": initial, "final": current, "comparison": comparison}
            verification["all_valid"] = verification["all_valid"] and valid
        self.report["evidence"]["domain_verification"] = verification
        return verification["all_valid"]

    def remove_runtime(self) -> bool:
        if self.runtime.exists():
            try:
                self.reject_symlink(self.runtime, "run runtime")
                if self.runtime.stat().st_uid != os.getuid() or self.runtime.name != f"omashiki-vm-e2e-{self.run_id}":
                    raise E2EError("runtime ownership/name verification failed")
                shutil.rmtree(self.runtime)
            except Exception as error:
                self.cleanup_errors.append(f"runtime_removed: {error}")
                return False
        guest = True
        for name in VM_NAMES:
            if name in self.vm_ips:
                safe_remove = f"if [ -e {q(self.guest_root)} ]; then test -d {q(self.guest_root)} && test ! -L {q(self.guest_root)} && test \"$(stat -c %u {q(self.guest_root)})\" = \"$(id -u)\" && rm -rf -- {q(self.guest_root)}; fi; test ! -e {q(self.guest_root)} && test ! -L {q(self.guest_root)} && printf removed"
                guest = guest and self.ssh(name, safe_remove, check=False) == "removed"
        return not self.runtime.exists() and guest

    def remove_db(self) -> bool:
        if not self.db_container:
            return True
        inspect = self.host_docker_inspect(["inspect", "-f", "{{index .Config.Labels \"omashiki.vm_e2e\"}}", self.db_container])
        if inspect.returncode != 0:
            text = inspect.stdout.decode(errors="replace").lower()
            if "no such object" in text:
                return True
            raise E2EError(f"database container inspection failed: {text[-500:]}")
        if inspect.stdout.decode().strip() != self.run_id:
            raise E2EError("database container ownership label did not match this run")
        removed = self.host_docker_result(["rm", "-f", self.db_container])
        if removed.returncode != 0:
            raise E2EError("database container removal failed")
        final = self.host_docker_inspect(["inspect", self.db_container])
        if final.returncode == 0:
            return False
        text = final.stdout.decode(errors="replace").lower()
        if "no such object" in text:
            return True
        raise E2EError(f"database container final inspection failed: {text[-500:]}")

    def remove_images(self) -> dict[str, bool]:
        removed = {}
        if not self.host_image_absent():
            self.host_docker_result(["image", "rm", "-f", self.image])
        removed["host"] = self.host_image_absent()
        for name in VM_NAMES:
            if name in self.vm_ips:
                if not self.guest_image_absent(name):
                    self.guest_docker_result(name, f"image rm -f {q(self.image)}")
                removed[name] = self.guest_image_absent(name)
        return removed

    def restore_selinux(self) -> dict:
        restored = {}
        for name, initial in self.vm_selinux_initial.items():
            if name in self.vm_selinux_disabled:
                self.ssh(name, "sudo -n setenforce 1", check=False)
            restored[name] = self.ssh(name, "getenforce", check=False) == initial
        return {"initial": self.vm_selinux_initial, "changed_to_permissive": sorted(self.vm_selinux_disabled), "restored": restored, "all_restored": all(restored.values()) if restored else True, "exercised_enforcing_mode": False}

    def verify_no_labelled_containers(self) -> bool:
        self.host_docker_result(["ps", "-a", "--filter", "label=omashiki.vm_e2e=" + self.run_id, "-q"])
        host_labels = self.host_docker_result(["ps", "-a", "--format", "{{.Label \"omashiki.job_scope_id\"}}"]).stdout.decode(errors="replace").splitlines()
        absent = not any(label in {f"job-{attempt}" for attempt in self.attempt_ids} for label in host_labels)
        for name in VM_NAMES:
            if name in self.vm_ips:
                labels = self.guest_docker_result(name, "ps -a --format '{{.Label \"omashiki.job_scope_id\"}}'").stdout.decode(errors="replace").splitlines()
                absent = absent and not any(label in {f"job-{attempt}" for attempt in self.attempt_ids} for label in labels)
        return absent

    def handle_signal(self, signum, _frame) -> None:
        self.signal_reason = signal.Signals(signum).name
        if not self.in_cleanup:
            raise E2EError(f"received {self.signal_reason}; entering cleanup")

    def run(self) -> int:
        exit_code = 1
        old_handlers = {name: signal.getsignal(getattr(signal, name)) for name in ("SIGINT", "SIGTERM", "SIGHUP")}
        for name in old_handlers:
            signal.signal(getattr(signal, name), self.handle_signal)
        try:
            self.acquire_lock()
            access_pub = self.preflight()
            host_ip = self.host_ip()
            self.copy_source()
            self.render_config(host_ip)
            self.ensure_vms(access_pub)
            self.report["evidence"]["preflight"]["created_by_run"] = sorted(self.vm_created_by_run)
            self.write_report()
            self.generate_git_key()
            self.setup_ssh(host_ip)
            self.create_remote(host_ip)
            self.start_db()
            self.prepare_host()
            self.local(["docker", "build", "-t", self.image, "-f", "agent/Dockerfile.jcode", "agent"], cwd=self.source)
            self.sync_workers()
            self.start_tunnels()
            self.run_jobs()
            self.report["status"] = "succeeded"
            exit_code = 0
        except Blocker as error:
            self.failed = True
            self.report["status"] = "blocked"
            self.report["error"] = str(error)
            self.log(f"BLOCKER: {error}")
            exit_code = 2
        except Exception as error:
            self.failed = True
            self.report["status"] = "failed"
            self.report["error"] = str(error)
            self.log(f"FAILURE: {error}")
            exit_code = 1
        finally:
            if self.signal_reason:
                self.report["signal"] = self.signal_reason
            try:
                self.write_report()
                self.cleanup()
            except Exception as error:
                self.cleanup_errors.append(str(error))
                self.report["cleanup"]["complete"] = False
                self.report["cleanup"]["errors"] = self.cleanup_errors
                self.log(f"cleanup failure: {error}")
            if not self.report.get("cleanup", {}).get("complete", False):
                self.report["status"] = "failed_cleanup" if exit_code == 0 else self.report["status"]
                if exit_code == 0:
                    exit_code = 1
            self.write_report()
            if self.lock_file is not None:
                if self.lock_acquired:
                    fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_UN)
                self.lock_file.close()
            for name, handler in old_handlers.items():
                signal.signal(getattr(signal, name), handler)
            os.umask(self.previous_umask)
        if exit_code == 0:
            self.log(f"VM E2E succeeded; report: {self.report_path}")
        return exit_code


if __name__ == "__main__":
    sys.exit(Harness().run())
