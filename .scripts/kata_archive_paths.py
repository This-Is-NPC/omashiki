#!/usr/bin/env python3
"""Validate paths listed from the pinned Kata release archive."""

from __future__ import annotations

from pathlib import PurePosixPath
import sys
from typing import Iterable


class ArchivePathError(ValueError):
    pass


def validate(entries: Iterable[str]) -> None:
    contains_kata = False

    for raw_entry in entries:
        entry = raw_entry.rstrip("\n")
        path = PurePosixPath(entry)
        if path.is_absolute() or ".." in path.parts:
            raise ArchivePathError(f"unsafe path in Kata archive: {entry}")
        if path.parts[:2] == ("opt", "kata"):
            contains_kata = True

    if not contains_kata:
        raise ArchivePathError("Kata archive does not contain opt/kata")


def main() -> int:
    try:
        validate(sys.stdin)
    except ArchivePathError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
