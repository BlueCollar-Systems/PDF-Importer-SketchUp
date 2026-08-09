#!/usr/bin/env python3
"""Acquire the public local-only PDF stress corpus.

The manifest is committed; downloaded PDFs are not. Every enabled download is
bound to an expected SHA-256 before publication, keeping the local test set
repeatable without redistributing third-party PDFs from this repository.
Each corpus root receives one immutable no-replace lock; use a fresh root for a
new acquisition run instead of overwriting prior evidence.
"""

from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_MANIFEST = SCRIPT_DIR / "public_pdf_corpus_manifest.json"
LOCK_NAME = "PUBLIC_PDF_CORPUS.lock.json"
USER_AGENT = "BlueCollarSystems-PDFImporter-TestCorpus/1.1"
SHA256_RE = re.compile(r"\A[0-9a-f]{64}\Z")
FILE_ATTRIBUTE_REPARSE_POINT = 0x0400
RAW_GITHUB_PIN_RE = re.compile(
    r"\Ahttps://raw\.githubusercontent\.com/[^/]+/[^/]+/"
    r"[0-9a-f]{40}/.+\Z"
)


class CorpusDownloadError(RuntimeError):
    """Closed, path-free failure from verified corpus acquisition."""


@dataclass
class _LockParentCapability:
    path: Path
    handle: int
    identity: tuple[int, ...]
    windows: bool
    closed: bool = False


@dataclass
class _LockTempCapability:
    path: Path
    handle: object
    identity: tuple[int, ...]
    parent: _LockParentCapability
    native_handle: int | None = None
    closed: bool = False


_FILE_LIST_DIRECTORY = 0x0001
_FILE_READ_ATTRIBUTES = 0x0080
_SYNCHRONIZE = 0x00100000
_GENERIC_READ = 0x80000000
_GENERIC_WRITE = 0x40000000
_DELETE = 0x00010000
_FILE_SHARE_READ = 0x00000001
_FILE_SHARE_WRITE = 0x00000002
_FILE_SHARE_DELETE = 0x00000004
_OPEN_EXISTING = 3
_CREATE_NEW = 1
_FILE_ATTRIBUTE_NORMAL = 0x0080
_FILE_ATTRIBUTE_DIRECTORY = 0x0010
_FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
_FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
_FILE_LINK_INFO_CLASS = 11
_FILE_DISPOSITION_INFO_CLASS = 4


def _stat_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        int(metadata.st_dev),
        int(metadata.st_ino),
        int(stat.S_IFMT(metadata.st_mode)),
        int(metadata.st_nlink),
        int(metadata.st_size),
    )


def _windows_kernel32():
    if os.name != "nt":
        raise CorpusDownloadError("lock_native_unavailable")
    return ctypes.WinDLL("kernel32", use_last_error=True)


def _windows_handle_identity(handle: int) -> tuple[int, ...]:
    from ctypes import wintypes

    class _BY_HANDLE_FILE_INFORMATION(ctypes.Structure):
        _fields_ = [
            ("dwFileAttributes", wintypes.DWORD),
            ("ftCreationTime", wintypes.FILETIME),
            ("ftLastAccessTime", wintypes.FILETIME),
            ("ftLastWriteTime", wintypes.FILETIME),
            ("dwVolumeSerialNumber", wintypes.DWORD),
            ("nFileSizeHigh", wintypes.DWORD),
            ("nFileSizeLow", wintypes.DWORD),
            ("nNumberOfLinks", wintypes.DWORD),
            ("nFileIndexHigh", wintypes.DWORD),
            ("nFileIndexLow", wintypes.DWORD),
        ]

    info = _BY_HANDLE_FILE_INFORMATION()
    function = _windows_kernel32().GetFileInformationByHandle
    function.argtypes = [wintypes.HANDLE, ctypes.POINTER(_BY_HANDLE_FILE_INFORMATION)]
    function.restype = wintypes.BOOL
    if not function(wintypes.HANDLE(handle), ctypes.byref(info)):
        raise ctypes.WinError(ctypes.get_last_error())
    return (
        int(info.dwVolumeSerialNumber),
        (int(info.nFileIndexHigh) << 32) | int(info.nFileIndexLow),
        int(info.dwFileAttributes),
        int(info.nNumberOfLinks),
        (int(info.nFileSizeHigh) << 32) | int(info.nFileSizeLow),
    )


