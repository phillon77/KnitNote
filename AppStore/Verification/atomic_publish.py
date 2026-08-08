#!/usr/bin/env python3
"""Atomically publish a release candidate only when its destination is absent."""

from __future__ import annotations

import ctypes
import errno
import os
import sys
from pathlib import Path


AT_FDCWD = -2
RENAME_EXCL = 0x00000004


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: atomic_publish.py STAGED_ARTIFACTS FINAL_DESTINATION")
    source = Path(sys.argv[1])
    destination = Path(sys.argv[2])
    if not source.is_dir() or source.is_symlink():
        raise SystemExit("staged release artifacts are missing or unsafe")
    if os.stat(source.parent).st_dev != os.stat(destination.parent).st_dev:
        raise SystemExit("release publication must stay on one filesystem")
    renameatx_np = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True).renameatx_np
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int
    result = renameatx_np(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        RENAME_EXCL,
    )
    if result == 0:
        return 0
    failure = ctypes.get_errno()
    if failure == errno.EEXIST:
        raise SystemExit("candidate destination appeared during exclusive publication")
    raise SystemExit(os.strerror(failure))


if __name__ == "__main__":
    raise SystemExit(main())
