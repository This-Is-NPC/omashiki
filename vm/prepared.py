"""Metadata and verification helpers for prepared libvirt base images."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import xml.etree.ElementTree as ET


_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_FINGERPRINT_RE = _SHA256_RE
_FINGERPRINT_FILES = (
    "vm/prepare.py",
    "vm/prepared.py",
    "vm/e2e.py",
    "server/mix.exs",
    "server/mix.lock",
)
_POINTER_KEYS = frozenset({
    "fingerprint", "source_sha256", "host_path", "volume", "libvirt_path",
    "sha256", "size", "virtual_size",
})


class PreparedBaseError(RuntimeError):
    """Raised when prepared-base metadata or its backing files are unsafe."""


def sha256_file(path: str | os.PathLike[str]) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_root(manifest_path: str | os.PathLike[str]) -> Path:
    return Path(manifest_path).resolve().parent.parent


def _base_sha(manifest: dict) -> bytes:
    try:
        value = manifest["base"]["sha256"]
    except (KeyError, TypeError) as error:
        raise PreparedBaseError("manifest base.sha256 is required") from error
    if not isinstance(value, str) or not _SHA256_RE.fullmatch(value):
        raise PreparedBaseError("manifest base.sha256 must be 64 lowercase hexadecimal characters")
    return bytes.fromhex(value)


def preparation_fingerprint(manifest: dict, manifest_path: str | os.PathLike[str]) -> str:
    """Return a content-addressed identity for the preparation inputs."""
    base_sha = _base_sha(manifest)
    manifest_file = Path(manifest_path)
    root = _manifest_root(manifest_file)
    digest = hashlib.sha256()

    # Length framing keeps the identity unambiguous while preserving file order.
    for label, data in [("manifest", manifest_file.read_bytes()), ("base.sha256", base_sha)]:
        encoded_label = label.encode("ascii")
        digest.update(len(encoded_label).to_bytes(4, "big"))
        digest.update(encoded_label)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)

    try:
        cloud_init = manifest["prepared"]["cloud_init"]
    except (KeyError, TypeError) as error:
        raise PreparedBaseError("manifest prepared.cloud_init is required") from error
    if not isinstance(cloud_init, str) or not cloud_init:
        raise PreparedBaseError("manifest prepared.cloud_init is invalid")

    for relative in (*_FINGERPRINT_FILES, cloud_init):
        path = root / relative
        if path.is_symlink() or not path.is_file():
            raise PreparedBaseError(f"fingerprint input is not a regular file: {path}")
        data = path.read_bytes()
        encoded_label = relative.encode("ascii")
        digest.update(len(encoded_label).to_bytes(4, "big"))
        digest.update(encoded_label)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def _configured_path(value: object, label: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise PreparedBaseError(f"manifest {label} must be a non-empty path")
    return Path(value).expanduser()


def prepared_paths(manifest: dict, fingerprint: str) -> tuple[Path, str]:
    """Return the prepared host image path and its libvirt volume name."""
    if not isinstance(fingerprint, str) or not _FINGERPRINT_RE.fullmatch(fingerprint):
        raise PreparedBaseError("prepared fingerprint is invalid")
    try:
        prepared = manifest["prepared"]
        directory = _configured_path(prepared["directory"], "prepared.directory")
        prefix = prepared["volume_prefix"]
    except (KeyError, TypeError) as error:
        raise PreparedBaseError("manifest prepared.directory and prepared.volume_prefix are required") from error
    if not isinstance(prefix, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,126}", prefix):
        raise PreparedBaseError("manifest prepared.volume_prefix is invalid")
    return directory / f"{fingerprint}.qcow2", f"{prefix}-{fingerprint[:16]}.qcow2"


def atomic_write_json(path: str | os.PathLike[str], payload: object) -> None:
    """Write JSON durably, replacing the destination without exposing a partial file."""
    destination = Path(path)
    parent = destination.parent
    fd, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=str(parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="ascii", newline="\n") as output:
            fd = -1
            json.dump(payload, output, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination)
        directory_fd = os.open(parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd != -1:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _regular_file(path: Path, label: str, *, require_owner: bool = True) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PreparedBaseError(f"{label} is unavailable: {path}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise PreparedBaseError(f"{label} is not a regular file: {path}")
    if require_owner and metadata.st_uid != os.getuid():
        raise PreparedBaseError(f"{label} has an unsafe owner: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise PreparedBaseError(f"{label} has unsafe write permissions: {path}")
    return metadata


def _command_json(command: list[str], label: str) -> dict:
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        raise PreparedBaseError(f"{label} could not be executed") from error
    if result.returncode != 0:
        raise PreparedBaseError(f"{label} failed")
    try:
        value = json.loads(result.stdout)
    except (TypeError, json.JSONDecodeError) as error:
        raise PreparedBaseError(f"{label} returned invalid JSON") from error
    if not isinstance(value, dict):
        raise PreparedBaseError(f"{label} returned a non-object JSON value")
    return value


def _command_text(command: list[str], label: str) -> str:
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True)
    except OSError as error:
        raise PreparedBaseError(f"{label} could not be executed") from error
    if result.returncode != 0:
        raise PreparedBaseError(f"{label} failed")
    value = result.stdout.strip()
    if not value:
        raise PreparedBaseError(f"{label} returned an empty result")
    return value


def _integer(value: object, label: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or (positive and value <= 0) or (not positive and value < 0):
        raise PreparedBaseError(f"pointer {label} is invalid")
    return value


def _no_backing(info: dict, label: str) -> None:
    for key in ("backing-filename", "full-backing-filename", "backing-filename-format"):
        if info.get(key):
            raise PreparedBaseError(f"{label} has a backing file")


def _qcow2_info(info: dict, label: str, virtual_size: int) -> None:
    reported_size = info.get("virtual-size")
    if (
        info.get("format") != "qcow2"
        or isinstance(reported_size, bool)
        or not isinstance(reported_size, int)
        or reported_size <= 0
        or reported_size != virtual_size
    ):
        raise PreparedBaseError(f"{label} metadata differs")
    _no_backing(info, label)


def verify_prepared_base(
    manifest: dict,
    manifest_path: str | os.PathLike[str],
    qemu_uri: str = "qemu:///system",
) -> dict:
    """Verify and return the trusted prepared-base pointer."""
    try:
        if not isinstance(manifest, dict) or not isinstance(qemu_uri, str) or not qemu_uri:
            raise PreparedBaseError("manifest or qemu URI is invalid")
        base = manifest["base"]
        prepared = manifest["prepared"]
        if not isinstance(base, dict) or not isinstance(prepared, dict):
            raise PreparedBaseError("manifest base and prepared sections are required")
        pool = base["pool"]
        if not isinstance(pool, str) or not pool:
            raise PreparedBaseError("manifest base.pool is required")
        expected_sha = _base_sha(manifest).hex()
        fingerprint = preparation_fingerprint(manifest, manifest_path)
        host_path, volume = prepared_paths(manifest, fingerprint)
        pointer_path = _configured_path(prepared["pointer"], "prepared.pointer")

        pointer_metadata = _regular_file(pointer_path, "prepared pointer")
        if stat.S_IMODE(pointer_metadata.st_mode) != 0o600:
            raise PreparedBaseError("prepared pointer must have mode 0600")
        try:
            pointer = json.loads(pointer_path.read_text(encoding="ascii"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise PreparedBaseError("prepared pointer is invalid JSON") from error
        if not isinstance(pointer, dict) or set(pointer) != _POINTER_KEYS:
            raise PreparedBaseError("prepared pointer schema is invalid")
        if pointer["fingerprint"] != fingerprint:
            raise PreparedBaseError("prepared pointer fingerprint differs")
        if pointer["host_path"] != str(host_path) or pointer["volume"] != volume:
            raise PreparedBaseError("prepared pointer paths differ from the manifest")
        if not isinstance(pointer["libvirt_path"], str) or not pointer["libvirt_path"]:
            raise PreparedBaseError("prepared pointer libvirt path is invalid")
        if not isinstance(pointer["sha256"], str) or not _SHA256_RE.fullmatch(pointer["sha256"]):
            raise PreparedBaseError("prepared pointer SHA-256 is invalid")
        if pointer["source_sha256"] != expected_sha:
            raise PreparedBaseError("prepared pointer source SHA-256 differs")
        size = _integer(pointer["size"], "size", positive=True)
        virtual_size = _integer(pointer["virtual_size"], "virtual_size", positive=True)

        host_metadata = _regular_file(host_path, "prepared host image")
        if host_metadata.st_size != size:
            raise PreparedBaseError("prepared host image size differs")
        if sha256_file(host_path) != pointer["sha256"]:
            raise PreparedBaseError("prepared host image bytes differ")
        host_info = _command_json(["qemu-img", "info", "--output=json", str(host_path)], "host qemu-img info")
        _qcow2_info(host_info, "prepared host image", virtual_size)

        libvirt_path = Path(pointer["libvirt_path"])
        _regular_file(libvirt_path, "libvirt prepared volume", require_owner=False)
        actual_volume_path = _command_text(
            ["virsh", "-c", qemu_uri, "vol-path", volume, "--pool", pool],
            "virsh vol-path",
        )
        if actual_volume_path != pointer["libvirt_path"]:
            raise PreparedBaseError("libvirt volume path differs")
        volume_xml = _command_text(
            ["virsh", "-c", qemu_uri, "vol-dumpxml", volume, "--pool", pool],
            "virsh vol-dumpxml",
        )
        try:
            volume_root = ET.fromstring(volume_xml)
        except ET.ParseError as error:
            raise PreparedBaseError("libvirt volume XML is invalid") from error
        if volume_root.tag.rsplit("}", 1)[-1] != "volume":
            raise PreparedBaseError("libvirt volume XML has the wrong root")
        target_path = volume_root.find("./target/path")
        target_format = volume_root.find("./target/format")
        if (
            volume_root.findtext("./name") != volume
            or target_path is None
            or target_path.text != pointer["libvirt_path"]
            or target_format is None
            or target_format.attrib != {"type": "qcow2"}
            or volume_root.find(".//backingStore") is not None
        ):
            raise PreparedBaseError("libvirt volume metadata differs")

        libvirt_info = _command_json(
            ["qemu-img", "info", "--output=json", pointer["libvirt_path"]],
            "libvirt qemu-img info",
        )
        _qcow2_info(libvirt_info, "libvirt prepared volume", virtual_size)
        libvirt_metadata = libvirt_path.stat()
        if libvirt_metadata.st_size != size or sha256_file(libvirt_path) != pointer["sha256"]:
            raise PreparedBaseError("libvirt volume bytes differ from the host image")
        return pointer
    except PreparedBaseError:
        raise
    except (KeyError, OSError, TypeError, ValueError) as error:
        raise PreparedBaseError("prepared base verification failed") from error
