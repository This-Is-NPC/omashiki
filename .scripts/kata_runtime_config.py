#!/usr/bin/env python3
"""Validate the Cloud Hypervisor settings in a Kata runtime-rs config."""

from __future__ import annotations

from pathlib import Path
import sys
import tomllib


class RuntimeConfigError(ValueError):
    pass


def validate(path: Path, expected_hypervisor: str) -> None:
    if path.is_symlink():
        raise RuntimeConfigError(f"refusing symlinked Kata config: {path}")
    try:
        with path.open("rb") as source:
            config = tomllib.load(source)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise RuntimeConfigError(f"invalid Kata runtime-rs config: {error}") from error

    hypervisor = config.get("hypervisor", {}).get("clh")
    runtime = config.get("runtime")
    if (
        not isinstance(hypervisor, dict)
        or hypervisor.get("path") != expected_hypervisor
        or not isinstance(runtime, dict)
        or runtime.get("hypervisor_name") != "clh"
    ):
        raise RuntimeConfigError(
            "Kata runtime-rs config is not configured for Cloud Hypervisor"
        )


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(f"usage: {argv[0]} CONFIG EXPECTED_HYPERVISOR", file=sys.stderr)
        return 2
    try:
        validate(Path(argv[1]), argv[2])
    except RuntimeConfigError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
