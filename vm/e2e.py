#!/usr/bin/env python3
"""Non-interactive distributed VM E2E for the current Omashiki source tree.

The test is deliberately self-contained and run-scoped. It never edits the
repository configuration, uses only the two owned libvirt domains, and records
cleanup verification in the JSON report before returning success.
"""

from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import fcntl
import hashlib
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
import threading
import time
import tomllib
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

from prepared import PreparedBaseError, verify_prepared_base


ROOT = Path(__file__).resolve().parents[1]
GUEST_RUNTIME_PARENT = Path("/tmp")
HOST_HOME = Path.home()
HOST_GIT_USER = os.environ.get("OMASHIKI_VM_HOST_USER") or pwd.getpwuid(os.getuid()).pw_name
VIRT_INSTALL = ["/usr/bin/python3", "/usr/bin/virt-install"]
LOCK_PATH = Path("/tmp/omashiki-vm-e2e.lock")
RUN_ID_RE = re.compile(r"^\d{8}-\d{6}-[0-9a-f]{6}$")
SAFE_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
SAFE_IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9._/-]{0,127}$")
SAFE_RUNTIME_VARIANTS = {"runc", "kata"}
PUBLIC_KEY_RE = re.compile(r"^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) [A-Za-z0-9+/]+={0,3}(?: [^\s]+)?$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_HELLO_FILE = "hello.py"
EXPECTED_HELLO_CONTENT = 'print("Hello, World!")\n'
EXPECTED_HELLO_OUTPUT = "Hello, World!\n"
KATA_ARCHIVE_URL = "https://github.com/kata-containers/kata-containers/releases/download/4.1.0/kata-static-4.1.0-amd64.tar.zst"
KATA_ARCHIVE_NAME = "kata-static-4.1.0-amd64.tar.zst"
KATA_ARCHIVE_SHA256 = "3dc6b69c4acb787b967b04b64599a20d02a8beb1a8eaab3084110df9d0b08c96"


class E2EError(RuntimeError):
    pass


class Blocker(E2EError):
    pass


def q(value: object) -> str:
    return shlex.quote(str(value))


def now_id() -> str:
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3)


def manifest_path(value: str | None = None) -> Path:
    return Path(value).expanduser() if value else ROOT / "vm" / "manifest.toml"


def _required_table(value: object, name: str) -> dict:
    if not isinstance(value, dict):
        raise Blocker(f"manifest [{name}] must be a table")
    return value


def _required_string(table: dict, key: str, where: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value.strip():
        raise Blocker(f"manifest {where}.{key} must be a non-empty string")
    return value


def _required_int(table: dict, key: str, where: str, minimum: int = 1) -> int:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise Blocker(f"manifest {where}.{key} must be an integer >= {minimum}")
    return value


def _repository_path(value: str, label: str, *, directory: bool = False) -> Path:
    relative = Path(value)
    if relative.is_absolute():
        raise Blocker(f"{label} must be a relative repository path")
    current = ROOT
    for component in relative.parts:
        if component in ("", "."):
            continue
        current = current / component
        if current.is_symlink():
            raise Blocker(f"{label} contains a symlink component: {value}")
    candidate = ROOT / relative
    try:
        candidate.resolve(strict=False).relative_to(ROOT.resolve())
    except ValueError as error:
        raise Blocker(f"{label} must remain inside the repository: {value}") from error
    if (candidate.is_dir() if directory else candidate.is_file()) is False:
        raise Blocker(f"{label} is missing: {candidate}")
    return candidate


def validate_manifest(manifest: object, path: Path) -> dict:
    if not isinstance(manifest, dict):
        raise Blocker(f"manifest is not a TOML table: {path}")
    expected_sections = {"project", "base", "prepared", "topology", "vm", "services", "workload", "resources", "artifact", "runtime"}
    unknown_sections = set(manifest) - expected_sections
    if unknown_sections:
        raise Blocker(f"manifest has unsupported sections: {', '.join(sorted(unknown_sections))}")
    sensitive_names = {"password", "token", "secret", "api_key", "private_key", "credentials"}
    def reject_secrets(value: object, where: str) -> None:
        if isinstance(value, dict):
            for key, nested in value.items():
                if str(key).lower() in sensitive_names:
                    raise Blocker(f"manifest must not contain secret field {where}.{key}")
                reject_secrets(nested, f"{where}.{key}")
        elif isinstance(value, list):
            for index, nested in enumerate(value):
                reject_secrets(nested, f"{where}[{index}]")
        elif isinstance(value, str) and ("${env:" in value or "${ENV:" in value):
            raise Blocker(f"manifest must not resolve secrets from the environment: {where}")
    reject_secrets(manifest, "manifest")
    project = _required_table(manifest.get("project"), "project")
    slug = _required_string(project, "slug", "[project]")
    purpose = _required_string(project, "purpose", "[project]")
    marker = _required_string(project, "ownership_marker", "[project]")
    if not SAFE_NAME_RE.fullmatch(slug) or not SAFE_NAME_RE.fullmatch(purpose):
        raise Blocker("manifest project slug and purpose must be lowercase names")
    if marker != f"project={slug};purpose={purpose}":
        raise Blocker("manifest ownership_marker must exactly identify project and purpose")

    base = _required_table(manifest.get("base"), "base")
    if _required_string(base, "qemu_uri", "[base]") != "qemu:///system":
        raise Blocker("manifest base.qemu_uri must be qemu:///system")
    _required_string(base, "pool", "[base]")
    _required_string(base, "volume", "[base]")
    _required_string(base, "path", "[base]")
    base_sha = _required_string(base, "sha256", "[base]")
    if not SHA256_RE.fullmatch(base_sha):
        raise Blocker("manifest base.sha256 must be 64 lowercase hexadecimal characters")
    if _required_string(base, "format", "[base]") != "qcow2":
        raise Blocker("manifest base.format must be qcow2")

    prepared = _required_table(manifest.get("prepared"), "prepared")
    for key in ("directory", "pointer", "pending"):
        value = Path(_required_string(prepared, key, "[prepared]")).expanduser()
        if not value.is_absolute():
            raise Blocker(f"manifest prepared.{key} must expand to an absolute path")
    prefix = _required_string(prepared, "volume_prefix", "[prepared]")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,126}", prefix):
        raise Blocker("manifest prepared.volume_prefix is invalid")
    _repository_path(_required_string(prepared, "cloud_init", "[prepared]"), "prepared cloud-init template")

    topology = _required_table(manifest.get("topology"), "topology")
    if _required_string(topology, "variant", "[topology]") != "service-node":
        raise Blocker("this harness supports only the service-node topology")
    if _required_string(topology, "core", "[topology]") != "host":
        raise Blocker("manifest topology.core must be host")
    domain_prefix = _required_string(topology, "domain_prefix", "[topology]")
    guest_user = _required_string(topology, "guest_user", "[topology]")
    nodes = topology.get("nodes")
    if not isinstance(nodes, list) or not nodes or any(not isinstance(node, str) or not SAFE_NAME_RE.fullmatch(node) for node in nodes):
        raise Blocker("manifest topology.nodes must contain unique lowercase names")
    if len(set(nodes)) != len(nodes) or not SAFE_NAME_RE.fullmatch(domain_prefix) or not SAFE_NAME_RE.fullmatch(guest_user):
        raise Blocker("manifest topology names must be safe and unique")

    vm = _required_table(manifest.get("vm"), "vm")
    _required_int(vm, "memory_mib", "[vm]")
    _required_int(vm, "vcpus", "[vm]")
    _required_int(vm, "disk_gib", "[vm]")
    _required_string(vm, "network", "[vm]")
    _required_string(vm, "bridge_interface", "[vm]")
    cloud_init = _required_string(vm, "cloud_init", "[vm]")
    _repository_path(cloud_init, "manifest cloud-init template")

    services = _required_table(manifest.get("services"), "services")
    for key in ("core_port", "worker_port", "fake_provider_port", "database_internal_port", "tunnel_port_base"):
        port = _required_int(services, key, "[services]", 1024)
        if port > 65535:
            raise Blocker(f"manifest services.{key} is outside the TCP port range")
    if len({services[key] for key in ("core_port", "worker_port", "fake_provider_port")}) != 3:
        raise Blocker("manifest service ports must be distinct")
    _required_string(services, "database_image", "[services]")

    workload = _required_table(manifest.get("workload"), "workload")
    count = _required_int(workload, "count", "[workload]")
    capacity = _required_int(workload, "per_node_capacity", "[workload]")
    if count != len(nodes) * capacity:
        raise Blocker("manifest workload.count must equal nodes * per_node_capacity")
    _required_int(workload, "fake_latency_ms", "[workload]", 0)
    _required_int(workload, "job_timeout_ms", "[workload]")
    jitter = workload.get("jitter_pct")
    if isinstance(jitter, bool) or not isinstance(jitter, int) or not 0 <= jitter <= 100:
        raise Blocker("manifest workload.jitter_pct must be an integer from 0 to 100")
    expected_file = _required_string(workload, "expected_file", "[workload]")
    expected_content = _required_string(workload, "expected_content", "[workload]")
    expected_output = _required_string(workload, "expected_output", "[workload]")
    for key in ("repository", "environment", "fake_scenario"):
        value = _required_string(workload, key, "[workload]")
        if not SAFE_NAME_RE.fullmatch(value):
            raise Blocker(f"manifest workload.{key} must be a safe name")
    expected_path = Path(expected_file)
    if (expected_path.is_absolute() or ".." in expected_path.parts or
            any(part in ("", ".") for part in expected_path.parts) or
            not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9._/-]*", expected_file)):
        raise Blocker("manifest workload.expected_file must be a safe relative path")
    if workload["fake_scenario"] == "python-hello" and (
            expected_file != EXPECTED_HELLO_FILE or
            expected_content != EXPECTED_HELLO_CONTENT or
            expected_output != EXPECTED_HELLO_OUTPUT):
        raise Blocker("python-hello requires the canonical hello.py content and output")

    resources = _required_table(manifest.get("resources"), "resources")
    _required_int(resources, "max_concurrent_containers", "[resources]")
    cpu = resources.get("cpu_per_container")
    if isinstance(cpu, bool) or not isinstance(cpu, (int, float)) or cpu <= 0:
        raise Blocker("manifest resources.cpu_per_container must be positive")
    _required_string(resources, "memory_per_container", "[resources]")
    _required_int(resources, "pids_limit", "[resources]")

    artifact = _required_table(manifest.get("artifact"), "artifact")
    image_repository = _required_string(artifact, "image_repository", "[artifact]")
    if not SAFE_IMAGE_RE.fullmatch(image_repository):
        raise Blocker("manifest artifact.image_repository is not a safe image reference")
    image_key = _required_string(artifact, "image_key", "[artifact]")
    if not SAFE_NAME_RE.fullmatch(image_key):
        raise Blocker("manifest artifact.image_key is not safe")
    for key in ("dockerfile", "build_context"):
        _repository_path(
            _required_string(artifact, key, "[artifact]"),
            f"manifest artifact.{key}",
            directory=key == "build_context",
        )
    excludes = artifact.get("source_excludes")
    if not isinstance(excludes, list) or any(not isinstance(item, str) or not item for item in excludes):
        raise Blocker("manifest artifact.source_excludes must be a list of paths")
    for item in excludes:
        exclude_path = Path(item)
        if exclude_path.is_absolute() or ".." in exclude_path.parts:
            raise Blocker(f"manifest artifact.source_excludes contains an unsafe path: {item}")
    required_excludes = {".git", ".temp", "deps", "_build", "node_modules", "server/tmp"}
    if not required_excludes.issubset(excludes):
        raise Blocker("manifest artifact.source_excludes must exclude repository metadata, dependencies, and builds")
    if _required_string(artifact, "delivery", "[artifact]") != "docker-save-load":
        raise Blocker("manifest artifact.delivery must be docker-save-load")

    runtime = _required_table(manifest.get("runtime"), "runtime")
    backend = _required_string(runtime, "backend", "[runtime]")
    distribution = _required_string(runtime, "distribution", "[runtime]")
    if backend != "docker" or distribution != "debian":
        raise Blocker("manifest runtime must use the Docker Debian runtime")
    variant = _required_string(runtime, "variant", "[runtime]")
    if variant not in SAFE_RUNTIME_VARIANTS:
        raise Blocker("manifest runtime.variant must be runc or kata")
    if _required_string(runtime, "runc_id", "[runtime]") != "docker.runc.debian":
        raise Blocker("manifest runtime.runc_id must be docker.runc.debian")
    if _required_string(runtime, "kata_id", "[runtime]") != "docker.kata.debian":
        raise Blocker("manifest runtime.kata_id must be docker.kata.debian")
    kata = _required_table(runtime.get("kata"), "runtime.kata")
    if _required_string(kata, "version", "[runtime.kata]") != "4.1.0":
        raise Blocker("manifest runtime.kata.version must be 4.1.0")
    if _required_string(kata, "archive", "[runtime.kata]") != KATA_ARCHIVE_NAME:
        raise Blocker("manifest runtime.kata.archive is not the pinned amd64 archive")
    if _required_string(kata, "url", "[runtime.kata]") != KATA_ARCHIVE_URL:
        raise Blocker("manifest runtime.kata.url is not the pinned release URL")
    if not SHA256_RE.fullmatch(_required_string(kata, "sha256", "[runtime.kata]")) or kata["sha256"] != KATA_ARCHIVE_SHA256:
        raise Blocker("manifest runtime.kata.sha256 is not the pinned archive checksum")
    for key, expected in (
        ("install_root", "/opt/kata"),
        ("runtime_path", "/opt/kata/runtime-rs/bin/containerd-shim-kata-v2"),
        ("hypervisor_path", "/opt/kata/bin/cloud-hypervisor"),
        ("daemon_config", "/etc/docker/daemon.json"),
        ("config_path", "/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-clh-runtime-rs.toml"),
    ):
        if _required_string(kata, key, "[runtime.kata]") != expected:
            raise Blocker(f"manifest runtime.kata.{key} must be {expected}")
    return manifest