def _windows_final_path(handle: int) -> Path:
    from ctypes import wintypes

    function = _windows_kernel32().GetFinalPathNameByHandleW
    function.argtypes = [wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD]
    function.restype = wintypes.DWORD
    needed = int(function(wintypes.HANDLE(handle), None, 0, 0))
    if needed <= 0:
        raise ctypes.WinError(ctypes.get_last_error())
    buffer = ctypes.create_unicode_buffer(needed + 1)
    written = int(function(wintypes.HANDLE(handle), buffer, len(buffer), 0))
    if written <= 0 or written >= len(buffer):
        raise ctypes.WinError(ctypes.get_last_error())
    value = buffer.value
    if value.startswith("\\\\?\\UNC\\"):
        value = "\\\\" + value[8:]
    elif value.startswith("\\\\?\\"):
        value = value[4:]
    return Path(value)


def _same_windows_path(left: Path, right: Path) -> bool:
    return os.path.normcase(os.path.abspath(str(left))) == os.path.normcase(
        os.path.abspath(str(right))
    )


def _close_windows_handle(handle: int) -> None:
    from ctypes import wintypes

    function = _windows_kernel32().CloseHandle
    function.argtypes = [wintypes.HANDLE]
    function.restype = wintypes.BOOL
    if not function(wintypes.HANDLE(handle)):
        raise ctypes.WinError(ctypes.get_last_error())


