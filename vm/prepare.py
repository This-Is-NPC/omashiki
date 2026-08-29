#!/usr/bin/env python3
"""Build and atomically publish the prepared VM E2E base image."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).parent))

from e2e import HOST_HOME, LOCK_PATH, PUBLIC_KEY_RE, ROOT, VIRT_INSTALL, Blocker, load_manifest  # noqa: E402
from prepared import (  # noqa: E402
    PreparedBaseError,
    atomic_write_json,
    preparation_fingerprint,
    prepared_paths,
    sha256_file,
    verify_prepared_base,
)


def q(value: object) -> str:
    return shlex.quote(str(value))


class Preparer:
    def __init__(self, manifest_path: Path) -> None:
        self.manifest_path = manifest_path
        self.manifest = load_manifest(manifest_path)
        self.fingerprint = preparation_fingerprint(self.manifest, manifest_path)
        self.host_path, self.final_volume = prepared_paths(self.manifest, self.fingerprint)
        self.pointer_path = Path(self.manifest["prepared"]["pointer"]).expanduser()
        self.pending_path = Path(self.manifest["prepared"]["pending"]).expanduser()
        self.base = self.manifest["base"]
        self.vm = self.manifest["vm"]
        self.runtime = self.manifest["runtime"]
        self.kata = self.runtime["kata"]
        self.pool = self.base["pool"]
        self.qemu_uri = self.base["qemu_uri"]
        self.guest_user = self.manifest["topology"]["guest_user"]
        self.name = f"{self.manifest['topology']['domain_prefix']}-prep-{self.fingerprint[:12]}"
        self.volume = f"{self.name}.qcow2"
        self.marker = f"{self.manifest['project']['ownership_marker']};phase=prepare"
        self.run_id = time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)
        self.state = Path("/tmp") / f"omashiki-vm-prepare-{self.run_id}"
        self.known_hosts = self.state / "known_hosts"
        cache_home = Path(os.environ.get("XDG_CACHE_HOME", HOST_HOME / ".cache")).expanduser()
        self.kata_bundle = cache_home / "omashiki" / "vm-e2e" / self.kata["archive"]
        self.candidate_path = self.host_path.parent / f".{self.fingerprint}.candidate.qcow2"
        self.lock = None
        self.vm_ip = ""

    def log(self, message: str) -> None:
        print(message, flush=True)

    def run(self, args: list[str], *, check: bool = True, timeout: int | None = None,
            input_data: bytes | None = None) -> subprocess.CompletedProcess:
        self.log("$ " + " ".join(q(value) for value in args))
        result = subprocess.run(args, input=input_data, timeout=timeout)
        if check and result.returncode != 0:
            raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}")
        return result

    def output(self, args: list[str], *, check: bool = True) -> str:
        result = subprocess.run(args, check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if check and result.returncode != 0:
            raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout[-1000:]}")
        return result.stdout.strip()

    def virsh(self, args: list[str], *, check: bool = True) -> str:
        return self.output(["virsh", "-c", self.qemu_uri, *args], check=check)

    def acquire_lock(self) -> None:
        if LOCK_PATH.is_symlink():
            raise Blocker(f"refusing symlinked VM E2E lock: {LOCK_PATH}")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(LOCK_PATH, flags, 0o600)
        opened = os.fstat(fd)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                or stat.S_IMODE(opened.st_mode) & 0o077):
            os.close(fd)
            raise Blocker(f"VM E2E lock has unsafe owner, type, or mode: {LOCK_PATH}")
        self.lock = os.fdopen(fd, "a+")
        self.log("waiting for the exclusive VM preparation lock")
        fcntl.flock(self.lock.fileno(), fcntl.LOCK_EX)

    def release_lock(self) -> None:
        if self.lock is not None:
            fcntl.flock(self.lock.fileno(), fcntl.LOCK_UN)
            self.lock.close()
            self.lock = None

    def ensure_private_directory(self, path: Path) -> None:
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid():
            raise Blocker(f"unsafe preparation directory: {path}")
        if stat.S_IMODE(metadata.st_mode) & 0o022:
            raise Blocker(f"preparation directory is group/world writable: {path}")
        os.chmod(path, 0o700)

    def current_is_valid(self) -> bool:
        if not self.pointer_path.exists() and not self.pointer_path.is_symlink():
            return False
        try:
            pointer = verify_prepared_base(self.manifest, self.manifest_path, self.qemu_uri)
        except PreparedBaseError as error:
            metadata = self.pointer_path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise Blocker(str(error)) from error
            try:
                previous = json.loads(self.pointer_path.read_text())
            except (OSError, json.JSONDecodeError) as parse_error:
                raise Blocker(str(error)) from parse_error
            old_fingerprint = previous.get("fingerprint") if isinstance(previous, dict) else None
            if not isinstance(old_fingerprint, str) or not re.fullmatch(r"[0-9a-f]{64}", old_fingerprint):
                raise Blocker(str(error)) from error
            if old_fingerprint == self.fingerprint:
                raise Blocker(str(error)) from error
            self.log(f"prepared base {old_fingerprint[:12]} is stale; building {self.fingerprint[:12]}")
            return False
        self.log(f"prepared base is already valid: {pointer['fingerprint']}")
        return True

    def validate_source(self) -> None:
        source = Path(self.base["path"]).expanduser()
        if source.is_symlink() or not source.is_file():
            raise Blocker(f"source Fedora base is unavailable: {source}")
        metadata = source.stat()
        if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise Blocker("source Fedora base has unsafe owner or permissions")
        actual = sha256_file(source)
        if actual != self.base["sha256"]:
            raise Blocker(f"source Fedora base checksum differs: {actual}")
        volume_path = self.virsh(["vol-path", self.base["volume"], "--pool", self.pool])
        if sha256_file(volume_path) != actual:
            raise Blocker("source Fedora host and libvirt images differ")

    def ensure_kata_bundle(self) -> None:
        self.ensure_private_directory(self.kata_bundle.parent.parent)
        self.ensure_private_directory(self.kata_bundle.parent)
        if self.kata_bundle.exists() or self.kata_bundle.is_symlink():
            metadata = self.kata_bundle.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
                raise Blocker("cached Kata archive has unsafe type or owner")
            if stat.S_IMODE(metadata.st_mode) & 0o022:
                raise Blocker("cached Kata archive has unsafe permissions")
            if sha256_file(self.kata_bundle) == self.kata["sha256"]:
                return
            self.kata_bundle.unlink()
        fd, temporary = tempfile.mkstemp(prefix=".kata.", suffix=".part", dir=self.kata_bundle.parent)
        os.close(fd)
        candidate = Path(temporary)
        try:
            self.run(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
                      "--progress-bar", "--output", str(candidate), self.kata["url"]], timeout=1800)
            if sha256_file(candidate) != self.kata["sha256"]:
                raise Blocker("downloaded Kata archive checksum differs")
            os.chmod(candidate, 0o600)
            os.replace(candidate, self.kata_bundle)
        finally:
            candidate.unlink(missing_ok=True)

    def volume_root(self, xml: str, name: str) -> ET.Element:
        try:
            root = ET.fromstring(xml)
        except ET.ParseError as error:
            raise Blocker(f"libvirt volume XML is invalid for {name}") from error
        if root.tag != "volume" or root.findtext("./name") != name:
            raise Blocker(f"libvirt volume identity differs for {name}")
        return root

    def expected_pool_path(self, name: str) -> str:
        base_path = Path(self.virsh(["vol-path", self.base["volume"], "--pool", self.pool]))
        return str(base_path.parent / name)

    def staging_volume_owned(self, xml: str) -> bool:
        root = self.volume_root(xml, self.volume)
        target_format = root.find("./target/format")
        try:
            capacity = int(root.findtext("./capacity", ""))
        except ValueError:
            return False
        return (
            root.findtext("./target/path") == self.expected_pool_path(self.volume)
            and target_format is not None
            and target_format.attrib == {"type": "qcow2"}
            and root.findtext("./backingStore/path") == self.expected_pool_path(self.base["volume"])
            and capacity == self.vm["disk_gib"] * 1024 ** 3
        )

    def domain_owned(self, xml: str) -> bool:
        try:
            root = ET.fromstring(xml)
        except ET.ParseError:
            return False
        sources = root.findall("./devices/disk[@device='disk']/source")
        source = sources[0] if len(sources) == 1 else None
        return (
            root.tag == "domain"
            and root.findtext("./name") == self.name
            and root.findtext("./title") == self.marker
            and source is not None
            and source.get("file") == self.expected_pool_path(self.volume)
            and set(source.attrib) <= {"file", "index"}
            and ("index" not in source.attrib or source.attrib["index"].isdigit())
        )

    def cleanup_candidate(self) -> None:
        if not self.candidate_path.exists() and not self.candidate_path.is_symlink():
            return
        metadata = self.candidate_path.lstat()
        if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) & 0o022):
            raise Blocker(f"refusing unsafe prepared candidate: {self.candidate_path}")
        self.candidate_path.unlink()

    def cleanup_owned_staging(self) -> None:
        domains = set(self.virsh(["list", "--all", "--name"], check=False).splitlines())
        if any(line.startswith("error:") for line in domains):
            raise Blocker("could not list libvirt domains during preparation cleanup")
        domain_xml = self.virsh(["dumpxml", self.name], check=False) if self.name in domains else ""
        volume_xml = self.virsh(["vol-dumpxml", self.volume, "--pool", self.pool], check=False)
        volume_exists = bool(volume_xml and "not found" not in volume_xml.lower() and "no storage vol" not in volume_xml.lower())
        if domain_xml and not volume_exists:
            raise Blocker(f"refusing to remove preparation domain {self.name} without its validated volume")
        if domain_xml and not self.domain_owned(domain_xml):
            raise Blocker(f"refusing to remove unowned preparation domain {self.name}")
        if volume_exists and not self.staging_volume_owned(volume_xml):
            raise Blocker(f"refusing to remove unowned preparation volume {self.volume}")
        if self.name in domains:
            state = self.virsh(["domstate", self.name], check=False)
            if state not in ("running", "shut off"):
                raise Blocker(f"preparation domain is in an unsafe state: {state}")
            if state != "shut off":
                self.run(["virsh", "-c", self.qemu_uri, "destroy", self.name], check=False)
            self.run(["virsh", "-c", self.qemu_uri, "undefine", self.name])
        if volume_exists:
            self.run(["virsh", "-c", self.qemu_uri, "vol-delete", self.volume, "--pool", self.pool])

    def recover_pending_publication(self) -> None:
        if not self.pending_path.exists() and not self.pending_path.is_symlink():
            return
        metadata = self.pending_path.lstat()
        if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o600):
            raise Blocker("pending preparation journal is unsafe")
        try:
            pending = json.loads(self.pending_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise Blocker("pending preparation journal is invalid") from error
        if not isinstance(pending, dict) or set(pending) != {"fingerprint", "host_path", "volume"}:
            raise Blocker("pending preparation journal schema is invalid")
        fingerprint = pending["fingerprint"]
        try:
            expected_host, expected_volume = prepared_paths(self.manifest, fingerprint)
        except PreparedBaseError as error:
            raise Blocker("pending preparation journal fingerprint is invalid") from error
        if pending["host_path"] != str(expected_host) or pending["volume"] != expected_volume:
            raise Blocker("pending preparation journal paths are invalid")
        volume = self.virsh(["vol-info", expected_volume, "--pool", self.pool], check=False)
        if volume and "not found" not in volume.lower() and "no storage vol" not in volume.lower():
            volume_xml = self.virsh(["vol-dumpxml", expected_volume, "--pool", self.pool])
            volume_root = self.volume_root(volume_xml, expected_volume)
            target_format = volume_root.find("./target/format")
            if (volume_root.findtext("./target/path") != self.expected_pool_path(expected_volume)
                    or target_format is None or target_format.attrib != {"type": "qcow2"}
                    or volume_root.find("./backingStore") is not None):
                raise Blocker("refusing to remove an unsafe pending libvirt volume")
            self.run(["virsh", "-c", self.qemu_uri, "vol-delete", expected_volume, "--pool", self.pool])
        if expected_host.exists() or expected_host.is_symlink():
            host_metadata = expected_host.lstat()
            if (stat.S_ISLNK(host_metadata.st_mode) or not stat.S_ISREG(host_metadata.st_mode)
                    or host_metadata.st_uid != os.getuid() or stat.S_IMODE(host_metadata.st_mode) & 0o022):
                raise Blocker("refusing to remove an unsafe pending host image")
            expected_host.unlink()
        self.pending_path.unlink()

    def render_cloud_init(self, public_key: str) -> Path:
        template_path = ROOT / self.manifest["prepared"]["cloud_init"]
        template = template_path.read_text()
        rendered = template.replace("{{HOSTNAME}}", self.name).replace("{{SSH_PUBLIC_KEY}}", public_key).replace("{{GUEST_USER}}", self.guest_user)
        target = self.state / "cloud-init.yaml"
        target.write_text(rendered)
        os.chmod(target, 0o600)
        return target

    def validated_public_key(self) -> str:
        public = HOST_HOME / ".ssh" / "id_vms.pub"
        if public.is_symlink() or not public.is_file():
            raise Blocker(f"VM public key is unavailable or unsafe: {public}")
        raw = public.read_text()
        lines = raw.splitlines()
        if len(lines) != 1 or raw.endswith("\n\n") or not PUBLIC_KEY_RE.fullmatch(lines[0]):
            raise Blocker("~/.ssh/id_vms.pub must contain exactly one safe OpenSSH public-key line")
        if self.run(["ssh-keygen", "-lf", str(public)], check=False).returncode != 0:
            raise Blocker("~/.ssh/id_vms.pub is not accepted by ssh-keygen")
        return lines[0]

    def create_builder(self, cloud_init: Path) -> None:
        self.run(["virsh", "-c", self.qemu_uri, "vol-create-as", self.pool, self.volume,
                  f"{self.vm['disk_gib']}G", "--format", "qcow2", "--backing-vol",
                  self.base["volume"], "--backing-vol-format", "qcow2"])
        self.run([*VIRT_INSTALL, "--connect", self.qemu_uri, "--name", self.name,
                  "--memory", str(self.vm["memory_mib"]), "--vcpus", str(self.vm["vcpus"]),
                  "--cpu", "host-passthrough", "--disk", f"vol={self.pool}/{self.volume},format=qcow2,bus=virtio",
                  "--import", "--os-variant", "generic", "--network", f"network={self.vm['network']},model=virtio",
                  "--graphics", "none", "--console", "pty,target_type=serial", "--metadata",
                  f"title={self.marker}", "--cloud-init", f"user-data={cloud_init}", "--autoconsole", "none"])

    def wait_for_ssh(self) -> None:
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            addresses = self.virsh(["domifaddr", self.name], check=False)
            match = re.search(r"(\d+\.\d+\.\d+\.\d+)/\d+", addresses)
            if match:
                self.vm_ip = match.group(1)
                scan = subprocess.run(["ssh-keyscan", "-T", "5", "-t", "ed25519", self.vm_ip],
                                      check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                if scan.returncode == 0 and scan.stdout:
                    self.known_hosts.write_bytes(scan.stdout)
                    os.chmod(self.known_hosts, 0o600)
                    try:
                        authenticated = subprocess.run(
                            [*self.ssh_args(), "true"], check=False,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=20,
                        )
                    except subprocess.TimeoutExpired:
                        authenticated = None
                    if authenticated is not None and authenticated.returncode == 0:
                        return
            time.sleep(3)
        raise RuntimeError("prepared VM did not become reachable over SSH")

    def ssh_args(self) -> list[str]:
        return ["ssh", "-i", str(HOST_HOME / ".ssh" / "id_vms"), "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=12",
                "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts}",
                f"{self.guest_user}@{self.vm_ip}"]

    def ssh(self, script: str, *, timeout: int = 1800) -> None:
        self.run([*self.ssh_args(), "bash", "-lc", q(script)], timeout=timeout)

    def scp(self, source: Path, destination: str) -> None:
        self.run(["scp", "-q", "-i", str(HOST_HOME / ".ssh" / "id_vms"), "-o", "BatchMode=yes",
                  "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=12",
                  "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={self.known_hosts}",
                  str(source), f"{self.guest_user}@{self.vm_ip}:{destination}"], timeout=1800)

    def install_kata(self) -> None:
        remote_archive = f"/tmp/{self.kata['archive']}"
        self.scp(self.kata_bundle, remote_archive)
        daemon = json.dumps({"runtimes": {"kata": {"runtimeType": self.kata["runtime_path"], "options": {"ConfigPath": self.kata["config_path"]}}}}, sort_keys=True)
        script = f'''set -euo pipefail
test "$(sha256sum {q(remote_archive)} | cut -d' ' -f1)" = {q(self.kata['sha256'])}
stage=$(mktemp -d /tmp/omashiki-kata.XXXXXX)
trap 'sudo -n rm -rf -- "$stage"; rm -f -- {q(remote_archive)}' EXIT
sudo -n zstd -dc -- {q(remote_archive)} | sudo -n tar --no-same-owner -x -C "$stage"
sudo -n install -d -m 0755 /opt/kata
sudo -n cp -a "$stage/opt/kata"/. /opt/kata/
sudo -n install -d -m 0755 /etc/docker
printf '%s\n' {q(daemon)} | sudo -n tee /etc/docker/daemon.json >/dev/null
sudo -n dockerd --validate --config-file=/etc/docker/daemon.json
sudo -n systemctl restart docker
sudo -n docker info --format '{{{{json .Runtimes}}}}' | grep -q '"kata"'
sudo -n test -x {q(self.kata['runtime_path'])}
sudo -n test -x {q(self.kata['hypervisor_path'])}
'''
        self.ssh(script)

    def prime_server_cache(self) -> None:
        rsync_ssh = "ssh " + " ".join(q(value) for value in self.ssh_args()[1:-1])
        source = ROOT / "server"
        destination = f"{self.guest_user}@{self.vm_ip}:/tmp/omashiki-server-cache/"
        self.run(["rsync", "-az", "--delete", "--include=/mix.exs", "--include=/mix.lock",
                  "--include=/config/***", "--exclude=*", "-e", rsync_ssh, f"{source}/", destination], timeout=600)
        self.ssh('''set -euo pipefail
sudo -n rm -rf /opt/omashiki-e2e/server-cache
sudo -n install -d -o "$USER" -g "$USER" -m 0755 /opt/omashiki-e2e/server-cache
cp -a /tmp/omashiki-server-cache/. /opt/omashiki-e2e/server-cache/
cd /opt/omashiki-e2e/server-cache
cat > config/vm_e2e.exs <<'EOF'
import Config

import_config "dev.exs"

config :omashiki, OmashikiWeb.Endpoint,
  watchers: nil,
  code_reloader: false,
  live_reload: nil
EOF
MIX_ENV=vm_e2e mix local.hex --force
MIX_ENV=vm_e2e mix local.rebar --force
MIX_ENV=vm_e2e mix deps.get
MIX_ENV=vm_e2e mix deps.compile
rm -rf /tmp/omashiki-server-cache
''')

    def validate_guest(self) -> None:
        self.ssh('''set -euo pipefail
selinux=$(getenforce)
restore_selinux() {
  if [ "$selinux" = Enforcing ]; then sudo -n setenforce 1; fi
}
trap restore_selinux EXIT
if [ "$selinux" = Enforcing ]; then sudo -n setenforce 0; fi
command -v docker
command -v mix
command -v rsync
sudo -n test -c /dev/kvm
sudo -n docker pull alpine:3.20
sudo -n docker run --rm --runtime runc alpine:3.20 /bin/true
sudo -n docker run --rm --runtime kata alpine:3.20 /bin/true
test -d /opt/omashiki-e2e/server-cache/deps
test -d /opt/omashiki-e2e/server-cache/_build/vm_e2e
restore_selinux
trap - EXIT
''')

    def sysprep_and_poweroff(self) -> None:
        self.ssh(f'''set -euo pipefail
sudo -n rm -f /home/{self.guest_user}/.ssh/authorized_keys
sudo -n cloud-init clean --logs --seed
sudo -n rm -f /etc/ssh/ssh_host_*
sudo -n truncate -s 0 /etc/machine-id
sudo -n rm -f /var/lib/dbus/machine-id
sudo -n sync
nohup sudo -n systemctl poweroff >/dev/null 2>&1 &
''', timeout=120)

    def wait_shutoff(self) -> None:
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.virsh(["domstate", self.name], check=False) == "shut off":
                return
            time.sleep(2)
        raise RuntimeError("prepared VM did not power off")

    def export_candidate(self) -> tuple[Path, dict]:
        downloaded = self.state / "builder-overlay.qcow2"
        candidate = self.candidate_path
        if candidate.exists() or candidate.is_symlink():
            raise Blocker(f"prepared candidate already exists: {candidate}")
        self.run(["virsh", "-c", self.qemu_uri, "vol-download", self.volume, str(downloaded),
                  "--pool", self.pool, "--sparse"], timeout=900)
        self.run(["qemu-img", "convert", "-p", "-O", "qcow2", str(downloaded), str(candidate)], timeout=900)
        self.run(["qemu-img", "check", str(candidate)], timeout=300)
        info = json.loads(self.output(["qemu-img", "info", "--output=json", str(candidate)]))
        if info.get("format") != "qcow2" or info.get("backing-filename") or info.get("virtual-size") != self.vm["disk_gib"] * 1024 ** 3:
            candidate.unlink(missing_ok=True)
            raise RuntimeError("prepared candidate qcow2 metadata is invalid")
        os.chmod(candidate, 0o644)
        return candidate, info

    def publish(self, candidate: Path, info: dict) -> None:
        journal = {"fingerprint": self.fingerprint, "host_path": str(self.host_path), "volume": self.final_volume}
        atomic_write_json(self.pending_path, journal)
        os.replace(candidate, self.host_path)
        directory_fd = os.open(self.host_path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        image_sha = sha256_file(self.host_path)
        image_size = self.host_path.stat().st_size
        base_xml = self.volume_root(
            self.virsh(["vol-dumpxml", self.base["volume"], "--pool", self.pool]),
            self.base["volume"],
        )
        owner = base_xml.findtext("./target/permissions/owner")
        group = base_xml.findtext("./target/permissions/group")
        if not owner or not owner.isdigit() or not group or not group.isdigit():
            raise Blocker("source Fedora volume does not declare numeric libvirt ownership")
        volume_definition = self.state / "prepared-volume.xml"
        volume_definition.write_text(f'''<volume type="file">
  <name>{self.final_volume}</name>
  <capacity unit="bytes">{info["virtual-size"]}</capacity>
  <target>
    <format type="qcow2"/>
    <permissions>
      <mode>0644</mode>
      <owner>{owner}</owner>
      <group>{group}</group>
    </permissions>
  </target>
</volume>
''')
        os.chmod(volume_definition, 0o600)
        self.run(["virsh", "-c", self.qemu_uri, "vol-create", self.pool, str(volume_definition)])
        self.run(["virsh", "-c", self.qemu_uri, "vol-upload", self.final_volume, str(self.host_path),
                  "--pool", self.pool, "--sparse"], timeout=900)
        libvirt_path = self.virsh(["vol-path", self.final_volume, "--pool", self.pool])
        if sha256_file(libvirt_path) != image_sha or Path(libvirt_path).stat().st_size != image_size:
            raise RuntimeError("published libvirt volume differs from prepared host image")
        pointer = {
            "fingerprint": self.fingerprint,
            "source_sha256": self.base["sha256"],
            "host_path": str(self.host_path),
            "volume": self.final_volume,
            "libvirt_path": libvirt_path,
            "sha256": image_sha,
            "size": image_size,
            "virtual_size": info["virtual-size"],
        }
        atomic_write_json(self.pointer_path, pointer)
        verify_prepared_base(self.manifest, self.manifest_path, self.qemu_uri)
        self.pending_path.unlink()
        self.log(f"published prepared base {self.fingerprint}")

    def build(self) -> None:
        self.acquire_lock()
        try:
            if self.current_is_valid():
                return
            self.validate_source()
            self.ensure_kata_bundle()
            self.ensure_private_directory(self.pointer_path.parent)
            self.ensure_private_directory(self.host_path.parent)
            self.recover_pending_publication()
            self.cleanup_candidate()
            self.state.mkdir(mode=0o700)
            self.cleanup_owned_staging()
            public_key = self.validated_public_key()
            cloud_init = self.render_cloud_init(public_key)
            try:
                self.create_builder(cloud_init)
                self.wait_for_ssh()
                self.log("waiting for package installation in the preparation VM")
                self.ssh("sudo -n cloud-init status --wait")
                self.install_kata()
                self.prime_server_cache()
                self.validate_guest()
                self.sysprep_and_poweroff()
                self.wait_shutoff()
                candidate, info = self.export_candidate()
            finally:
                self.cleanup_owned_staging()
            self.publish(candidate, info)
        finally:
            try:
                if hasattr(self, "candidate_path"):
                    self.cleanup_candidate()
            finally:
                shutil.rmtree(self.state, ignore_errors=True)
                self.release_lock()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(ROOT / "vm" / "manifest.toml"))
    parser.add_argument("--verify", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    manifest_path = Path(args.manifest).expanduser()
    try:
        if args.verify:
            manifest = load_manifest(manifest_path)
            pointer = verify_prepared_base(manifest, manifest_path, manifest["base"]["qemu_uri"])
            print(json.dumps({"status": "ready", "fingerprint": pointer["fingerprint"]}, sort_keys=True))
        else:
            Preparer(manifest_path).build()
        return 0
    except (Blocker, PreparedBaseError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f"VM preparation failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