def load_manifest(path: Path) -> dict:
    try:
        with path.open("rb") as source:
            return validate_manifest(tomllib.load(source), path)
    except FileNotFoundError as error:
        raise Blocker(f"manifest is missing: {path}") from error
    except tomllib.TOMLDecodeError as error:
        raise Blocker(f"manifest is invalid TOML: {path}: {error}") from error


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the disposable distributed VM E2E")
    parser.add_argument(
        "--manifest",
        default=str(ROOT / "vm" / "manifest.toml"),
        help="validated VM E2E manifest (default: vm/manifest.toml)",
    )
    parser.add_argument(
        "--runtime",
        choices=sorted(SAFE_RUNTIME_VARIANTS),
        help="override manifest runtime.variant for this run",
    )
    parser.add_argument(
        "--keep-vms",
        action="store_true",
        help="keep the owned VM definitions and overlays, shut off, after this run",
    )
    return parser.parse_args(argv)


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

REMOTE_SNAPSHOT_CODE = r'''
import base64, json, pathlib, stat
path = pathlib.Path(json.loads(base64.b64decode("PAYLOAD").decode())["path"])
if path.is_symlink() or path.parent.is_symlink():
    raise SystemExit("refusing symlinked SSH path: " + str(path))
if not path.exists():
    print(json.dumps({"exists": False}))
else:
    if not path.is_file():
        raise SystemExit("SSH path is not a regular file: " + str(path))
    print(json.dumps({"exists": True, "mode": stat.S_IMODE(path.stat().st_mode), "bytes": base64.b64encode(path.read_bytes()).decode()}))
'''

REMOTE_RESTORE_CODE = r'''
import base64, json, os, pathlib, stat, tempfile
payload = json.loads(base64.b64decode("PAYLOAD").decode())
path = pathlib.Path(payload["path"])
parent = path.parent
if path.is_symlink() or parent.is_symlink():
    raise SystemExit("refusing symlinked SSH path")
if not payload["exists"]:
    if path.exists():
        if not path.is_file():
            raise SystemExit("SSH path is not a regular file")
        path.unlink()
else:
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".omashiki-ssh-", dir=str(parent))
    try:
        os.fchmod(fd, int(payload["mode"]))
        with os.fdopen(fd, "wb") as output:
            output.write(base64.b64decode(payload["bytes"]))
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        os.chmod(path, int(payload["mode"]))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
if payload["exists"]:
    if path.is_symlink() or not path.is_file():
        raise SystemExit("restored SSH path is not a regular file")
    if stat.S_IMODE(path.stat().st_mode) != int(payload["mode"]):
        raise SystemExit("restored SSH path mode differs")
    if path.read_bytes() != base64.b64decode(payload["bytes"]):
        raise SystemExit("restored SSH path contents differ")
elif path.exists() or path.is_symlink():
    raise SystemExit("removed SSH path still exists")
print("restored")
'''