def _open_windows_lock_parent(path: Path) -> int:
    from ctypes import wintypes

    function = _windows_kernel32().CreateFileW
    function.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    function.restype = wintypes.HANDLE
    handle = function(
        str(path),
        _FILE_LIST_DIRECTORY | _FILE_READ_ATTRIBUTES | _SYNCHRONIZE,
        _FILE_SHARE_READ | _FILE_SHARE_WRITE,
        None,
        _OPEN_EXISTING,
        _FILE_FLAG_BACKUP_SEMANTICS | _FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    invalid = wintypes.HANDLE(-1).value
    if handle == invalid:
        raise ctypes.WinError(ctypes.get_last_error())
    return int(handle)


def _create_windows_lock_temp(path: Path) -> int:
    from ctypes import wintypes

    function = _windows_kernel32().CreateFileW
    function.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    function.restype = wintypes.HANDLE
    handle = function(
        str(path),
        _GENERIC_READ
        | _GENERIC_WRITE
        | _DELETE
        | _FILE_READ_ATTRIBUTES
        | _SYNCHRONIZE,
        _FILE_SHARE_READ,
        None,
        _CREATE_NEW,
        _FILE_ATTRIBUTE_NORMAL | _FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    invalid = wintypes.HANDLE(-1).value
    if handle == invalid:
        raise ctypes.WinError(ctypes.get_last_error())
    return int(handle)


def _duplicate_windows_handle(handle: int) -> int:
    from ctypes import wintypes

    kernel32 = _windows_kernel32()
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    current = kernel32.GetCurrentProcess()
    duplicate = wintypes.HANDLE()
    function = kernel32.DuplicateHandle
    function.argtypes = [
        wintypes.HANDLE,
        wintypes.HANDLE,
        wintypes.HANDLE,
        ctypes.POINTER(wintypes.HANDLE),
        wintypes.DWORD,
        wintypes.BOOL,
        wintypes.DWORD,
    ]
    function.restype = wintypes.BOOL
    if not function(
        current,
        wintypes.HANDLE(handle),
        current,
        ctypes.byref(duplicate),
        0,
        False,
        0x00000002,
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return int(duplicate.value)


def _windows_temp_file_object(handle: int):
    import msvcrt

    duplicate = _duplicate_windows_handle(handle)
    try:
        descriptor = msvcrt.open_osfhandle(duplicate, os.O_BINARY | os.O_RDWR)
    except Exception:
        _close_windows_handle(duplicate)
        raise
    return os.fdopen(descriptor, "w+b")


def _mark_windows_handle_for_deletion(handle: int) -> None:
    from ctypes import wintypes

    class _FILE_DISPOSITION_INFO(ctypes.Structure):
        _fields_ = [("DeleteFile", wintypes.BOOL)]

    information = _FILE_DISPOSITION_INFO(True)
    function = _windows_kernel32().SetFileInformationByHandle
    function.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    function.restype = wintypes.BOOL
    if not function(
        wintypes.HANDLE(handle),
        _FILE_DISPOSITION_INFO_CLASS,
        ctypes.byref(information),
        ctypes.sizeof(information),
    ):
        raise ctypes.WinError(ctypes.get_last_error())


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if data.get("schema") != "bcs.public_pdf_corpus/1.1":
        raise SystemExit(f"Unsupported manifest schema in {path}")
    entries = data.get("entries")
    if not isinstance(entries, list):
        raise SystemExit("Invalid manifest: entries must be an array")

    seen_ids = set()
    seen_paths = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise SystemExit("Invalid manifest: every entry must be an object")
        entry_id = entry.get("id")
        if not isinstance(entry_id, str) or not entry_id:
            raise SystemExit("Invalid manifest: entry id must be a nonempty string")
        if entry_id in seen_ids:
            raise SystemExit("Invalid manifest: duplicate entry id")
        seen_ids.add(entry_id)

        enabled = entry.get("enabled")
        if type(enabled) is not bool:
            raise SystemExit("Invalid manifest: enabled must be a boolean")
        url = entry.get("url")
        rel = entry.get("local_path")
        if not isinstance(url, str) or not isinstance(rel, str) or not rel:
            raise SystemExit("Invalid manifest: url/local_path must be strings")
        normalized_rel = rel.replace("\\", "/")
        parts = normalized_rel.split("/")
        if rel.startswith(("/", "\\")) or ":" in parts[0] or ".." in parts:
            raise SystemExit("Invalid manifest: local_path must stay relative")
        folded_rel = normalized_rel.casefold()
        if folded_rel in seen_paths:
            raise SystemExit("Invalid manifest: duplicate local_path")
        seen_paths.add(folded_rel)

        if enabled and url:
            expected = entry.get("expected_sha256")
            if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
                raise SystemExit(
                    "Invalid manifest: enabled download requires lowercase expected_sha256"
                )
            if (
                url.startswith("https://raw.githubusercontent.com/")
                and not RAW_GITHUB_PIN_RE.fullmatch(url)
            ):
                raise SystemExit(
                    "Invalid manifest: raw GitHub URL must pin a full 40-character commit"
                )
    return data


def resolve_root(manifest: dict, explicit_root: str | None) -> Path:
    candidates = (
        explicit_root,
        os.environ.get("BCS_PRIVATE_VALIDATION_ROOT"),
        os.environ.get("PDF_PRIVATE_VALIDATION_ROOT"),
        manifest.get("default_root"),
    )
    root = next(
        (
            value.strip()
            for value in candidates
            if isinstance(value, str) and value.strip()
        ),
        None,
    )
    if root is None or root == "__private_validation_assets_not_configured__":
        raise SystemExit("Corpus root is not configured; pass an explicit --root")
    return Path(root).expanduser().resolve()


def _lstat_or_none(path: Path):
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise CorpusDownloadError("lock_path_io_error") from exc


def _is_link_or_reparse(metadata: object) -> bool:
    mode = getattr(metadata, "st_mode", 0)
    attributes = getattr(metadata, "st_file_attributes", 0)
    return bool(
        stat.S_ISLNK(mode)
        or (attributes & FILE_ATTRIBUTE_REPARSE_POINT)
    )


def _contained_lock_parent(root: Path, *, create: bool) -> Path:
    """Return the fixed lock directory only when it is a real contained directory."""
    parent = root / "web-acquired"
    metadata = _lstat_or_none(parent)
    if metadata is None and create:
        try:
            os.mkdir(parent)
        except FileExistsError:
            pass
        except OSError as exc:
            raise CorpusDownloadError("lock_path_io_error") from exc
        metadata = _lstat_or_none(parent)

    if (
        metadata is None
        or _is_link_or_reparse(metadata)
        or not stat.S_ISDIR(metadata.st_mode)
    ):
        raise CorpusDownloadError("lock_path_unsafe")

    try:
        parent.resolve().relative_to(root)
    except (OSError, ValueError) as exc:
        raise CorpusDownloadError("lock_path_unsafe") from exc
    return parent


def _open_lock_parent_capability(parent: Path) -> _LockParentCapability:
    """Pin one verified real directory while omitting delete sharing."""
    try:
        metadata = os.lstat(parent)
        if _is_link_or_reparse(metadata) or not stat.S_ISDIR(metadata.st_mode):
            raise CorpusDownloadError("lock_path_unsafe")
        if os.name == "nt":
            handle = _open_windows_lock_parent(parent)
            try:
                identity = _windows_handle_identity(handle)
                attributes = identity[2]
                if (
                    not attributes & _FILE_ATTRIBUTE_DIRECTORY
                    or attributes & FILE_ATTRIBUTE_REPARSE_POINT
                    or not _same_windows_path(_windows_final_path(handle), parent)
                ):
                    raise CorpusDownloadError("lock_path_unsafe")
                path_identity = _stat_identity(metadata)
                if path_identity[1] != identity[1]:
                    raise CorpusDownloadError("lock_path_unsafe")
                return _LockParentCapability(parent, handle, identity, True)
            except Exception:
                try:
                    _close_windows_handle(handle)
                except Exception:
                    pass
                raise

        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        handle = os.open(parent, flags)
        try:
            identity = _stat_identity(os.fstat(handle))
            if identity != _stat_identity(metadata):
                raise CorpusDownloadError("lock_path_unsafe")
            return _LockParentCapability(parent, handle, identity, False)
        except Exception:
            os.close(handle)
            raise
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_path_io_error") from exc


def _validate_lock_parent_capability(capability: _LockParentCapability) -> None:
    if not isinstance(capability, _LockParentCapability) or capability.closed:
        raise CorpusDownloadError("lock_path_unsafe")
    try:
        metadata = os.lstat(capability.path)
        if _is_link_or_reparse(metadata) or not stat.S_ISDIR(metadata.st_mode):
            raise CorpusDownloadError("lock_path_unsafe")
        if capability.windows:
            if (
                _windows_handle_identity(capability.handle) != capability.identity
                or not _same_windows_path(
                    _windows_final_path(capability.handle), capability.path
                )
                or _stat_identity(metadata)[1] != capability.identity[1]
            ):
                raise CorpusDownloadError("lock_path_unsafe")
        elif (
            _stat_identity(os.fstat(capability.handle))[:3] != capability.identity[:3]
            or _stat_identity(metadata)[:3] != capability.identity[:3]
        ):
            raise CorpusDownloadError("lock_path_unsafe")
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_path_io_error") from exc


def _close_lock_parent_capability(capability: _LockParentCapability) -> None:
    if capability.closed:
        return
    try:
        if capability.windows:
            _close_windows_handle(capability.handle)
        else:
            os.close(capability.handle)
    finally:
        capability.closed = True


def _create_lock_temp_capability(
    parent: _LockParentCapability,
) -> _LockTempCapability:
    _validate_lock_parent_capability(parent)
    try:
        if parent.windows:
            native_handle = None
            for _attempt in range(32):
                path = parent.path / (
                    f".{LOCK_NAME}.{uuid.uuid4().hex}.part"
                )
                try:
                    native_handle = _create_windows_lock_temp(path)
                    break
                except FileExistsError:
                    continue
            if native_handle is None:
                raise CorpusDownloadError("lock_publish_conflict")
            try:
                identity = _windows_handle_identity(native_handle)
                attributes = identity[2]
                if (
                    attributes & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                    or identity[3] != 1
                    or not _same_windows_path(_windows_final_path(native_handle), path)
                ):
                    raise CorpusDownloadError("lock_path_unsafe")
                handle = _windows_temp_file_object(native_handle)
                if int(os.fstat(handle.fileno()).st_ino) != identity[1]:
                    raise CorpusDownloadError("lock_path_unsafe")
                _validate_lock_parent_capability(parent)
                return _LockTempCapability(
                    path, handle, identity, parent, native_handle=native_handle
                )
            except Exception:
                try:
                    _mark_windows_handle_for_deletion(native_handle)
                except Exception:
                    pass
                try:
                    _close_windows_handle(native_handle)
                except Exception:
                    pass
                raise

        handle = tempfile.NamedTemporaryFile(
            mode="w+b",
            dir=str(parent.path),
            prefix=f".{LOCK_NAME}.",
            suffix=".part",
            delete=True,
        )
        path = Path(handle.name)
        identity = _stat_identity(os.fstat(handle.fileno()))
        if identity[2] != stat.S_IFREG or identity[3] != 1:
            handle.close()
            raise CorpusDownloadError("lock_path_unsafe")
        _validate_lock_parent_capability(parent)
        return _LockTempCapability(path, handle, identity, parent)
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_publish_io_error") from exc


def _write_lock_temp_capability(temp: _LockTempCapability, payload: bytes) -> None:
    try:
        if temp.closed:
            raise CorpusDownloadError("lock_path_unsafe")
        if temp.parent.windows:
            if (
                temp.native_handle is None
                or _windows_handle_identity(temp.native_handle) != temp.identity
                or int(os.fstat(temp.handle.fileno()).st_ino) != temp.identity[1]
            ):
                raise CorpusDownloadError("lock_path_unsafe")
        elif _stat_identity(os.fstat(temp.handle.fileno())) != temp.identity:
            raise CorpusDownloadError("lock_path_unsafe")
        temp.handle.seek(0)
        temp.handle.write(payload)
        temp.handle.flush()
        os.fsync(temp.handle.fileno())
        temp.handle.seek(0)
        if temp.handle.read() != payload:
            raise CorpusDownloadError("lock_published_bytes_invalid")
        temp.handle.seek(0)
        if temp.parent.windows:
            assert temp.native_handle is not None
            current = _windows_handle_identity(temp.native_handle)
            if current[:4] != temp.identity[:4] or current[4] != len(payload):
                raise CorpusDownloadError("lock_path_unsafe")
        else:
            current = _stat_identity(os.fstat(temp.handle.fileno()))
            if current[:4] != temp.identity[:4] or current[4] != len(payload):
                raise CorpusDownloadError("lock_path_unsafe")
        temp.identity = current
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_publish_io_error") from exc


def _read_lock_temp_capability(temp: _LockTempCapability) -> bytes:
    try:
        if temp.closed:
            raise CorpusDownloadError("lock_path_unsafe")
        current = temp.handle.tell()
        temp.handle.seek(0)
        payload = temp.handle.read()
        temp.handle.seek(current)
        return payload
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_publish_io_error") from exc


def _windows_file_handle_from_temp(temp: _LockTempCapability) -> int:
    if temp.native_handle is None:
        raise CorpusDownloadError("lock_native_unavailable")
    return temp.native_handle


def _publish_lock_temp_no_replace(
    temp: _LockTempCapability,
    parent: _LockParentCapability,
    destination: Path,
) -> None:
    """Create the final hard link from the retained source handle, never replacing."""
    _validate_lock_parent_capability(parent)
    if destination != parent.path / LOCK_NAME or temp.parent is not parent:
        raise CorpusDownloadError("lock_path_unsafe")
    try:
        if parent.windows:
            from ctypes import wintypes

            target_name = destination.name

            class _FILE_LINK_INFO(ctypes.Structure):
                _fields_ = [
                    ("ReplaceIfExists", wintypes.BOOLEAN),
                    ("RootDirectory", wintypes.HANDLE),
                    ("FileNameLength", wintypes.DWORD),
                    ("FileName", wintypes.WCHAR * (len(target_name) + 1)),
                ]

            information = _FILE_LINK_INFO()
            information.ReplaceIfExists = False
            information.RootDirectory = wintypes.HANDLE(parent.handle)
            information.FileNameLength = len(target_name.encode("utf-16-le"))
            information.FileName = target_name

            class _IO_STATUS_BLOCK(ctypes.Structure):
                _fields_ = [
                    ("Status", ctypes.c_void_p),
                    ("Information", ctypes.c_size_t),
                ]

            io_status = _IO_STATUS_BLOCK()
            ntdll = ctypes.WinDLL("ntdll", use_last_error=True)
            function = ntdll.NtSetInformationFile
            function.argtypes = [
                wintypes.HANDLE,
                ctypes.POINTER(_IO_STATUS_BLOCK),
                wintypes.LPVOID,
                wintypes.DWORD,
                ctypes.c_int,
            ]
            function.restype = ctypes.c_long
            status = int(function(
                wintypes.HANDLE(_windows_file_handle_from_temp(temp)),
                ctypes.byref(io_status),
                ctypes.byref(information),
                ctypes.sizeof(information),
                _FILE_LINK_INFO_CLASS,
            ))
            if status < 0:
                converter = ntdll.RtlNtStatusToDosError
                converter.argtypes = [ctypes.c_long]
                converter.restype = wintypes.ULONG
                error = int(converter(status))
                if error in (80, 183):
                    raise FileExistsError(error, "lock_publish_conflict")
                raise ctypes.WinError(error)
            return

        os.link(
            temp.path.name,
            destination.name,
            src_dir_fd=parent.handle,
            dst_dir_fd=parent.handle,
            follow_symlinks=False,
        )
    except FileExistsError:
        raise
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_publish_io_error") from exc


def _dispose_lock_temp_capability(temp: _LockTempCapability) -> None:
    """Delete only the current run's already-open temp through its file handle."""
    if temp.closed:
        return
    try:
        if temp.parent.windows:
            if temp.native_handle is None:
                raise CorpusDownloadError("lock_cleanup_io_error")
            temp.handle.close()
            _mark_windows_handle_for_deletion(temp.native_handle)
            _close_windows_handle(temp.native_handle)
            temp.native_handle = None
        else:
            temp.handle.close()
        temp.closed = True
        if temp.path.exists():
            raise CorpusDownloadError("lock_cleanup_io_error")
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_cleanup_io_error") from exc


def _force_close_lock_temp_capability(temp: _LockTempCapability) -> None:
    if temp.closed:
        return
    try:
        temp.handle.close()
    except Exception:
        pass
    if temp.native_handle is not None:
        try:
            _close_windows_handle(temp.native_handle)
        except Exception:
            pass
        temp.native_handle = None
    temp.closed = True


def _open_windows_lock_file(path: Path, *, share_all: bool = False) -> int:
    from ctypes import wintypes

    function = _windows_kernel32().CreateFileW
    function.argtypes = [
        wintypes.LPCWSTR,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.HANDLE,
    ]
    function.restype = wintypes.HANDLE
    handle = function(
        str(path),
        _GENERIC_READ | _FILE_READ_ATTRIBUTES | _SYNCHRONIZE,
        (
            _FILE_SHARE_READ | _FILE_SHARE_WRITE | _FILE_SHARE_DELETE
            if share_all
            else _FILE_SHARE_READ
        ),
        None,
        _OPEN_EXISTING,
        _FILE_FLAG_OPEN_REPARSE_POINT,
        None,
    )
    invalid = wintypes.HANDLE(-1).value
    if handle == invalid:
        error = ctypes.get_last_error()
        if error in (2, 3):
            raise FileNotFoundError(error, "lock_missing")
        raise ctypes.WinError(error)
    return int(handle)


def _read_existing_lock_bytes(
    parent: _LockParentCapability,
    destination: Path,
    *,
    expected_identity: tuple[int, ...] | None = None,
) -> bytes | None:
    _validate_lock_parent_capability(parent)
    try:
        metadata = _lstat_or_none(destination)
        if metadata is None:
            return None
        if _is_link_or_reparse(metadata) or not stat.S_ISREG(metadata.st_mode):
            raise CorpusDownloadError("lock_path_unsafe")
        if parent.windows:
            handle = _open_windows_lock_file(
                destination, share_all=expected_identity is not None
            )
            try:
                identity = _windows_handle_identity(handle)
                attributes = identity[2]
                if (
                    attributes & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                    or identity[3] != (2 if expected_identity is not None else 1)
                    or not _same_windows_path(_windows_final_path(handle), destination)
                    or (
                        expected_identity is not None
                        and identity[:2] != expected_identity[:2]
                    )
                ):
                    raise CorpusDownloadError("lock_path_unsafe")
                with destination.open("rb") as reader:
                    if int(os.fstat(reader.fileno()).st_ino) != identity[1]:
                        raise CorpusDownloadError("lock_path_unsafe")
                    return reader.read()
            finally:
                _close_windows_handle(handle)

        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        handle = os.open(destination.name, flags, dir_fd=parent.handle)
        try:
            opened = os.fstat(handle)
            if not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1:
                raise CorpusDownloadError("lock_path_unsafe")
            with os.fdopen(os.dup(handle), "rb") as reader:
                return reader.read()
        finally:
            os.close(handle)
    except FileNotFoundError:
        return None
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("lock_publish_io_error") from exc


def prepare_lock_destination(root: Path) -> Path:
    """Preflight the one derived lock destination before any corpus publication."""
    parent = _contained_lock_parent(root, create=True)
    lock_path = parent / LOCK_NAME
    metadata = _lstat_or_none(lock_path)
    if metadata is not None:
        if _is_link_or_reparse(metadata) or not stat.S_ISREG(metadata.st_mode):
            raise CorpusDownloadError("lock_path_unsafe")
        raise CorpusDownloadError("lock_publish_conflict")
    return lock_path


def publish_lock_bytes(root: Path, lock_path: Path, payload: bytes) -> None:
    """Publish complete derived metadata atomically without replacing any object."""
    if not isinstance(payload, bytes):
        raise CorpusDownloadError("lock_payload_invalid")
    parent_capability: _LockParentCapability | None = None
    temp_capability: _LockTempCapability | None = None
    primary_error: CorpusDownloadError | None = None
    cleanup_error: CorpusDownloadError | None = None
    published = False
    try:
        parent = _contained_lock_parent(root, create=False)
        if lock_path != parent / LOCK_NAME:
            raise CorpusDownloadError("lock_path_unsafe")
        parent_capability = _open_lock_parent_capability(parent)
        existing = _read_existing_lock_bytes(parent_capability, lock_path)
        if existing is not None:
            if existing != payload:
                raise CorpusDownloadError("lock_publish_conflict")
            published = True
        else:
            temp_capability = _create_lock_temp_capability(parent_capability)
            _write_lock_temp_capability(temp_capability, payload)

            # This second check is defense in depth. The retained directory handle
            # is the authority that prevents its name from being replaced here.
            if _contained_lock_parent(root, create=False) != parent:
                raise CorpusDownloadError("lock_path_unsafe")
            _validate_lock_parent_capability(parent_capability)

            existing = _read_existing_lock_bytes(parent_capability, lock_path)
            if existing is not None:
                if existing != payload:
                    raise CorpusDownloadError("lock_publish_conflict")
                published = True
            else:
                linked_current_temp = False
                try:
                    _publish_lock_temp_no_replace(
                        temp_capability, parent_capability, lock_path
                    )
                    linked_current_temp = True
                except FileExistsError:
                    winner = _read_existing_lock_bytes(parent_capability, lock_path)
                    if winner != payload:
                        raise CorpusDownloadError("lock_publish_conflict") from None
                winner = _read_existing_lock_bytes(
                    parent_capability,
                    lock_path,
                    expected_identity=(
                        temp_capability.identity if linked_current_temp else None
                    ),
                )
                if winner != payload:
                    raise CorpusDownloadError("lock_published_bytes_invalid")
                published = True
    except CorpusDownloadError as exc:
        primary_error = exc
    except OSError as exc:
        primary_error = CorpusDownloadError("lock_publish_io_error")
        primary_error.__cause__ = exc
    finally:
        if temp_capability is not None:
            try:
                _dispose_lock_temp_capability(temp_capability)
            except Exception as exc:
                cleanup_error = CorpusDownloadError("lock_cleanup_io_error")
                cleanup_error.__cause__ = exc
            finally:
                _force_close_lock_temp_capability(temp_capability)
        if parent_capability is not None:
            if published and cleanup_error is None:
                try:
                    if _read_existing_lock_bytes(parent_capability, lock_path) != payload:
                        raise CorpusDownloadError("lock_published_bytes_invalid")
                except CorpusDownloadError as exc:
                    primary_error = exc
            try:
                _close_lock_parent_capability(parent_capability)
            except Exception as exc:
                if cleanup_error is None:
                    cleanup_error = CorpusDownloadError("lock_cleanup_io_error")
                    cleanup_error.__cause__ = exc

    if cleanup_error is not None:
        raise cleanup_error from cleanup_error.__cause__
    if primary_error is not None:
        raise primary_error from primary_error.__cause__
    if not published:
        raise CorpusDownloadError("lock_publish_io_error")


def download_verified(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Acquire one expected byte sequence and publish it without replacement."""
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        raise CorpusDownloadError("invalid_expected_sha256")

    if target.exists():
        if target.is_file() and sha256_file(target) == expected_sha256:
            return expected_sha256
        raise CorpusDownloadError("existing_digest_mismatch")

    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = None
    digest = hashlib.sha256()
    try:
        with tempfile.NamedTemporaryFile(
            mode="xb",
            dir=str(target.parent),
            prefix=f".{target.name}.",
            suffix=".part",
            delete=False,
        ) as handle:
            tmp_path = Path(handle.name)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    handle.write(chunk)
                    digest.update(chunk)
            handle.flush()
            os.fsync(handle.fileno())

        actual = digest.hexdigest()
        if actual != expected_sha256:
            raise CorpusDownloadError("download_digest_mismatch")

        try:
            os.link(tmp_path, target)
        except FileExistsError:
            if target.is_file() and sha256_file(target) == expected_sha256:
                return expected_sha256
            raise CorpusDownloadError("publish_conflict")
        except OSError as exc:
            raise CorpusDownloadError("publish_io_error") from exc

        if sha256_file(target) != expected_sha256:
            raise CorpusDownloadError("published_digest_mismatch")
        return expected_sha256
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass
            except OSError:
                # The verified target, if any, is never removed by cleanup.
                pass


def download(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Verified public entry point; the expected hash is mandatory."""
    return download_verified(url, target, timeout, expected_sha256)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST))
    parser.add_argument(
        "--root",
        help=(
            "Corpus root. Required unless BCS_PRIVATE_VALIDATION_ROOT, "
            "PDF_PRIVATE_VALIDATION_ROOT, or a real manifest default is configured."
        ),
    )
    parser.add_argument("--id", action="append", dest="ids", help="Download only the named manifest id. Repeatable.")
    parser.add_argument("--include-disabled", action="store_true", help="Attempt entries marked enabled=false when they have a URL.")
    parser.add_argument("--timeout", type=int, default=120, help="Per-file HTTP timeout in seconds.")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest).resolve()
    manifest = load_manifest(manifest_path)
    root = resolve_root(manifest, args.root)
    root.mkdir(parents=True, exist_ok=True)
    try:
        lock_path = prepare_lock_destination(root)
    except CorpusDownloadError as exc:
        print(f"FAIL corpus-lock: {exc}", file=sys.stderr)
        return 1

    selected_ids = set(args.ids or [])
    entries = []
    for entry in manifest.get("entries", []):
        entry_id = entry.get("id", "")
        if selected_ids and entry_id not in selected_ids:
            continue
        if not entry.get("enabled", False) and not args.include_disabled:
            continue
        entries.append(entry)

    if selected_ids:
        found = {entry.get("id") for entry in entries}
        missing = sorted(selected_ids - found)
        if missing:
            print(f"Warning: no enabled manifest entries matched: {', '.join(missing)}", file=sys.stderr)

    lock_entries = []
    failures = []

    print(f"Manifest: {manifest_path}")
    print(f"Corpus root: {root}")
    print(f"Entries: {len(entries)}")

    for entry in entries:
        entry_id = entry.get("id", "")
        url = entry.get("url", "")
        rel = entry.get("local_path", "")
        expected = entry.get("expected_sha256", "")
        if not url or not rel or rel.endswith("/"):
            print(f"SKIP {entry_id}: no direct download URL")
            lock_entries.append({"id": entry_id, "status": "skipped", "reason": "no_direct_url"})
            continue

        target = (root / rel).resolve()
        try:
            target.relative_to(root)
        except ValueError:
            failures.append((entry_id, "target_outside_root"))
            print(f"FAIL {entry_id}: target_outside_root", file=sys.stderr)
            lock_entries.append(
                {"id": entry_id, "status": "failed", "reason": "target_outside_root"}
            )
            continue
        try:
            if target.exists():
                digest = download_verified(url, target, args.timeout, expected)
                print(f"OK   {entry_id}: exists {target} sha256={digest[:12]}")
            else:
                print(f"GET  {entry_id}: {url}")
                start = time.time()
                digest = download_verified(url, target, args.timeout, expected)
                elapsed = time.time() - start
                print(f"OK   {entry_id}: {target.stat().st_size} bytes in {elapsed:.1f}s sha256={digest[:12]}")

            lock_entries.append(
                {
                    "id": entry_id,
                    "title": entry.get("title", ""),
                    "source_org": entry.get("source_org", ""),
                    "source_page": entry.get("source_page", ""),
                    "url": url,
                    "local_path": str(target),
                    "size_bytes": target.stat().st_size,
                    "expected_sha256": expected,
                    "sha256": digest,
                    "features": entry.get("features", []),
                    "test_intent": entry.get("test_intent", ""),
                    "license_note": entry.get("license_note", ""),
                    "status": "ok",
                }
            )
        except (
            CorpusDownloadError,
            OSError,
            urllib.error.URLError,
            urllib.error.HTTPError,
            TimeoutError,
        ) as exc:
            failures.append((entry_id, str(exc)))
            print(f"FAIL {entry_id}: {exc}", file=sys.stderr)
            lock_entries.append({"id": entry_id, "status": "failed", "reason": str(exc)})

    lock = {
        "schema": "bcs.public_pdf_corpus.lock/1.1",
        "producer": "bcs.public_pdf_corpus_downloader/1.1",
        "manifest": str(manifest_path),
        "root": str(root),
        "entries": lock_entries,
    }
    lock_bytes = (json.dumps(lock, indent=2, sort_keys=True) + "\n").encode("utf-8")
    try:
        publish_lock_bytes(root, lock_path, lock_bytes)
        print(f"Lock file: {lock_path}")
    except CorpusDownloadError as exc:
        failures.append(("corpus-lock", str(exc)))
        print(f"FAIL corpus-lock: {exc}", file=sys.stderr)

    if failures:
        print("Failures:", file=sys.stderr)
        for entry_id, reason in failures:
            print(f"  {entry_id}: {reason}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