class Harness:
    def __init__(self, *, keep_vms: bool = False, manifest: Path | None = None,
                 runtime_variant: str | None = None) -> None:
        # Parse and validate before changing umask, creating state, or acquiring a lock.
        self.manifest = load_manifest(manifest or manifest_path())
        self.manifest_file = manifest or manifest_path()
        self.run_id = now_id()
        self.keep_vms = keep_vms
        project = self.manifest["project"]
        base = self.manifest["base"]
        topology = self.manifest["topology"]
        vm_config = self.manifest["vm"]
        services = self.manifest["services"]
        workload = self.manifest["workload"]
        resources = self.manifest["resources"]
        artifact = self.manifest["artifact"]
        runtime = self.manifest["runtime"]
        self.project_slug = project["slug"]
        self.purpose = project["purpose"]
        self.ownership_marker = project["ownership_marker"]
        self.qemu_uri = base["qemu_uri"]
        self.pool = base["pool"]
        self.source_base_volume = base["volume"]
        self.source_base_path = Path(os.environ.get("OMASHIKI_VM_BASE", base["path"])).expanduser()
        self.base_volume = self.source_base_volume
        self.base_path = self.source_base_path
        self.prepared_pointer: dict | None = None
        self.domain_prefix = topology["domain_prefix"]
        self.vm_user = topology["guest_user"]
        self.node_names = tuple(topology["nodes"])
        self.vm_names = tuple(f"{self.domain_prefix}-{node}" for node in self.node_names)
        self.vm_memory_mib = vm_config["memory_mib"]
        self.vm_vcpus = vm_config["vcpus"]
        self.vm_disk_gib = vm_config["disk_gib"]
        self.vm_network = vm_config["network"]
        self.bridge_interface = vm_config["bridge_interface"]
        self.cloud_init_file = ROOT / vm_config["cloud_init"]
        self.core_port = services["core_port"]
        self.worker_port = services["worker_port"]
        self.fake_provider_port = services["fake_provider_port"]
        self.database_internal_port = services["database_internal_port"]
        self.tunnel_port_base = services["tunnel_port_base"]
        self.database_image = services["database_image"]
        self.workload_count = workload["count"]
        self.per_node_capacity = workload["per_node_capacity"]
        self.fake_latency_ms = workload["fake_latency_ms"]
        self.jitter_pct = workload["jitter_pct"]
        self.job_timeout_ms = workload["job_timeout_ms"]
        self.expected_file = workload["expected_file"]
        self.expected_content = workload["expected_content"].encode()
        self.expected_output = workload["expected_output"].encode()
        self.repository_name = workload["repository"]
        self.environment_name = workload["environment"]
        self.fake_scenario = workload["fake_scenario"]
        self.runtime_variant = runtime_variant or runtime["variant"]
        if self.runtime_variant not in SAFE_RUNTIME_VARIANTS:
            raise Blocker("runtime override must be runc or kata")
        self.runtime_backend = runtime["backend"]
        self.runtime_distribution = runtime["distribution"]
        self.runtime_ids = {"runc": runtime["runc_id"], "kata": runtime["kata_id"]}
        self.runtime_name = self.runtime_ids[self.runtime_variant]
        kata = runtime["kata"]
        self.kata_archive_name = kata["archive"]
        self.kata_archive_url = kata["url"]
        self.kata_archive_sha256 = kata["sha256"]
        self.kata_install_root = kata["install_root"]
        self.kata_runtime_path = kata["runtime_path"]
        self.kata_hypervisor_path = kata["hypervisor_path"]
        self.kata_daemon_config = kata["daemon_config"]
        self.kata_config_path = kata["config_path"]
        self.artifact_image_repository = artifact["image_repository"]
        self.artifact_image_key = artifact["image_key"]
        self.artifact_dockerfile = Path(artifact["dockerfile"])
        self.artifact_build_context = Path(artifact["build_context"])
        self.source_excludes = tuple(artifact["source_excludes"])
        self.remote_mirror = f".cache/{self.project_slug}/mirrors/{self.repository_name}"
        self.max_concurrent_containers = resources["max_concurrent_containers"]
        self.cpu_per_container = resources["cpu_per_container"]
        self.memory_per_container = resources["memory_per_container"]
        self.pids_limit = resources["pids_limit"]
        self.previous_umask = os.umask(0o077)
        cache_home = Path(os.environ.get("XDG_CACHE_HOME", HOST_HOME / ".cache")).expanduser()
        self.kata_cache_dir = cache_home / self.project_slug / "vm-e2e"
        self.state = Path("/tmp") / f"{self.project_slug}-vm-e2e-{self.run_id}-state"
        self.logs = self.state / "logs"
        self.source = self.state / "source"
        self.runtime = Path("/tmp") / f"{self.project_slug}-vm-e2e-{self.run_id}"
        self.guest_root = GUEST_RUNTIME_PARENT / f"{self.project_slug}-vm-e2e-{self.run_id}"
        self.guest_source = self.guest_root / "source"
        self.guest_logs = self.guest_root / "logs"
        self.image = f"{self.artifact_image_repository}:vm-e2e-{self.run_id}"
        self.correlation_id = f"VM_E2E_{self.run_id}"
        self.kata_bundle = self.kata_cache_dir / self.kata_archive_name
        self.guest_mix_cache = "/opt/omashiki-e2e/server-cache"
        self.heartbeat_interval_seconds = 30.0
        self.sla_seconds = 600
        self.report: dict = {
            "schema_version": 3,
            "run_id": self.run_id,
            "keep_vms": self.keep_vms,
            "status": "running",
            "topology": {"qemu_uri": self.qemu_uri, "vms": list(self.vm_names), "nodes": list(self.node_names)},
            "ownership": {"project": self.project_slug, "purpose": self.purpose, "marker": self.ownership_marker},
            "runtime": {"name": self.runtime_name, "ids": self.runtime_ids, "variant": self.runtime_variant, "variant_configured": True,
                         "network": "restricted" if self.runtime_variant == "kata" else "host"},
            "container_ownership_expectation": {
                "job_payload_context_field": "correlation_id",
                "expected_label": "omashiki.correlation_id",
                "expected_value": self.correlation_id,
                "attempt_label": "omashiki.job_scope_id",
                "server_support": "required",
            },
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
        self.vm_owned_by_harness: set[str] = set()
        self.vm_initial_snapshots: dict[str, dict] = {}
        self.db_container: str | None = None
        self.db_port = 0
        self.vm_db_port = 0
        self.authorized_line: str | None = None
        self.authorized_added = False
        self.host_known_lines: list[str] = []
        self.vm_known_added: dict[str, list[str]] = {name: [] for name in self.vm_names_for_run()}
        self.vm_known_snapshots: dict[str, dict] = {}
        self.vm_authorized_snapshots: dict[str, dict] = {}
        self.vm_authorized_lines: dict[str, str] = {}
        self.guest_runtime_snapshots: dict[str, dict[str, dict]] = {}
        self.guest_runtime_changed: set[str] = set()
        self.guest_kata_installed: set[str] = set()
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
        self.source_identity: dict | None = None
        self.host_process_metadata: dict[str, dict] = {}
        self.tunnel_metadata: dict[int, dict] = {}
        self.db_query_verified = False
        self.remote_cleanup_result: dict[str, bool] = {}

    def log(self, message: str) -> None:
        print(message, file=sys.stderr, flush=True)

    def run_phase(self, label: str, function):
        started = time.monotonic()
        stopped = threading.Event()

        def heartbeat() -> None:
            interval = float(self.setting("heartbeat_interval_seconds", 30.0))
            while not stopped.wait(interval):
                self.log(f"... {label} ({time.monotonic() - started:.0f}s elapsed)")

        self.log(f"==> {label}")
        thread = threading.Thread(target=heartbeat, name="vm-e2e-heartbeat", daemon=True)
        thread.start()
        succeeded = False
        try:
            value = function()
            succeeded = True
            return value
        finally:
            stopped.set()
            thread.join()
            state = "complete" if succeeded else "stopped"
            self.log(f"<== {label} {state} ({time.monotonic() - started:.1f}s)")

    def print_report(self) -> None:
        print(json.dumps(self.report, indent=2, sort_keys=True), flush=True)

    def vm_names_for_run(self) -> tuple[str, ...]:
        return getattr(self, "vm_names", ())

    def node_names_for_run(self) -> tuple[str, ...]:
        return getattr(self, "node_names", ())

    def worker_network_mode(self) -> str:
        return "bridge" if self.runtime_variant == "kata" else "host"

    def setting(self, name: str, default: object) -> object:
        return getattr(self, name, default)

    def overlay_path(self, name: str, base_path: str | None = None) -> str:
        return str(Path(base_path or self.setting("libvirt_base_path", "/var/lib/libvirt/images/base.qcow2")).parent / f"{name}.qcow2")

    def expected_domain_xml(self, name: str, xml: str, volume_xml: str, base_path: str) -> bool:
        return self.domain_owned(name, xml, volume_xml, base_path)

    def volume_query_is_missing(self, value: str) -> bool:
        text = value.lower()
        return text.startswith("error:") and any(fragment in text for fragment in ("not found", "no volume", "does not exist"))

    def volume_query_is_present(self, value: str) -> bool:
        return bool(value) and not value.startswith("error:")

    def local(self, args: list[str], *, cwd: Path | None = None, env: dict | None = None,
              check: bool = True, input_data: bytes | None = None, timeout: int | None = None) -> subprocess.CompletedProcess:
        if getattr(self, "in_cleanup", False):
            timeout = min(timeout, 15) if timeout is not None else 15
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
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6",
                "-o", "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                f"{self.setting('vm_user', 'fedora')}@{ip}"]

    def ssh(self, name: str, script: str, *, check: bool = True,
            input_data: bytes | None = None) -> str:
        return self.ssh_result(name, script, check=check, input_data=input_data).stdout.decode(errors="replace").strip()

    def ssh_result(self, name: str, script: str, *, check: bool = True,
                   input_data: bytes | None = None) -> subprocess.CompletedProcess:
        args = self.ssh_args(self.vm_ips[name]) + ["bash", "-lc", q(script)]
        return self.local(args, check=check, input_data=input_data)

    def scp_to(self, name: str, source: Path, destination: str) -> None:
        args = ["scp", "-q", "-i", str(HOST_HOME / ".ssh" / "id_vms"),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o",
                "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o",
                "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                str(source), f"{self.setting('vm_user', 'fedora')}@{self.vm_ips[name]}:{destination}"]
        self.local(args)

    def scp_from(self, name: str, source: str, destination: Path) -> bool:
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        args = ["scp", "-q", "-i", str(HOST_HOME / ".ssh" / "id_vms"),
                "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o",
                "ServerAliveInterval=10", "-o", "ServerAliveCountMax=6", "-o",
                "StrictHostKeyChecking=yes", "-o",
                f"UserKnownHostsFile={self.state / 'vm_known_hosts'}",
                f"{self.setting('vm_user', 'fedora')}@{self.vm_ips[name]}:{source}", str(destination)]
        return self.local(args, check=False).returncode == 0 and destination.is_file()

    def virsh(self, args: list[str], *, check: bool = True) -> str:
        command = ["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), *args]
        if check:
            return self.output(command, cwd=ROOT)
        result = self.local(command, check=False)
        if result.returncode != 0:
            return "error: " + result.stdout.decode(errors="replace").strip()
        return result.stdout.decode().strip()

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
        if LOCK_PATH.is_symlink():
            raise Blocker(f"refusing symlinked VM E2E lock: {LOCK_PATH}")
        try:
            lock_stat = LOCK_PATH.stat()
            if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.getuid() or stat.S_IMODE(lock_stat.st_mode) & 0o077:
                raise Blocker(f"VM E2E lock has unsafe owner, type, or mode: {LOCK_PATH}")
            fd = os.open(LOCK_PATH, os.O_RDWR | getattr(os, "O_NOFOLLOW", 0))
        except FileNotFoundError:
            try:
                fd = os.open(LOCK_PATH, os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
            except FileExistsError as error:
                raise Blocker(f"VM E2E lock changed during validation: {LOCK_PATH}") from error
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid() or stat.S_IMODE(opened.st_mode) & 0o077:
            os.close(fd)
            raise Blocker(f"VM E2E lock changed to an unsafe file during validation: {LOCK_PATH}")
        self.lock_file = os.fdopen(fd, "a+")
        try:
            fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            self.lock_file.close()
            self.lock_file = None
            raise Blocker(f"another VM E2E is running; lock is held at {LOCK_PATH}") from error
        os.fchmod(self.lock_file.fileno(), 0o600)
        self.lock_acquired = True

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

    def host_docker_result(self, args: list[str], *, timeout: int = 15) -> subprocess.CompletedProcess:
        info = self.local(["docker", "info"], check=False, timeout=10)
        if info.returncode != 0:
            raise E2EError("host Docker daemon is unavailable")
        result = self.local(["docker", *args], check=False, timeout=timeout)
        if result.returncode != 0:
            raise E2EError(f"host Docker query failed: {' '.join(args)}")
        return result

    def guest_docker_result(self, name: str, args: str, *, timeout: int = 15) -> subprocess.CompletedProcess:
        info = self.ssh_result(name, "timeout 15s sudo -n docker info >/dev/null 2>&1", check=False)
        if info.returncode != 0:
            raise E2EError(f"{name} Docker daemon is unavailable")
        result = self.ssh_result(name, f"timeout {timeout}s sudo -n docker {args}", check=False)
        if result.returncode != 0:
            output = result.stdout.decode(errors="replace").strip()
            raise E2EError(f"{name} Docker query failed: {args}\n{output[-2000:]}")
        return result

    def wait_guest_docker(self, name: str, timeout: int = 60) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.ssh_result(
                name, "timeout 10s sudo -n docker info >/dev/null 2>&1", check=False
            )
            if result.returncode == 0:
                return True
            time.sleep(2)
        return False

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
        info = self.ssh_result(name, "timeout 30s sudo -n docker info >/dev/null 2>&1", check=False)
        if info.returncode != 0:
            raise E2EError(f"{name} Docker daemon is unavailable")
        return self.ssh_result(name, f"timeout 30s sudo -n docker {args}", check=False)

    def domain_owned(self, name: str, xml: str, volume_xml: str, base_path: str) -> bool:
        try:
            root = ET.fromstring(xml)
        except ET.ParseError:
            return False
        if root.findtext("name") != name or root.findtext("title") != self.setting("ownership_marker", "project=omashiki;purpose=vm-e2e"):
            return False
        memory = root.find("memory")
        current_memory = root.find("currentMemory")
        vcpu = root.find("vcpu")
        if (memory is None or current_memory is None or vcpu is None
                or root.findtext("memory") != str(int(self.setting("vm_memory_mib", 4096)) * 1024) or memory.get("unit") != "KiB"):
            return False
        if root.findtext("currentMemory") != str(int(self.setting("vm_memory_mib", 4096)) * 1024) or current_memory.get("unit") != "KiB":
            return False
        if root.findtext("vcpu") != str(self.setting("vm_vcpus", 2)) or vcpu.get("placement") != "static":
            return False
        cpu = root.find("cpu")
        if cpu is None or cpu.get("mode") != "host-passthrough":
            return False
        devices = root.find("devices")
        if devices is None:
            return False
        disks = root.findall("./devices/disk[@device='disk']")
        if len(disks) != 1:
            return False
        cdroms = root.findall("./devices/disk[@device='cdrom']")
        if len(root.findall("./devices/disk")) != 1 + len(cdroms) or len(cdroms) > 1:
            return False
        if cdroms:
            cdrom = cdroms[0]
            cdrom_driver = cdrom.find("driver")
            cdrom_source = cdrom.find("source")
            cdrom_target = cdrom.find("target")
            source_path = Path(cdrom_source.get("file")) if cdrom_source is not None and cdrom_source.get("file") else None
            if (cdrom_driver is None or cdrom_driver.get("name") != "qemu" or cdrom_driver.get("type") != "raw"
                    or cdrom.find("readonly") is None or cdrom_target is None or cdrom_target.get("bus") != "ide"):
                return False
            if source_path is not None and (source_path.parent != Path("/var/lib/libvirt/boot")
                                            or not source_path.name.startswith("virtinst-")
                                            or not source_path.name.endswith("-cloudinit.iso")):
                return False
        source = disks[0].find("source")
        driver = disks[0].find("driver")
        target = disks[0].find("target")
        if (source is None or source.get("file") != self.overlay_path(name, base_path)
                or driver is None or driver.get("name") != "qemu" or driver.get("type") != "qcow2"
                or target is None or target.get("dev") != "vda" or target.get("bus") != "virtio"):
            return False
        if not self.volume_owned(name, volume_xml, base_path):
            return False
        interfaces = root.findall("./devices/interface")
        if len(interfaces) != 1:
            return False
        network = interfaces[0].find("source")
        model = interfaces[0].find("model")
        console = root.find("./devices/console/target")
        allowed = {"audio", "console", "controller", "disk", "emulator", "hostdev", "input", "interface", "memballoon", "serial"}
        unexpected = {child.tag for child in devices if child.tag not in allowed}
        emulator = root.findtext("./devices/emulator")
        controllers = root.findall("./devices/controller")
        serials = root.findall("./devices/serial")
        inputs = {(item.get("type"), item.get("bus")) for item in root.findall("./devices/input")}
        audio = root.findall("./devices/audio")
        balloons = root.findall("./devices/memballoon")
        hostdevs = root.findall("./devices/hostdev")
        if hostdevs:
            return False
        return (network is not None and network.get("network") == self.setting("vm_network", "default") and model is not None
                and model.get("type") == "virtio" and len(root.findall("./devices/console")) == 1 and not root.findall("./devices/graphics")
                and console is not None and console.get("type") == "serial" and not unexpected
                and emulator == "/usr/bin/qemu-system-x86_64"
                and controllers and all(item.get("type") in {"ide", "pci", "usb"} for item in controllers)
                and len(serials) == 1 and serials[0].find("target") is not None
                and serials[0].find("target").get("type") == "isa-serial"
                and inputs == {("mouse", "ps2"), ("keyboard", "ps2")}
                and len(audio) == 1 and audio[0].get("type") == "none"
                and len(balloons) == 1 and balloons[0].get("model") == "virtio")

    def volume_owned(self, name: str, volume_xml: str, base_path: str) -> bool:
        try:
            volume = ET.fromstring(volume_xml)
        except ET.ParseError:
            return False
        target = volume.find("./target/path")
        backing = volume.find("./backingStore/path")
        target_format = volume.find("./target/format")
        backing_format = volume.find("./backingStore/format")
        format_name = (target_format.get("type") if target_format is not None else None) or volume.findtext("format")
        if format_name != "qcow2":
            return False
        capacity = volume.findtext("capacity")
        try:
            expected_capacity = int(self.setting("vm_disk_gib", 20)) * 1024 ** 3
        except (TypeError, ValueError):
            return False
        if capacity != str(expected_capacity):
            return False
        if target is None or not target.text:
            return False
        target_path = Path(target.text)
        try:
            target_stat = target_path.stat()
        except OSError:
            return False
        if target_path.is_symlink() or not target_path.is_file() or stat.S_IMODE(target_stat.st_mode) & 0o022:
            return False
        return (
            volume.findtext("name") == f"{name}.qcow2"
            and target.text == self.overlay_path(name, base_path)
            and backing is not None
            and backing.text == base_path
            and backing_format is not None
            and backing_format.get("type") == "qcow2"
            and volume.find("./backingStore/backingStore") is None
        )

    def domain_snapshot(self, name: str, state: str | None) -> dict:
        xml = self.virsh(["dumpxml", name], check=False) if state is not None else ""
        pool = self.setting("pool", "images")
        volume_info = self.virsh(["vol-info", f"{name}.qcow2", "--pool", pool], check=False)
        volume_xml = self.virsh(["vol-dumpxml", f"{name}.qcow2", "--pool", pool], check=False)
        volume_path = self.virsh(["vol-path", f"{name}.qcow2", "--pool", pool], check=False)
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

    def file_identity(self, path: Path) -> dict:
        self.reject_symlink(path, "identity input")
        if not path.is_file():
            raise E2EError(f"identity input is not a regular file: {path}")
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
                size += len(chunk)
        return {"sha256": digest.hexdigest(), "size": size, "mode": stat.S_IMODE(path.stat().st_mode)}

    def source_tree_identity(self, root: Path) -> str:
        digest = hashlib.sha256()
        excludes = tuple(self.setting("source_excludes", ()))
        for path in sorted(root.rglob("*")):
            relative = path.relative_to(root)
            if any(relative == Path(item) or Path(item) in relative.parents for item in excludes):
                continue
            if path.is_symlink():
                raise E2EError(f"source snapshot contains symlink: {relative}")
            if not path.is_file():
                continue
            digest.update(str(relative).encode() + b"\0")
            with path.open("rb") as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(chunk)
        return digest.hexdigest()

    def validate_base_volume(self) -> None:
        self.reject_symlink(self.base_path, "base image")
        if not self.base_path.is_file():
            raise Blocker(f"base image is missing: {self.base_path}")
        base_stat = self.base_path.stat()
        if base_stat.st_uid != os.getuid() or stat.S_IMODE(base_stat.st_mode) & 0o022:
            raise Blocker(f"base image owner/mode is unsafe: {self.base_path}")
        host_info = self.local(["qemu-img", "info", "--output=json", str(self.base_path)], check=False)
        if host_info.returncode != 0:
            raise Blocker(f"qemu-img cannot inspect base image: {self.base_path}")
        try:
            host_identity = json.loads(host_info.stdout)
        except json.JSONDecodeError as error:
            raise Blocker("qemu-img returned invalid base image metadata") from error
        if host_identity.get("format") != "qcow2" or not isinstance(host_identity.get("virtual-size"), int) or host_identity["virtual-size"] <= 0:
            raise Blocker("base image must be a non-empty qcow2 image")
        if host_identity.get("backing-filename"):
            raise Blocker("base image must not depend on an unvalidated backing file")
        base_volume_xml = self.virsh(["vol-dumpxml", self.base_volume, "--pool", self.pool], check=False)
        try:
            volume = ET.fromstring(base_volume_xml)
        except ET.ParseError as error:
            raise Blocker(f"libvirt base volume metadata is invalid: {self.base_volume}") from error
        target = volume.find("./target/path")
        target_format = volume.find("./target/format")
        format_name = (target_format.get("type") if target_format is not None else None) or volume.findtext("format")
        backing_format = volume.find("./backingStore/format")
        if (volume.findtext("name") != self.base_volume or target is None
                or target.text != self.libvirt_base_path or format_name != "qcow2"):
            raise Blocker("libvirt base volume name, path, or format is not the declared base")
        libvirt_path = Path(self.libvirt_base_path)
        self.reject_symlink(libvirt_path, "libvirt base volume")
        if not libvirt_path.is_file():
            raise Blocker(f"libvirt base volume path is not a regular file: {libvirt_path}")
        libvirt_stat = libvirt_path.stat()
        if stat.S_IMODE(libvirt_stat.st_mode) & 0o022:
            raise Blocker("libvirt base volume has unsafe write permissions")
        libvirt_info = self.local(["qemu-img", "info", "--output=json", str(libvirt_path)], check=False)
        if libvirt_info.returncode != 0:
            raise Blocker("qemu-img cannot inspect the libvirt base volume")
        try:
            libvirt_identity = json.loads(libvirt_info.stdout)
        except json.JSONDecodeError as error:
            raise Blocker("qemu-img returned invalid libvirt base metadata") from error
        if (libvirt_identity.get("format") != "qcow2"
                or libvirt_identity.get("virtual-size") != host_identity.get("virtual-size")
                or backing_format is not None):
            raise Blocker("host base image and libvirt base volume identities differ")
        host_file = self.file_identity(self.base_path)
        libvirt_file = self.file_identity(libvirt_path)
        if host_file["sha256"] != libvirt_file["sha256"] or host_file["size"] != libvirt_file["size"]:
            raise Blocker("declared base image bytes do not match the libvirt base volume")
        self.report["evidence"]["base"] = {
            "declared_path": str(self.base_path), "libvirt_path": self.libvirt_base_path,
            "volume": self.base_volume, "format": "qcow2",
            "host_qemu_info": host_identity, "libvirt_qemu_info": libvirt_identity,
            "host_file": host_file, "libvirt_file": libvirt_file,
        }

    def prepare_kata_bundle(self) -> None:
        if self.runtime_variant != "kata":
            return
        if not Path("/dev/kvm").is_char_device() or not os.access("/dev/kvm", os.R_OK | os.W_OK):
            raise Blocker("Kata requires an accessible host /dev/kvm for nested virtualization")
        if not self.kata_cache_dir.is_absolute():
            raise Blocker("Kata cache path must be absolute")
        for directory in (self.kata_cache_dir.parent, self.kata_cache_dir):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            self.reject_symlink(directory, "Kata cache directory")
            directory_stat = directory.stat()
            if not directory.is_dir() or directory_stat.st_uid != os.getuid():
                raise Blocker(f"Kata cache directory is not owned by the current user: {directory}")
            if stat.S_IMODE(directory_stat.st_mode) & 0o022:
                raise Blocker(f"Kata cache directory has unsafe write permissions: {directory}")
            os.chmod(directory, 0o700)

        source = "cache"
        identity = None
        if self.kata_bundle.exists() or self.kata_bundle.is_symlink():
            self.reject_symlink(self.kata_bundle, "Kata cache archive")
            archive_stat = self.kata_bundle.stat()
            if not self.kata_bundle.is_file() or archive_stat.st_uid != os.getuid():
                raise Blocker("cached Kata archive is not a regular file owned by the current user")
            if stat.S_IMODE(archive_stat.st_mode) & 0o022:
                raise Blocker("cached Kata archive has unsafe write permissions")
            identity = self.file_identity(self.kata_bundle)
            if identity["sha256"] != self.kata_archive_sha256:
                self.log("cached Kata archive checksum mismatch; replacing it")
                self.kata_bundle.unlink()
                identity = None

        if identity is None:
            source = "network"
            fd, temporary = tempfile.mkstemp(
                prefix=f".{self.kata_archive_name}.", suffix=".part", dir=self.kata_cache_dir
            )
            os.close(fd)
            temporary_path = Path(temporary)
            try:
                self.log(f"downloading Kata {self.kata_archive_name} into the validated cache")
                self.local(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
                            "--progress-bar", "--output", str(temporary_path), self.kata_archive_url], timeout=1800)
                identity = self.file_identity(temporary_path)
                if identity["sha256"] != self.kata_archive_sha256:
                    raise Blocker("downloaded Kata archive checksum does not match the pinned 4.1.0 release")
                os.chmod(temporary_path, 0o600)
                os.replace(temporary_path, self.kata_bundle)
            finally:
                temporary_path.unlink(missing_ok=True)
        else:
            self.log(f"using checksum-validated Kata archive from {self.kata_bundle}")

        assert identity is not None
        self.report["evidence"]["kata"] = {
            "version": "4.1.0", "archive": self.kata_archive_name,
            "url": self.kata_archive_url, "sha256": identity["sha256"],
            "size": identity["size"], "host_kvm": "/dev/kvm",
            "source": source, "cache_path": str(self.kata_bundle),
        }

    def preflight(self) -> str:
        self.state.mkdir(parents=True, exist_ok=False, mode=0o700)
        self.logs.mkdir(mode=0o700)
        required = ["docker", "virsh", "virt-install", "qemu-img", "ssh", "ssh-keygen", "rsync", "mix", "gzip", "tar", "ip"]
        missing = [tool for tool in required if subprocess.run(["bash", "-lc", f"command -v {q(tool)}"], stdout=subprocess.DEVNULL).returncode != 0]
        if missing:
            raise Blocker("missing required host tools: " + ", ".join(missing))
        if not (HOST_HOME / ".ssh" / "id_vms").is_file():
            raise Blocker(f"VM private key missing: {HOST_HOME / '.ssh' / 'id_vms'}")
        access_pub = self.validate_ssh_files()
        if self.local(["docker", "info"], check=False).returncode != 0:
            raise Blocker("host Docker daemon is unavailable")
        if self.output(["virsh", "-c", self.qemu_uri, "uri"]) != self.qemu_uri:
            raise Blocker("libvirt system URI is unavailable")
        virt = self.local([*VIRT_INSTALL, "--version"], check=False)
        if virt.returncode != 0:
            raise Blocker("virt-install cannot run with the host Python")
        if self.local(["docker", "image", "inspect", self.database_image], check=False).returncode != 0:
            raise Blocker(f"Docker image {self.database_image} is not available locally")
        try:
            self.prepared_pointer = verify_prepared_base(self.manifest, self.manifest_file, self.qemu_uri)
        except PreparedBaseError as error:
            raise Blocker(f"prepared VM base is unavailable: {error}; run `mise run e2e:vm:prepare`") from error
        self.base_volume = self.prepared_pointer["volume"]
        self.base_path = Path(self.prepared_pointer["host_path"])
        base_path = self.virsh(["vol-path", self.base_volume, "--pool", self.pool], check=False)
        if not base_path or base_path.startswith("error:"):
            raise Blocker(f"base libvirt volume is unavailable: {self.base_volume}")
        self.libvirt_base_path = base_path
        self.validate_base_volume()
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        if any(line.startswith("error:") for line in domains):
            raise Blocker("could not list libvirt domains")
        self.vm_initial_state = {
            name: self.virsh(["domstate", name], check=False) if name in domains else None
            for name in self.vm_names_for_run()
        }
        for name in self.vm_names_for_run():
            state = self.vm_initial_state[name]
            snapshot = self.domain_snapshot(name, state)
            self.vm_initial_snapshots[name] = snapshot
            if state is not None:
                volume_path = snapshot["volume"]["path"]
                volume_xml = snapshot["volume"]["xml"] or ""
                if not self.expected_domain_xml(name, snapshot["domain_xml"] or "", volume_xml, base_path) or volume_path != self.overlay_path(name, base_path):
                    raise Blocker(f"refusing to reuse domain {name}: ownership, disk chain, or network does not match exactly")
                if state not in ("running", "shut off"):
                    raise Blocker(f"domain {name} is in unexpected state: {state}")
                self.vm_owned_by_harness.add(name)
            elif snapshot["volume"]["info"].startswith("error:") and not self.volume_query_is_missing(snapshot["volume"]["info"]):
                raise Blocker(f"could not query volume {name}.qcow2")
            elif self.volume_query_is_present(snapshot["volume"]["info"]):
                raise Blocker(f"volume {name}.qcow2 exists without an owned domain")
        if not self.port_free(self.core_port):
            raise Blocker(f"host port {self.core_port} is already occupied")
        self.report["evidence"]["preflight"] = {
            "required_tools": required, "existing_domains": sorted(domains),
            "host_user": HOST_GIT_USER, "host_home": str(HOST_HOME), "base_path": str(self.base_path),
            "validated_vm_public_key": True, "image": self.image, "lock": str(LOCK_PATH),
            "initial_vm_state": self.vm_initial_state,
            "domain_snapshots": self.vm_initial_snapshots,
            "created_by_run": [],
        }
        self.report["evidence"]["prepared_base"] = dict(self.prepared_pointer)
        return access_pub

    def render_config(self, host_ip: str) -> None:
        key = self.runtime / "git_key"
        remote = f"ssh://{HOST_GIT_USER}@{host_ip}:22{self.runtime}/remote.git"
        qtoml = lambda value: json.dumps(str(value))
        nodes = "\n".join(f"[nodes.{node}]" for node in self.node_names_for_run())
        config = f'''[app]
port = {self.core_port}
host = "{'0.0.0.0' if self.runtime_variant == 'kata' else '127.0.0.1'}"

[db]
port = {self.database_internal_port}

[auth]
enabled = false

[limits]
max_concurrent_containers = {self.max_concurrent_containers}
cpu_per_container = {self.cpu_per_container}
memory_per_container = {qtoml(self.memory_per_container)}
pids_limit = {self.pids_limit}

[runtimes.{self.runtime_backend}.{self.runtime_variant}.{self.runtime_distribution}.images]
opencode = "omashiki/agent:latest"
claude-code = "omashiki/agent-claude:latest"
codex = "omashiki/agent-codex:latest"
pi = "omashiki/agent-pi:latest"
{self.artifact_image_key} = {qtoml(self.image)}

[nodes.core]
{nodes}

[vm_e2e]
project = {qtoml(self.project_slug)}
purpose = {qtoml(self.purpose)}
ownership_marker = {qtoml(self.ownership_marker)}
run_id = {qtoml(self.run_id)}
runtime_variant = {qtoml(self.runtime_variant)}
container_label_expectation = "omashiki.correlation_id"

[repositories.{self.repository_name}]
base_branch = "master"
remote = {qtoml(remote)}
ssh_key = {qtoml(key)}

[presets.lt-stub]
plugin = "{self.artifact_image_key}"
options = {{ timeout_ms = {self.job_timeout_ms}, model = "fake-model" }}

[credentials.loadtest-fake]
provider = "openai"
model = "fake-model"
api_key = "unused-by-the-stub"
base_url = "http://127.0.0.1:{self.fake_provider_port}/v1"

[environments.{self.environment_name}]
preset = "lt-stub"
runtime = "{self.runtime_name}"
sink = "git"
packages = []
executables = ["git"]
credentials = ["loadtest-fake"]
caches = []
timeout_ms = {self.job_timeout_ms}
network = "{'restricted' if self.runtime_variant == 'kata' else 'host'}"
mounts = []
pre_steps = []
post_steps = []

[environments.{self.environment_name}.policy]
mode = "off"

[environments.{self.environment_name}.resources]
cpus = {self.cpu_per_container}
memory = {qtoml(self.memory_per_container)}
pids = {self.pids_limit}
'''
        (self.source / "omashiki.toml").write_text(config)
        os.chmod(self.source / "omashiki.toml", 0o600)

    def copy_source(self) -> None:
        self.source.mkdir(mode=0o700)
        excludes = [argument for item in self.source_excludes for argument in ("--exclude=" + item,)]
        self.local(["rsync", "-a", *excludes,
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
        self.source_identity = {"sha256": self.source_tree_identity(self.source)}

    def host_ip(self) -> str:
        text = self.output(["ip", "-4", "-o", "addr", "show", self.bridge_interface])
        match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/", text)
        if not match:
            raise Blocker("libvirt virbr0 has no IPv4 address")
        return match.group(1)

    def ensure_vms(self, access_pub: str) -> None:
        template = self.cloud_init_file.read_text()
        if any(placeholder not in template for placeholder in ("{{HOSTNAME}}", "{{SSH_PUBLIC_KEY}}")):
            raise Blocker("cloud-init template must expose HOSTNAME and SSH_PUBLIC_KEY placeholders")
        if any(directive in template for directive in ("package_update:", "packages:", "runcmd:")):
            raise Blocker("runtime cloud-init must not install packages or run bootstrap commands")
        for name in self.vm_names_for_run():
            userdata = self.state / f"cloud-init-{name}.yaml"
            userdata.write_text(template.replace("{{HOSTNAME}}", name).replace("{{SSH_PUBLIC_KEY}}", access_pub).replace("{{GUEST_USER}}", self.vm_user))
            os.chmod(userdata, 0o600)
            state = self.vm_initial_state[name]
            created = False
            if state is None:
                volume = self.virsh(["vol-info", f"{name}.qcow2", "--pool", self.pool], check=False)
                if volume.startswith("error:") and not self.volume_query_is_missing(volume):
                    raise Blocker(f"could not query overlay volume {name}.qcow2")
                if self.volume_query_is_present(volume):
                    raise Blocker(f"volume {name}.qcow2 exists without an owned domain")
                self.created_volumes.add(name)
                self.local(["virsh", "-c", self.qemu_uri, "vol-create-as", self.pool,
                            f"{name}.qcow2", f"{self.vm_disk_gib}G", "--format", "qcow2",
                            "--backing-vol", self.base_volume, "--backing-vol-format", "qcow2"])
                self.vm_created_by_run.add(name)
                install_args = [*VIRT_INSTALL, "--connect", self.qemu_uri, "--name", name,
                            "--memory", str(self.vm_memory_mib), "--vcpus", str(self.vm_vcpus), "--cpu", "host-passthrough",
                            "--disk", f"vol={self.pool}/{name}.qcow2,format=qcow2,bus=virtio",
                            "--import", "--os-variant", "generic", "--network", f"network={self.vm_network},model=virtio",
                            "--graphics", "none", "--console", "pty,target_type=serial",
                            "--metadata", f"title={self.ownership_marker}", "--cloud-init",
                            f"user-data={userdata}", "--autoconsole", "none"]
                self.local(install_args)
                self.vm_owned_by_harness.add(name)
                created = True
                self.vm_started_by_run.add(name)
            elif state not in ("running", "shut off"):
                raise Blocker(f"domain {name} is in unexpected state: {state}")
            if state == "shut off" and not created and self.virsh(["domstate", name], check=False) != "running":
                self.local(["virsh", "-c", self.qemu_uri, "start", name])
                self.vm_started_by_run.add(name)
        deadline = time.monotonic() + max(180, self.job_timeout_ms / 1000)
        while time.monotonic() < deadline:
            ready = True
            for name in self.vm_names_for_run():
                text = self.virsh(["domifaddr", name], check=False)
                match = re.search(r"(\d+\.\d+\.\d+\.\d+)/\d+", text)
                if match:
                    self.vm_ips[name] = match.group(1)
                else:
                    ready = False
            if ready:
                break
            time.sleep(3)
        if set(self.vm_ips) != set(self.vm_names_for_run()):
            raise Blocker("libvirt did not provide IPv4 leases for every declared VM")
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
        for name in self.vm_names_for_run():
            self.log(f"waiting for cloud-init and Docker readiness on {name}")
            auth_deadline = time.monotonic() + 180
            while time.monotonic() < auth_deadline:
                if self.ssh_result(name, "true", check=False).returncode == 0:
                    break
                time.sleep(3)
            else:
                raise Blocker(f"SSH authentication did not become ready on {name}")
            self.ssh(name, "for p in ~/.ssh ~/.ssh/known_hosts ~/.ssh/authorized_keys; do test ! -L \"$p\" || exit 71; done")
            self.ssh(name, "sudo -n cloud-init status --wait")
            check = ""
            readiness_deadline = time.monotonic() + 90
            while time.monotonic() < readiness_deadline:
                check = self.ssh(
                    name,
                    "command -v docker && command -v mix && command -v python3 && sudo -n docker info >/dev/null",
                    check=False,
                )
                if check:
                    break
                time.sleep(3)
            if not check:
                raise Blocker(f"{name} does not have Docker, Mix, Python, or passwordless Docker access")
            self.vm_selinux_initial[name] = self.ssh(name, "getenforce", check=False)
            if self.vm_selinux_initial[name] not in ("Enforcing", "Permissive", "Disabled"):
                raise Blocker(f"{name} returned an unknown SELinux state")
            if self.vm_selinux_initial[name] == "Enforcing":
                self.ssh(name, "sudo -n setenforce 0")
                self.vm_selinux_disabled.add(name)
            for port in (self.worker_port, self.fake_provider_port):
                if not self.guest_port_free(name, port):
                    raise Blocker(f"{name} target port {port} is already occupied")
            self.vm_authorized_snapshots[name] = self.remote_file_snapshot(
                name, f"/home/{self.vm_user}/.ssh/authorized_keys"
            )
            if created:
                self.vm_authorized_lines[name] = access_pub
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

    def remote_file_snapshot(self, name: str, path: str, *, privileged: bool = False) -> dict:
        payload = base64.b64encode(json.dumps({"path": path}).encode()).decode()
        code = REMOTE_SNAPSHOT_CODE.replace("PAYLOAD", payload)
        try:
            runner = "sudo -n python3" if privileged else "python3"
            snapshot = json.loads(self.ssh(name, f"{runner} -c {q(code)}"))
        except (json.JSONDecodeError, TypeError) as error:
            raise E2EError(f"could not snapshot guest file {name}:{path}") from error
        if not isinstance(snapshot, dict) or not isinstance(snapshot.get("exists"), bool):
            raise E2EError(f"invalid guest file snapshot {name}:{path}")
        return snapshot

    def remote_file_restore(self, name: str, path: str, snapshot: dict, *, privileged: bool = False) -> bool:
        payload = dict(snapshot)
        payload["path"] = path
        encoded = base64.b64encode(json.dumps(payload).encode()).decode()
        code = REMOTE_RESTORE_CODE.replace("PAYLOAD", encoded)
        runner = "sudo -n python3" if privileged else "python3"
        if self.ssh(name, f"{runner} -c {q(code)}", check=False) != "restored":
            return False
        return True

    def snapshot_without_line(self, snapshot: dict, line: str) -> dict:
        if not snapshot.get("exists"):
            return snapshot
        raw = base64.b64decode(snapshot["bytes"])
        lines = [item for item in raw.splitlines(True) if item.rstrip(b"\r\n") != line.encode()]
        expected = dict(snapshot)
        expected["bytes"] = base64.b64encode(b"".join(lines)).decode()
        return expected

    def generate_git_key(self) -> None:
        self.runtime.mkdir(mode=0o700)
        self.local(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C",
                    f"{self.project_slug}-vm-e2e-{self.run_id}", "-f", str(self.runtime / "git_key")])
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
        for name in self.vm_names_for_run():
            known_path = f"/home/{self.vm_user}/.ssh/known_hosts"
            self.vm_known_snapshots[name] = self.remote_file_snapshot(name, known_path)
            result = self.remote_line_update(name, known_path, add=self.host_known_lines)
            self.vm_known_added[name] = result["added"]
        self.report["evidence"]["known_hosts"] = {
            "shared_host_file_modified": False,
            "run_file": str(known),
            "guest_newly_added": self.vm_known_added,
            "guest_original": {name: {"exists": snapshot["exists"], "mode": snapshot.get("mode"), "sha256": hashlib.sha256(base64.b64decode(snapshot.get("bytes", ""))).hexdigest() if snapshot["exists"] else None} for name, snapshot in self.vm_known_snapshots.items()},
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
        self.db_container = f"{self.project_slug}-vm-e2e-db-{self.run_id}"
        self.local(["docker", "run", "--detach", "--name", self.db_container,
                    "--label", f"omashiki.vm_e2e={self.run_id}", "--label", f"omashiki.vm_e2e_project={self.project_slug}",
                    "--label", f"omashiki.vm_e2e_purpose={self.purpose}", "--label", f"omashiki.vm_e2e_marker={self.ownership_marker}",
                    "-e", "POSTGRES_USER=postgres",
                    "-e", "POSTGRES_PASSWORD=postgres", "-e", "POSTGRES_DB=omashiki_dev",
                    "-p", f"127.0.0.1::{self.database_internal_port}", self.database_image])
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
            raise E2EError("database query refused: database container is not registered")
        result = self.local(["docker", "exec", self.db_container, "psql", "-U", "postgres", "-d", "omashiki_dev", "-A", "-t", "-F", "\t", "-c", sql], check=False)
        if result.returncode != 0:
            raise E2EError(f"database query failed: {result.stdout.decode(errors='replace')[-500:]}")
        rows = [line.split("\t") for line in result.stdout.decode().splitlines() if line]
        self.db_query_verified = True
        return rows

    def prepare_host(self) -> None:
        env = os.environ.copy()
        env.update({"MIX_ENV": "vm_e2e", "OMASHIKI_DB_PORT": str(self.db_port), "OMASHIKI_AGENT_NETWORK_MODE": "host"})
        server = self.source / "server"
        self.local(["mix", "deps.get"], cwd=server, env=env)
        self.local(["mix", "compile"], cwd=server, env=env)
        self.local(["mix", "ecto.create", "--quiet"], cwd=server, env=env, check=False)
        self.local(["mix", "ecto.migrate", "--quiet"], cwd=server, env=env)

    def sync_workers(self) -> None:
        if not self.source_identity:
            raise E2EError("source identity was not captured before guest delivery")
        excludes = list(self.source_excludes)
        source_code = (
            "import hashlib,json,pathlib;root=pathlib.Path(" + repr(str(self.guest_source)) + ");"
            "excluded=" + repr(excludes) + ";h=hashlib.sha256();"
            "paths=sorted(root.rglob('*'));"
            "[(h.update(str(p.relative_to(root)).encode()+b'\\0'),[h.update(c) for c in iter(lambda:f.read(1048576),b'')]) for p in paths if p.is_file() and not p.is_symlink() and not any(pathlib.Path(x)==p.relative_to(root) or pathlib.Path(x) in p.relative_to(root).parents for x in excluded) for f in [p.open('rb')]];"
            "print(h.hexdigest())"
        )
        names = self.vm_names_for_run()

        def sync_source(name: str) -> None:
            self.log(f"preparing source and runtime on {name}")
            self.ssh(name, f'''set -e
test ! -e {q(self.guest_root)} && test ! -L {q(self.guest_root)}
mkdir -m 700 {q(self.guest_root)}
test "$(stat -c %u {q(self.guest_root)})" = "$(id -u)"
mkdir -m 700 {q(self.guest_source)} {q(self.guest_logs)}
test ! -L {q(self.guest_source)} && test ! -L {q(self.guest_logs)}
''')
            self.configure_guest_runtime(name)
            rsync_ssh = "ssh -i %s -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s" % (q(HOST_HOME / ".ssh" / "id_vms"), q(self.state / "vm_known_hosts"))
            self.local(["rsync", "-az", "--delete", *["--exclude=" + item for item in self.source_excludes], "-e", rsync_ssh, f"{self.source}/", f"{self.vm_user}@{self.vm_ips[name]}:{self.guest_source}/"])
            self.ssh(name, f"test -d {q(self.guest_root)} && test \"$(stat -c %u {q(self.guest_root)})\" = \"$(id -u)\"")
            remote_source_identity = self.ssh(name, f"python3 -c {q(source_code)}")
            if remote_source_identity != self.source_identity["sha256"]:
                raise E2EError(f"source identity mismatch on {name}: {remote_source_identity}")
            self.scp_to(name, self.runtime / "git_key", str(self.guest_root / "git_key"))
            self.ssh(name, f"chmod 600 {q(self.guest_root / 'git_key')}")

        with ThreadPoolExecutor(max_workers=len(names), thread_name_prefix="vm-source") as executor:
            list(executor.map(sync_source, names))
        self.report["evidence"]["guest_paths"] = {
            "root": str(self.guest_root), "source": str(self.guest_source), "logs": str(self.guest_logs),
        }
        image_tar = self.state / f"{self.artifact_image_key}.tar.gz"
        with image_tar.open("wb") as output:
            save = subprocess.Popen(["docker", "save", self.image], stdout=subprocess.PIPE)
            gzip = subprocess.Popen(["gzip", "-c"], stdin=save.stdout, stdout=output)
            assert save.stdout is not None
            save.stdout.close()
            if gzip.wait() != 0 or save.wait() != 0:
                raise E2EError("docker save failed")
        image_tar_identity = self.file_identity(image_tar)
        host_image_id = self.output(["docker", "image", "inspect", "-f", "{{.Id}}", self.image])
        self.report["evidence"]["artifact"] = {
            "image": self.image, "host_image_id": host_image_id,
            "tar": image_tar_identity, "source": self.source_identity,
        }
        def load_image(name: str) -> tuple[str, str]:
            self.log(f"transferring and loading the agent image on {name}")
            destination = self.runtime / f"{self.artifact_image_key}.tar.gz"
            self.scp_to(name, image_tar, str(destination))
            remote_tar_identity = self.ssh(name, f"sha256sum {q(destination)} | cut -d' ' -f1")
            if remote_tar_identity != image_tar_identity["sha256"]:
                raise E2EError(f"image archive checksum mismatch on {name}")
            self.ssh(name, f"gzip -dc {q(destination)} | sudo -n docker load >/dev/null && rm -f {q(destination)}")
            remote_id = self.ssh(name, f"sudo -n docker image inspect -f '{{{{.Id}}}}' {q(self.image)}")
            if remote_id != host_image_id:
                raise E2EError(f"loaded image ID mismatch on {name}: {remote_id}")
            self.probe_guest_runtime(name)
            return name, remote_id

        with ThreadPoolExecutor(max_workers=len(names), thread_name_prefix="vm-image") as executor:
            image_ids = dict(executor.map(load_image, names))
        self.report["evidence"]["image_ids"] = image_ids
        self.report["evidence"]["image_ids"]["host"] = host_image_id

        def compile_worker(name: str) -> None:
            self.log(f"compiling the worker source on {name}")
            env = f"MIX_ENV=vm_e2e MIX_DEPS_PATH={self.guest_mix_cache}/deps MIX_BUILD_PATH={self.guest_mix_cache}/_build HOME=/home/{self.vm_user} OMASHIKI_AGENT_NETWORK_MODE=host OMASHIKI_VM_E2E_RUN_ID={self.run_id} OMASHIKI_VM_RUNTIME_VARIANT={self.runtime_variant}"
            self.ssh(name, f"cd {q(self.guest_source / 'server')} && {env} mix deps.get && {env} mix compile")

        with ThreadPoolExecutor(max_workers=len(names), thread_name_prefix="vm-compile") as executor:
            list(executor.map(compile_worker, names))

    def configure_guest_runtime(self, name: str) -> None:
        if self.runtime_variant != "kata":
            return
        daemon_code = f'''import json, pathlib
path = pathlib.Path({self.kata_daemon_config!r})
expected = {{
    "runtimeType": {self.kata_runtime_path!r},
    "options": {{"ConfigPath": {self.kata_config_path!r}}},
}}
data = json.loads(path.read_text())
raise SystemExit(0 if data.get("runtimes", {{}}).get("kata") == expected else 1)
'''
        script = f'''set -euo pipefail
sudo -n test -c /dev/kvm
sudo -n test -r /dev/kvm
sudo -n test -w /dev/kvm
sudo -n test -x {q(self.kata_runtime_path)}
sudo -n test -x {q(self.kata_hypervisor_path)}
sudo -n test -f {q(self.kata_config_path)}
sudo -n grep -q '^\\[hypervisor\\.clh\\]$' {q(self.kata_config_path)}
sudo -n grep -q '^path = "/opt/kata/bin/cloud-hypervisor"$' {q(self.kata_config_path)}
sudo -n grep -q '^hypervisor_name = "clh"$' {q(self.kata_config_path)}
sudo -n python3 -c {q(daemon_code)}
sudo -n dockerd --validate --config-file={q(self.kata_daemon_config)}
sudo -n docker info --format '{{{{json .Runtimes}}}}' | grep -q '"kata"'
sudo -n {q(self.kata_runtime_path)} --version
sudo -n {q(self.kata_hypervisor_path)} --version
'''
        self.ssh(name, script)
        self.report["evidence"].setdefault("prepared_guest_runtime", {})[name] = True

    def probe_guest_runtime(self, name: str) -> None:
        runtime = self.runtime_variant
        result = self.guest_docker_result(
            name,
            f"run --rm --runtime {q(runtime)} --entrypoint /bin/true {q(self.image)}",
            timeout=60,
        )
        if result.returncode != 0:
            raise E2EError(f"{name} Docker runtime probe failed for {runtime}")
        self.report["evidence"].setdefault("runtime_probes", {})[name] = {
            "runtime": runtime, "image": self.image, "passed": True,
        }

    def start_tunnels(self) -> None:
        self.vm_db_port = self.tunnel_port_base + (int(self.run_id[-6:], 16) % 1000)
        for name in self.vm_names_for_run():
            if not self.guest_port_free(name, self.vm_db_port):
                raise Blocker(f"{name} reverse-tunnel port {self.vm_db_port} is already occupied")
            args = self.ssh_args(self.vm_ips[name])[:-1] + ["-N", "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{self.vm_db_port}:127.0.0.1:{self.db_port}", f"{self.vm_user}@{self.vm_ips[name]}"]
            log = (self.logs / f"{name}-db-tunnel.log").open("ab")
            process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            self.tunnels.append(process)
            deadline_identity = time.monotonic() + 3
            identity = None
            while time.monotonic() < deadline_identity and identity is None and process.poll() is None:
                identity = self.read_host_process_identity(process, "ssh")
                if identity is None:
                    time.sleep(0.05)
            if identity is None:
                raise E2EError(f"could not capture tunnel process identity for {name}")
            self.tunnel_metadata[process.pid] = identity
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if all(process.poll() is None for process in self.tunnels):
                good = True
                for name in self.vm_names_for_run():
                    probe = self.ssh(name, f"python3 -c {q(f'import socket;s=socket.create_connection((\'127.0.0.1\',{self.vm_db_port}),2);s.close()')}", check=False)
                    if probe:
                        good = False
                if good:
                    return
            time.sleep(1)
        raise E2EError("SSH reverse database tunnels did not become reachable")

    def host_process_alive(self, name: str) -> bool:
        process = self.host_processes.get(name)
        expected = self.host_process_metadata.get(name)
        current = self.read_host_process_identity(process, "mix phx.server") if process is not None and process.poll() is None else None
        return expected is not None and self.same_process_identity(current, expected)

    def same_process_identity(self, current: dict | None, expected: dict) -> bool:
        fields = ("pid", "starttime", "pgrp", "session")
        return isinstance(current, dict) and all(current.get(field) == expected.get(field) for field in fields)

    def remote_process_metadata(self, name: str, pid: str, expected: str) -> dict | None:
        code = (
            "import json,os;pid=int(" + repr(pid) + ");expected=" + repr(expected) + ";root=" + repr(str(self.guest_root)) + ";"
            "raw=open('/proc/%d/stat'%pid).read();tail=raw[raw.rfind(') ')+2:].split();"
            "cmd=open('/proc/%d/cmdline'%pid,'rb').read().replace(b'\\0',b' ').decode(errors='replace').strip();"
            "cwd=os.readlink('/proc/%d/cwd'%pid);data={'pid':pid,'starttime':int(tail[19]),'pgrp':os.getpgid(pid),'session':os.getsid(pid),'proc_pgrp':int(tail[2]),'proc_session':int(tail[3]),'cmdline':cmd,'cwd':cwd};"
            "assert expected in cmd;assert cwd==root or cwd.startswith(root+'/');assert data['pgrp']==data['proc_pgrp'];assert data['session']==data['proc_session'];print(json.dumps(data,sort_keys=True))"
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
            raise E2EError(f"could not query guest processes on {name}")
        try:
            found = json.loads(result.stdout.decode(errors="replace").strip())
        except json.JSONDecodeError as error:
            raise E2EError(f"guest process query returned invalid JSON on {name}") from error
        if not isinstance(found, list) or not all(isinstance(item, dict) for item in found):
            raise E2EError(f"guest process query returned invalid data on {name}")
        return found

    def remote_process_alive(self, key: str) -> bool:
        if key not in self.remote_pids:
            return False
        metadata = self.remote_pids[key]
        current = self.remote_process_metadata(metadata["name"], metadata["pid"], metadata["expected"])
        if current is not None:
            current.update({"name": metadata["name"], "expected": metadata["expected"], "run_root": metadata["run_root"]})
        return current == metadata

    def same_remote_process_identity(self, current: dict | None, expected: dict) -> bool:
        fields = ("pid", "starttime", "pgrp", "session", "proc_pgrp", "proc_session", "cmdline", "cwd")
        return isinstance(current, dict) and all(current.get(field) == expected.get(field) for field in fields)

    def read_host_process_identity(self, process: subprocess.Popen, expected: str) -> dict | None:
        try:
            raw = Path(f"/proc/{process.pid}/stat").read_text()
            tail = raw[raw.rfind(") ") + 2:].split()
            cmdline = Path(f"/proc/{process.pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            pgrp = os.getpgid(process.pid)
            session = os.getsid(process.pid)
            if expected not in cmdline or pgrp != process.pid or session != process.pid or int(tail[2]) != pgrp or int(tail[3]) != session:
                return None
            return {"pid": process.pid, "starttime": int(tail[19]), "pgrp": pgrp, "session": session, "cmdline": cmdline}
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError, OSError):
            return None

    def start_host_process(self, name: str, env_values: dict[str, str], log_name: str) -> None:
        if not self.port_free(self.core_port):
            raise Blocker(f"host port {self.core_port} became occupied before core start")
        env = os.environ.copy()
        env.update(env_values)
        log = (self.logs / log_name).open("ab")
        process = subprocess.Popen(["mix", "phx.server"], cwd=self.source / "server", env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        self.host_processes[name] = process
        deadline = time.monotonic() + 3
        identity = None
        while time.monotonic() < deadline and identity is None and process.poll() is None:
            identity = self.read_host_process_identity(process, "mix phx.server")
            if identity is None:
                time.sleep(0.05)
        if identity is None:
            raise E2EError(f"could not capture host process identity for {name}")
        self.host_process_metadata[name] = identity
        self.report["evidence"].setdefault("host_processes", {})[name] = identity

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
            if self.same_remote_process_identity(current, metadata):
                candidates = [current]
            else:
                candidates = self.discover_run_processes(name, metadata["expected"])
            stopped = True
            for candidate in candidates:
                candidate_pgrp = candidate.get("pgrp")
                revalidated = self.remote_process_metadata(name, str(candidate.get("pid", "")), metadata["expected"])
                if not self.same_remote_process_identity(revalidated, candidate) or not isinstance(candidate_pgrp, int) or candidate_pgrp <= 0:
                    stopped = False
                    continue
                stopped = self.ssh_result(name, f"timeout 8s kill -TERM -- -{q(candidate_pgrp)}", check=False).returncode == 0 and stopped
            if candidates:
                time.sleep(2)
                remaining = self.discover_run_processes(name, metadata["expected"])
                for candidate in remaining:
                    candidate_pgrp = candidate.get("pgrp")
                    revalidated = self.remote_process_metadata(name, str(candidate.get("pid", "")), metadata["expected"])
                    if self.same_remote_process_identity(revalidated, candidate) and isinstance(candidate_pgrp, int) and candidate_pgrp > 0:
                        stopped = self.ssh_result(name, f"timeout 8s kill -KILL -- -{q(candidate_pgrp)}", check=False).returncode == 0 and stopped
                    else:
                        stopped = False
                time.sleep(1)
            result[key] = stopped and not self.discover_run_processes(name, metadata["expected"])
        return result

    def stop_host_processes(self) -> bool:
        stopped = True
        for name, process in self.host_processes.items():
            if process.poll() is None:
                identity = self.read_host_process_identity(process, "mix phx.server")
                if not self.same_process_identity(identity, self.host_process_metadata.get(name, {})):
                    stopped = False
                    continue
                try:
                    os.killpg(identity["pgrp"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for name, process in self.host_processes.items():
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                identity = self.read_host_process_identity(process, "mix phx.server")
                if not self.same_process_identity(identity, self.host_process_metadata.get(name, {})):
                    stopped = False
                    continue
                try:
                    os.killpg(identity["pgrp"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        return stopped and all(process.poll() is not None for process in self.host_processes.values()) and self.port_free(self.core_port)

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
                    log_path = self.logs / "core.log"
                    log_tail = log_path.read_text(errors="replace")[-4000:] if log_path.is_file() else ""
                    raise E2EError(f"captured core process exited before readiness\n{log_tail}")
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
        request = urllib.request.Request(f"http://127.0.0.1:{self.core_port}" + path, method=method)
        request.add_header("Content-Type", "application/json")
        if token:
            request.add_header("Authorization", "Bearer " + token)
        try:
            with urllib.request.urlopen(request, data=json.dumps(payload).encode() if payload is not None else None, timeout=10) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def attempts(self) -> list[dict]:
        sql = """SELECT a.id,a.job_id,a.status,COALESCE(a.machine_id,''),COALESCE(j.status,''),COALESCE(a.error::text,'')
                 FROM job_attempts a JOIN jobs j ON j.id=a.job_id
                 WHERE j.correlation_id='VM_E2E_%s' ORDER BY a.id""" % self.run_id
        rows = self.db_query(sql)
        if any(len(row) != 6 for row in rows):
            raise E2EError("database attempts query returned malformed rows")
        return [{"id": row[0], "job_id": row[1], "attempt_status": row[2], "machine_id": row[3],
                 "job_status": row[4], "error": row[5]} for row in rows]

    def live_containers(self) -> dict[str, list[dict]]:
        found = {"core": [], **{name: [] for name in self.vm_names_for_run()}}
        found["core"] = self.container_records(correlation_id="")
        for name in self.vm_names_for_run():
            found[name] = self.container_records(name, correlation_id="")
        return found

    def container_records(self, name: str | None = None, *, all_containers: bool = False,
                          scope_id: str | None = None, correlation_id: str | None = None) -> list[dict]:
        filters = [f"label=omashiki.job_scope_id={scope_id}" if scope_id else "label=omashiki.job_scope_id"]
        if correlation_id is None:
            correlation_id = self.correlation_id
        if correlation_id:
            filters.append(f"label=omashiki.correlation_id={correlation_id}")
        args = ["ps"] + (["-a"] if all_containers else [])
        for value in filters:
            args.extend(["--filter", value])
        args.extend(["--no-trunc", "-q"])
        format_value = "{{.Id}}\t{{index .Config.Labels \"omashiki.correlation_id\"}}\t{{index .Config.Labels \"omashiki.job_scope_id\"}}\t{{.HostConfig.Runtime}}"
        if name is None:
            ids = self.host_docker_result(args).stdout.decode(errors="replace").split()
            if not ids:
                return []
            result = self.host_docker_result(["inspect", "--format", format_value, *ids])
        else:
            ids = self.guest_docker_result(name, " ".join(q(value) for value in args)).stdout.decode(errors="replace").split()
            if not ids:
                return []
            if any(not re.fullmatch(r"[0-9a-fA-F]{12,64}", container_id) for container_id in ids):
                raise E2EError("Docker returned malformed container IDs")
            result = self.guest_docker_result(
                name, "inspect --format " + q(format_value) + " " + " ".join(q(container_id) for container_id in ids)
            )
        records = []
        for line in result.stdout.decode(errors="replace").splitlines():
            parts = line.split("\t")
            if len(parts) != 4 or not re.fullmatch(r"[0-9a-fA-F]{12,64}", parts[0]):
                raise E2EError(f"Docker returned malformed container identity data: {line!r}")
            records.append({"id": parts[0], "correlation_id": parts[1],
                            "scope_id": parts[2], "runtime": parts[3]})
        return records

    def run_jobs(self) -> None:
        common_env = {"OMASHIKI_VM_E2E_RUN_ID": self.run_id, "OMASHIKI_VM_RUNTIME_VARIANT": self.runtime_variant}
        self.start_host_process("core", {**common_env, "MIX_ENV": "vm_e2e", "OMASHIKI_NODE": "core", "OMASHIKI_AGENT_NETWORK_MODE": "host", "OBAN_SCHEDULER_LIMIT": "0", "OMASHIKI_DB_PORT": str(self.db_port), "PORT": str(self.core_port)}, "core.log")
        self.wait_http(f"http://127.0.0.1:{self.core_port}/api/v1/health")
        worker_network_mode = self.worker_network_mode()
        for name, node in zip(self.vm_names_for_run(), self.node_names_for_run()):
            self.start_remote_process(name, "fake", {**common_env, "SCENARIO": self.fake_scenario, "LAT_MS": str(self.fake_latency_ms), "JITTER_PCT": str(self.jitter_pct), "PORT": str(self.fake_provider_port), "HOST": "127.0.0.1"}, "fake-llm.log", self.fake_provider_port)
            self.start_remote_process(name, "worker", {**common_env, "MIX_ENV": "vm_e2e", "MIX_DEPS_PATH": f"{self.guest_mix_cache}/deps", "MIX_BUILD_PATH": f"{self.guest_mix_cache}/_build", "OMASHIKI_NODE": node, "OMASHIKI_AGENT_NETWORK_MODE": worker_network_mode, "OBAN_SCHEDULER_LIMIT": str(self.per_node_capacity), "OMASHIKI_DB_PORT": str(self.vm_db_port), "PORT": str(self.worker_port)}, "omashiki.log", self.worker_port)
            self.wait_http(f"http://127.0.0.1:{self.fake_provider_port}/healthz", remote=name, process_key=f"{name}:fake")
            self.wait_http(f"http://127.0.0.1:{self.worker_port}/api/v1/health", remote=name, process_key=f"{name}:worker")
        username = f"vm_e2e_{self.run_id.replace('-', '_')}"
        password = secrets.token_urlsafe(24)
        status, body = self.api("POST", "/api/v1/sessions/signup", {"email": username + "@example.test", "username": username, "password": password, "name": "VM E2E"})
        if status != 201 or not body.get("data", {}).get("token"):
            raise E2EError(f"API signup failed with HTTP {status}: {body}")
        token = body["data"]["token"]
        correlation = "VM_E2E_" + self.run_id
        jobs = []
        markers = {}
        for index in range(1, self.workload_count + 1):
            title = f"vm-e2e-{self.run_id}-{index}"
            marker = f"vm-e2e-marker-{self.run_id}-{index}"
            markers[marker] = index
            jobs.append({"ref": title, "idempotency_key": f"{title}-idempotency", "repo": self.repository_name, "environment": self.environment_name, "payload": {"instruction": f'Create {self.expected_file} containing exactly {self.expected_content.decode().rstrip()} followed by a newline, then commit it. Test marker: {marker}', "title": title, "context": {"correlation_id": self.correlation_id}}, "priority": 1})
        status, body = self.api("POST", "/api/v1/jobs/batch", {"schema_version": 1, "correlation_id": correlation, "jobs": jobs}, token)
        if status != 202 or len(body.get("data", [])) != self.workload_count:
            raise E2EError(f"batch admission failed with HTTP {status}: {body}")
        self.job_ids = [item["id"] for item in body["data"]]
        self.report["evidence"]["admission"] = {"http_status": status, "job_ids": self.job_ids, "idempotency_keys": [job["idempotency_key"] for job in jobs]}
        deadline = time.monotonic() + max(180, self.job_timeout_ms / 1000)
        overlap = None
        last_rows = []
        last_containers = {}
        while time.monotonic() < deadline:
            rows = self.attempts()
            last_rows = rows
            self.attempt_ids = [row["id"] for row in rows]
            active = [row for row in rows if row["attempt_status"] in ("provisioning", "running")]
            if len(rows) == self.workload_count and len(active) == self.workload_count:
                containers = self.live_containers()
                last_containers = containers
                entries = [item for values in containers.values() for item in values]
                expected_scopes = {f"job-{row['id']}" for row in active}
                relevant = [item for item in entries if item["scope_id"] in expected_scopes]
                by_scope = {item["scope_id"]: item for item in relevant}
                ids = [item["id"] for item in relevant]
                if (len(relevant) == self.workload_count and len(by_scope) == self.workload_count and
                        len(set(ids)) == self.workload_count and set(by_scope) == expected_scopes and
                        all(item["correlation_id"] == self.correlation_id and item["runtime"] == self.runtime_variant for item in relevant)):
                    overlap = {"observed_at": time.time(), "active_attempts": active,
                               "containers": {row["id"]: {"vm": next(name for name, values in containers.items() if any(item["id"] == by_scope[f"job-{row['id']}"]["id"] for item in values)),
                                                          "container_id": by_scope[f"job-{row['id']}"]["id"], "runtime": by_scope[f"job-{row['id']}"]["runtime"]} for row in active},
                                "all_live_containers": containers, "relevant_count": len(relevant)}
                    break
            if len(rows) == self.workload_count and all(row["attempt_status"] in ("blocked", "succeeded", "failed", "cancelled") for row in rows):
                break
            time.sleep(0.25)
        if overlap is None:
            raise E2EError(
                f"the {self.workload_count} active attempts never overlapped with exactly "
                f"{self.workload_count} distinct labelled containers: attempts={last_rows}, containers={last_containers}"
            )
        self.report["evidence"]["overlap"] = overlap
        counts = {node: sum(row["machine_id"] == node for row in overlap["active_attempts"]) for node in (*self.node_names_for_run(), "core")}
        expected_counts = {node: self.per_node_capacity for node in self.node_names_for_run()} | {"core": 0}
        if counts != expected_counts:
            raise E2EError(f"unexpected active machine distribution: {counts}")
        per_vm = {name: len(values) for name, values in overlap["all_live_containers"].items()}
        if per_vm != {"core": 0, **{name: self.per_node_capacity for name in self.vm_names_for_run()}}:
            raise E2EError(f"unexpected labelled container distribution: {per_vm}")
        for row in overlap["active_attempts"]:
            if overlap["containers"][row["id"]]["vm"] != self.domain_prefix + "-" + row["machine_id"]:
                raise E2EError(f"attempt {row['id']} has a container on the wrong VM")
            if overlap["containers"][row["id"]]["runtime"] != self.runtime_variant:
                raise E2EError(f"attempt {row['id']} used the wrong Docker runtime")
        deadline = time.monotonic() + max(240, self.job_timeout_ms / 1000)
        while time.monotonic() < deadline:
            rows = self.attempts()
            if len(rows) == self.workload_count and all(row["job_status"] == "succeeded" and row["attempt_status"] == "succeeded" for row in rows):
                break
            time.sleep(1)
        else:
            raise E2EError(f"not all {self.workload_count} jobs reached success: {self.attempts()}")
        stats = {}
        all_served_markers = set()
        for name in self.vm_names_for_run():
            value = self.remote_json(name, f"http://127.0.0.1:{self.fake_provider_port}/__stats")
            served = value.get("job_markers", [])
            if (
                len(served) != self.per_node_capacity
                or value.get("requests") != self.per_node_capacity * 2
                or value.get("completions") != self.per_node_capacity * 2
                or value.get("tool_call_turns") != self.per_node_capacity
                or value.get("stops") != self.per_node_capacity
                or value.get("peak_in_flight") != self.per_node_capacity
                or value.get("job_marker_peak") != self.per_node_capacity
                or len(set(served)) != self.per_node_capacity
            ):
                raise E2EError(f"fake provider on {name} did not serve {self.per_node_capacity} jobs concurrently: {value}")
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
            content = self.local(["git", "--git-dir", str(self.runtime / "remote.git"), "show", f"refs/heads/{branch}:{self.expected_file}"], cwd=ROOT).stdout
            if content != self.expected_content:
                raise E2EError(f"canonical branch {branch} has non-canonical hello.py content")
            exec_dir = self.state / "executed" / branch
            exec_dir.mkdir(parents=True, mode=0o700)
            archive = subprocess.run(["git", "--git-dir", str(self.runtime / "remote.git"), "archive", branch], stdout=subprocess.PIPE, check=True)
            subprocess.run(["tar", "-x", "-C", str(exec_dir)], input=archive.stdout, check=True)
            run = subprocess.run(["python3", str(exec_dir / self.expected_file)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            if run.returncode != 0 or run.stdout != self.expected_output or run.stderr != b"":
                raise E2EError(f"executing {branch}: expected exact configured output")
            results.append({"job_id": job_id, "branch": branch, "head_sha": result.get("head_sha"), "hello_sha": canonical, "worktree_clean": result.get("worktree_clean")})
        self.report["evidence"]["results"] = results
        if len({result["branch"] for result in results}) != self.workload_count:
            raise E2EError(f"the {self.workload_count} results did not produce {self.workload_count} unique branches")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and any(self.live_containers().values()):
            time.sleep(1)
        remaining = self.live_containers()
        if any(remaining.values()):
            raise E2EError(f"labelled containers remain after terminal success: {remaining}")
        for name in self.vm_names_for_run():
            worktrees = self.ssh(name, f"git -C {q('/home/' + self.vm_user + '/' + self.remote_mirror)} worktree list --porcelain", check=False)
            if ".omashiki-worktrees/" in worktrees:
                raise E2EError(f"worktrees remain on {name}: {worktrees}")
        capacity = self.db_query("SELECT machine_id,capacity,active FROM execution_capacity ORDER BY machine_id")
        capacity_rows = [{"machine_id": row[0], "capacity": int(row[1]), "active": int(row[2])} for row in capacity if len(row) >= 3]
        if {row["machine_id"] for row in capacity_rows} != {*self.node_names_for_run(), "core"} or any(row["active"] != 0 for row in capacity_rows):
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
        required = ["host_processes_stopped", "reverse_tunnels_stopped", "evidence_logs_copied", "temporary_auth_removed", "runtime_removed", "database_removed", "labelled_containers_absent", "vms_stopped", "vm_retention_complete", "guest_known_hosts_additions_removed", "guest_authorized_keys_restored", "guest_runtime_restored"]
        required.extend(f"{name}_containers_removed" for name in self.vm_names_for_run())
        required.extend(f"{name}_known_hosts_additions_removed" for name in self.vm_names_for_run())
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
        self.db_query_verified = not bool(self.db_container)
        if self.db_container:
            try:
                rows = self.attempts()
                self.attempt_ids = [row["id"] for row in rows]
            except Exception as error:
                self.db_query_verified = False
                self.cleanup_errors.append(f"attempts_query: {error}")
                self.log(f"cleanup failure (attempts query): {error}")
        for name in self.vm_names_for_run():
            if name in self.vm_ips:
                removed = self.cleanup_step(f"{name}_containers_removed", lambda name=name: self.remove_guest_containers(name))
                self.report["cleanup"][f"{name}_containers_removed"] = bool(removed)
            else:
                self.report["cleanup"][f"{name}_containers_removed"] = True
        self.cleanup_step("core_containers_removed", self.remove_host_containers)
        auth_removed = True
        if self.authorized_line and self.authorized_added:
            result = self.cleanup_step("temporary_authorized_key_removed", lambda: self.atomic_line_update(HOST_HOME / ".ssh" / "authorized_keys", remove=[self.authorized_line]))
            auth_removed = bool(result and self.authorized_line in result.get("removed", []))
        self.report["cleanup"]["temporary_auth_removed"] = auth_removed
        if self.vm_ips:
            known_removed = True
            for name in self.vm_names_for_run():
                snapshot = self.vm_known_snapshots.get(name)
                if snapshot is not None:
                    known_path = f"/home/{self.vm_user}/.ssh/known_hosts"
                    removed = bool(self.cleanup_step(f"{name}_known_hosts_restored", lambda name=name, known_path=known_path, snapshot=snapshot: self.remote_file_restore(name, known_path, snapshot)))
                    self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = removed
                else:
                    removed = True
                    self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = True
                known_removed = known_removed and removed
            self.report["cleanup"]["guest_known_hosts_additions_removed"] = known_removed
        else:
            for name in self.vm_names_for_run():
                self.report["cleanup"][f"{name}_known_hosts_additions_removed"] = True
            self.report["cleanup"]["guest_known_hosts_additions_removed"] = True
        self.report["cleanup"]["host_known_hosts_additions_removed"] = True
        guest_runtime_restored = self.cleanup_step("guest_runtime_restored", self.restore_guest_runtime)
        self.report["cleanup"]["guest_runtime_restored"] = bool(guest_runtime_restored)
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
        guest_auth_restored = True
        for name, snapshot in self.vm_authorized_snapshots.items():
            expected = snapshot
            if name in self.vm_authorized_lines and not self.keep_vms:
                expected = self.snapshot_without_line(snapshot, self.vm_authorized_lines[name])
            restored = self.cleanup_step(
                f"{name}_authorized_keys_restored",
                lambda name=name, expected=expected: self.remote_file_restore(
                    name, f"/home/{self.vm_user}/.ssh/authorized_keys", expected
                ),
            )
            self.report["cleanup"][f"{name}_authorized_keys_restored"] = bool(restored)
            guest_auth_restored = guest_auth_restored and bool(restored)
        self.report["cleanup"]["guest_authorized_keys_restored"] = guest_auth_restored
        stopped_vms = self.cleanup_step("vms_stopped", self.stop_owned_vms)
        self.report["cleanup"]["vms_stopped"] = bool(stopped_vms)
        if self.keep_vms:
            retention = self.cleanup_step("vms_preserved", self.verify_persisted_vms)
            self.report["cleanup"]["vms_preserved"] = bool(retention)
        else:
            retention = self.cleanup_step("vms_removed", self.remove_owned_vms)
            self.report["cleanup"]["vms_removed"] = bool(retention)
        self.report["cleanup"]["vm_retention_complete"] = bool(retention)
        complete = self.cleanup_is_complete(remote_stopped)
        self.report["cleanup"]["complete"] = complete
        self.report["cleanup"]["errors"] = list(self.cleanup_errors)

    def stop_tunnels(self) -> bool:
        stopped = True
        for process in self.tunnels:
            if process.poll() is None:
                identity = self.read_host_process_identity(process, "ssh")
                if not isinstance(identity, dict) or identity != self.tunnel_metadata.get(process.pid):
                    stopped = False
                    continue
                try:
                    os.killpg(identity["pgrp"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for process in self.tunnels:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                identity = self.read_host_process_identity(process, "ssh")
                if not isinstance(identity, dict) or identity != self.tunnel_metadata.get(process.pid):
                    stopped = False
                    continue
                try:
                    os.killpg(identity["pgrp"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        tunnel_stopped = stopped and all(process.poll() is not None for process in self.tunnels)
        if self.vm_ips and self.vm_db_port:
            tunnel_stopped = tunnel_stopped and all(self.guest_port_free(name, self.vm_db_port) for name in self.vm_names_for_run())
        return tunnel_stopped

    def remove_guest_containers(self, name: str) -> bool:
        if not self.db_query_verified:
            return False
        for attempt_id in self.attempt_ids:
            records = self.container_records(name, all_containers=True, scope_id=f"job-{attempt_id}")
            for record in records:
                if record["correlation_id"] != self.correlation_id:
                    return False
                self.guest_docker_result(name, f"rm -f -- {q(record['id'])}")
            remaining = self.container_records(name, all_containers=True, scope_id=f"job-{attempt_id}")
            if remaining:
                return False
        return True

    def remove_host_containers(self) -> bool:
        if not self.db_query_verified:
            return False
        for attempt_id in self.attempt_ids:
            records = self.container_records(all_containers=True, scope_id=f"job-{attempt_id}")
            for record in records:
                if record["correlation_id"] != self.correlation_id:
                    return False
                self.host_docker_result(["rm", "-f", record["id"]])
            remaining = self.container_records(all_containers=True, scope_id=f"job-{attempt_id}")
            if remaining:
                return False
        return True

    def stop_owned_vms(self) -> bool:
        managed = self.vm_owned_by_harness | self.vm_created_by_run
        if not managed:
            return True
        for name in managed:
            domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
            if any(line.startswith("error:") for line in domains):
                return False
            if name not in domains:
                continue
            state = self.virsh(["domstate", name], check=False)
            if state.startswith("error:"):
                return False
            snapshot = self.domain_snapshot(name, state)
            if not self.expected_domain_xml(name, snapshot["domain_xml"] or "", snapshot["volume"].get("xml") or "", self.setting("libvirt_base_path", "")):
                return False
            if state == "running":
                shutdown = self.local(["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), "shutdown", name], check=False)
                if shutdown.returncode != 0:
                    return False
            elif state != "shut off":
                destroyed = self.local(["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), "destroy", name], check=False)
                if destroyed.returncode != 0:
                    return False
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
            if any(line.startswith("error:") for line in domains):
                return False
            states = {name: self.virsh(["domstate", name], check=False) for name in managed if name in domains}
            if any(state.startswith("error:") for state in states.values()):
                return False
            if all(name not in domains or states[name] == "shut off" for name in managed):
                return True
            time.sleep(1)
        for name in managed:
            domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
            if any(line.startswith("error:") for line in domains):
                return False
            if name in domains and self.virsh(["domstate", name], check=False) != "shut off":
                state = self.virsh(["domstate", name], check=False)
                if state.startswith("error:"):
                    return False
                snapshot = self.domain_snapshot(name, state)
                if not self.expected_domain_xml(
                    name,
                    snapshot["domain_xml"] or "",
                    snapshot["volume"].get("xml") or "",
                    self.setting("libvirt_base_path", ""),
                ):
                    return False
                destroyed = self.local(["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), "destroy", name], check=False)
                if destroyed.returncode != 0:
                    return False
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        if any(line.startswith("error:") for line in domains):
            return False
        states = {name: self.virsh(["domstate", name], check=False) for name in managed if name in domains}
        return not any(state.startswith("error:") for state in states.values()) and all(name not in domains or states[name] == "shut off" for name in managed)

    def verify_persisted_vms(self) -> bool:
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        verification = {"mode": "preserved", "domains": {}, "all_valid": True}
        for name in self.vm_names_for_run():
            if name not in domains:
                verification["domains"][name] = {"valid": False, "reason": "missing domain"}
                verification["all_valid"] = False
                continue
            current = self.domain_snapshot(name, self.virsh(["domstate", name], check=False))
            initial = self.vm_initial_snapshots.get(name, {})
            initial_volume = initial.get("volume", {})
            current_volume = current.get("volume", {})
            exact_existing = (
                current.get("domain_xml") == initial.get("domain_xml") and
                current_volume.get("info") == initial_volume.get("info") and
                current_volume.get("xml") == initial_volume.get("xml") and
                current_volume.get("path") == initial_volume.get("path") and
                current_volume.get("backing_path") == initial_volume.get("backing_path") and
                current_volume.get("target_path") == initial_volume.get("target_path") and
                current_volume.get("network") == initial_volume.get("network")
            )
            valid = (current["initial_state"] == "shut off" and
                     (self.expected_domain_xml(name, current["domain_xml"] or "", current_volume.get("xml") or "", self.libvirt_base_path)
                      if name in self.vm_created_by_run else exact_existing) and
                     current_volume.get("path") == self.overlay_path(name, self.libvirt_base_path))
            verification["domains"][name] = {"valid": valid, "state": current["initial_state"]}
            verification["all_valid"] = verification["all_valid"] and valid
        self.report["evidence"]["domain_verification"] = verification
        return verification["all_valid"]

    def remove_owned_vms(self) -> bool:
        managed = self.vm_owned_by_harness | self.vm_created_by_run | self.created_volumes
        for name in managed:
            domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
            if name in domains:
                snapshot = self.domain_snapshot(name, self.virsh(["domstate", name], check=False))
                if snapshot.get("initial_state") != "shut off" or not self.expected_domain_xml(name, snapshot["domain_xml"] or "", snapshot["volume"].get("xml") or "", self.libvirt_base_path):
                    raise E2EError(f"refusing to remove domain {name}: ownership changed during the run")
                undefined = self.local(["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), "undefine", name], check=False)
                if undefined.returncode != 0:
                    raise E2EError(f"could not undefine owned domain {name}")
            volume_xml = self.virsh(["vol-dumpxml", f"{name}.qcow2", "--pool", self.setting("pool", "images")], check=False)
            if volume_xml.startswith("error:") and not self.volume_query_is_missing(volume_xml):
                raise E2EError(f"could not query owned volume {name}.qcow2")
            if volume_xml and not volume_xml.startswith("error:"):
                if not self.volume_owned(name, volume_xml, self.libvirt_base_path):
                    raise E2EError(f"refusing to remove volume {name}.qcow2: ownership changed during the run")
                deleted = self.local(["virsh", "-c", self.setting("qemu_uri", "qemu:///system"), "vol-delete", f"{name}.qcow2", "--pool", self.setting("pool", "images")], check=False)
                if deleted.returncode != 0:
                    raise E2EError(f"could not delete owned volume {name}.qcow2")
        domains = set(self.virsh(["list", "--all", "--name"]).splitlines())
        if any(line.startswith("error:") for line in domains):
            return False
        absent = all(name not in domains for name in managed)
        for name in managed:
            volume = self.virsh(
                ["vol-dumpxml", f"{name}.qcow2", "--pool", self.setting("pool", "images")],
                check=False,
            )
            if not self.volume_query_is_missing(volume):
                absent = False
        self.report["evidence"]["domain_verification"] = {
            "mode": "removed", "managed": sorted(managed), "all_absent": absent
        }
        return absent

    def remove_runtime(self) -> bool:
        if self.runtime.exists():
            try:
                self.reject_symlink(self.runtime, "run runtime")
                if self.runtime.stat().st_uid != os.getuid() or self.runtime.name != f"{self.project_slug}-vm-e2e-{self.run_id}":
                    raise E2EError("runtime ownership/name verification failed")
                shutil.rmtree(self.runtime)
            except Exception as error:
                self.cleanup_errors.append(f"runtime_removed: {error}")
                return False
        guest = True
        for name in self.vm_names_for_run():
            if name in self.vm_ips:
                safe_remove = f"if [ -e {q(self.guest_root)} ]; then test -d {q(self.guest_root)} && test ! -L {q(self.guest_root)} && test \"$(stat -c %u {q(self.guest_root)})\" = \"$(id -u)\" && rm -rf -- {q(self.guest_root)}; fi; test ! -e {q(self.guest_root)} && test ! -L {q(self.guest_root)} && printf removed"
                guest = guest and self.ssh(name, safe_remove, check=False) == "removed"
        return not self.runtime.exists() and guest

    def remove_state(self) -> bool:
        if not self.state.exists():
            return True
        self.reject_symlink(self.state, "run state")
        expected = f"{self.project_slug}-vm-e2e-{self.run_id}-state"
        if self.state.parent != Path("/tmp") or self.state.name != expected or self.state.stat().st_uid != os.getuid():
            raise E2EError("state ownership/name verification failed")
        shutil.rmtree(self.state)
        return not self.state.exists()

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
        removed = self.host_docker_result(["rm", "-f", self.db_container], timeout=60)
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
        for name in self.vm_names_for_run():
            if name in self.vm_ips:
                if not self.wait_guest_docker(name):
                    raise E2EError(f"{name} Docker daemon did not stabilize before image cleanup")
                if not self.guest_image_absent(name):
                    self.guest_docker_result(name, f"image rm -f {q(self.image)}")
                removed[name] = self.guest_image_absent(name)
        return removed

    def restore_guest_runtime(self) -> bool:
        restored = True
        for name, snapshots in self.guest_runtime_snapshots.items():
            for key, path in (("config", self.kata_config_path),
                              ("daemon", self.kata_daemon_config)):
                restored = self.remote_file_restore(
                    name, path, snapshots[key], privileged=True
                ) and restored
            restarted = self.ssh(name, "sudo -n systemctl restart docker", check=False) == ""
            healthy = restarted and self.wait_guest_docker(name)
            restored = restored and restarted and healthy
        kata_removed = True
        for name in self.guest_kata_installed:
            removed = self.ssh(
                name,
                f"sudo -n rm -rf -- {q(self.kata_install_root)} && sudo -n test ! -e {q(self.kata_install_root)}",
                check=False,
            ) == ""
            kata_removed = kata_removed and removed
        self.report["cleanup"]["guest_kata_install_removed"] = kata_removed
        restored = restored and kata_removed
        return restored

    def restore_selinux(self) -> dict:
        restored = {}
        for name, initial in self.vm_selinux_initial.items():
            if name in self.vm_selinux_disabled:
                self.ssh(name, "sudo -n setenforce 1", check=False)
            restored[name] = self.ssh(name, "getenforce", check=False) == initial
        return {"initial": self.vm_selinux_initial, "changed_to_permissive": sorted(self.vm_selinux_disabled), "restored": restored, "all_restored": all(restored.values()) if restored else True, "exercised_enforcing_mode": False}

    def verify_no_labelled_containers(self) -> bool:
        if not self.db_query_verified:
            return False
        absent = not self.container_records(all_containers=True)
        for name in self.vm_names_for_run():
            if name in self.vm_ips:
                absent = absent and not self.container_records(name, all_containers=True)
        return absent

    def handle_signal(self, signum, _frame) -> None:
        self.signal_reason = signal.Signals(signum).name
        if not self.in_cleanup:
            raise E2EError(f"received {self.signal_reason}; entering cleanup")

    def run(self) -> int:
        started = time.monotonic()
        exit_code = 1
        old_handlers = {name: signal.getsignal(getattr(signal, name)) for name in ("SIGINT", "SIGTERM", "SIGHUP", "SIGALRM")}
        for name in old_handlers:
            signal.signal(getattr(signal, name), self.handle_signal)
        signal.setitimer(signal.ITIMER_REAL, self.sla_seconds)
        try:
            self.run_phase("acquire exclusive VM E2E lock", self.acquire_lock)
            access_pub = self.run_phase("host and Kata preflight", self.preflight)
            host_ip = self.run_phase("resolve libvirt host networking", self.host_ip)
            self.run_phase("snapshot current source", self.copy_source)
            self.run_phase("render run configuration", lambda: self.render_config(host_ip))
            # The generated config is part of the source delivered to guests.
            self.source_identity = {"sha256": self.source_tree_identity(self.source)}
            self.run_phase("create VMs and wait for guest readiness", lambda: self.ensure_vms(access_pub))
            self.report["evidence"]["preflight"]["created_by_run"] = sorted(self.vm_created_by_run)
            self.run_phase("configure temporary Git access", self.generate_git_key)
            self.run_phase("configure strict SSH trust", lambda: self.setup_ssh(host_ip))
            self.run_phase("create disposable Git remote", lambda: self.create_remote(host_ip))
            self.run_phase("start PostgreSQL", self.start_db)
            self.run_phase("prepare host application", self.prepare_host)
            self.run_phase(
                "build agent image",
                lambda: self.local(["docker", "build", "-t", self.image, "-f", str(self.source / self.artifact_dockerfile), str(self.source / self.artifact_build_context)], cwd=self.source),
            )
            self.run_phase("install runtime and synchronize workers", self.sync_workers)
            self.run_phase("start database tunnels", self.start_tunnels)
            self.run_phase("run and verify distributed jobs", self.run_jobs)
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
                self.run_phase("cleanup and ownership verification", self.cleanup)
            except Exception as error:
                self.cleanup_errors.append(str(error))
                self.report["cleanup"]["complete"] = False
                self.report["cleanup"]["errors"] = self.cleanup_errors
                self.log(f"cleanup failure: {error}")
            state_removed = self.cleanup_step("state_removed", self.remove_state)
            self.report["cleanup"]["state_removed"] = bool(state_removed)
            self.report["cleanup"]["complete"] = bool(
                self.report.get("cleanup", {}).get("complete", False) and state_removed
            )
            self.report["cleanup"]["errors"] = list(self.cleanup_errors)
            if not self.report.get("cleanup", {}).get("complete", False):
                self.report["status"] = "failed_cleanup" if exit_code == 0 else self.report["status"]
                if exit_code == 0:
                    exit_code = 1
            if self.lock_file is not None:
                if self.lock_acquired:
                    fcntl.flock(self.lock_file.fileno(), fcntl.LOCK_UN)
                self.lock_file.close()
            signal.setitimer(signal.ITIMER_REAL, 0)
            self.in_cleanup = False
            elapsed = time.monotonic() - started
            within_sla = elapsed <= self.sla_seconds
            self.report["sla"] = {
                "seconds": self.sla_seconds,
                "elapsed_seconds": round(elapsed, 3),
                "within_sla": within_sla,
            }
            if not within_sla:
                self.report["status"] = "failed_sla"
                exit_code = 1
            for name, handler in old_handlers.items():
                signal.signal(getattr(signal, name), handler)
            os.umask(self.previous_umask)
        self.print_report()
        return exit_code


if __name__ == "__main__":
    arguments = parse_args(sys.argv[1:])
    try:
        harness = Harness(
            keep_vms=arguments.keep_vms,
            manifest=manifest_path(arguments.manifest),
            runtime_variant=arguments.runtime,
        )
        sys.exit(harness.run())
    except Blocker as error:
        print(json.dumps({"schema_version": 3, "status": "blocked", "error": str(error)}, sort_keys=True), flush=True)
        sys.exit(2)
