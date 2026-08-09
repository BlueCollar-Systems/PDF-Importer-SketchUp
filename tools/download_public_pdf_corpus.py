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
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import urllib.error
import urllib.parse
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
class _ParentCapability:
    path: Path
    handle: int
    identity: tuple[int, ...]
    windows: bool
    closed: bool = False


@dataclass
class _TempCapability:
    path: Path | None
    handle: object
    identity: tuple[int, ...]
    parent: _ParentCapability
    native_handle: int | None = None
    closed: bool = False


# Compatibility names retained for the focused lock-publication contract.  The
# same verified capabilities now also protect downloaded corpus entries.
_LockParentCapability = _ParentCapability
_LockTempCapability = _TempCapability


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
_FILE_CREATE = 2
_FILE_OPEN = 1
_FILE_NON_DIRECTORY_FILE = 0x00000040
_FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020
_FILE_OPEN_REPARSE_POINT = 0x00200000
_OBJ_CASE_INSENSITIVE = 0x00000040
_AT_EMPTY_PATH = 0x1000
_WINDOWS_FORBIDDEN_PATH_CHARACTERS = frozenset('<>:"|?*')
_WINDOWS_DEVICE_NAMES = frozenset(
    {"con", "prn", "aux", "nul"}
    | {f"com{number}" for number in range(1, 10)}
    | {f"lpt{number}" for number in range(1, 10)}
)


def _stat_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        int(metadata.st_dev),
        int(metadata.st_ino),
        int(stat.S_IFMT(metadata.st_mode)),
        int(metadata.st_nlink),
        int(metadata.st_size),
    )


def _immutable_stat_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        int(metadata.st_dev),
        int(metadata.st_ino),
        int(stat.S_IFMT(metadata.st_mode)),
    )


def _immutable_windows_directory_identity(identity: tuple[int, ...]) -> tuple[int, ...]:
    return (
        identity[0],
        identity[1],
        identity[2] & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT),
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


def _nt_relative_file_handle(
    parent_handle: int,
    name: str,
    *,
    create: bool,
    desired_access: int,
    share_access: int,
) -> int:
    from ctypes import wintypes

    if not name or Path(name).name != name or "/" in name or "\\" in name:
        raise CorpusDownloadError("lock_path_unsafe")

    class _UNICODE_STRING(ctypes.Structure):
        _fields_ = [
            ("Length", wintypes.USHORT),
            ("MaximumLength", wintypes.USHORT),
            ("Buffer", wintypes.LPWSTR),
        ]

    class _OBJECT_ATTRIBUTES(ctypes.Structure):
        _fields_ = [
            ("Length", wintypes.ULONG),
            ("RootDirectory", wintypes.HANDLE),
            ("ObjectName", ctypes.POINTER(_UNICODE_STRING)),
            ("Attributes", wintypes.ULONG),
            ("SecurityDescriptor", wintypes.LPVOID),
            ("SecurityQualityOfService", wintypes.LPVOID),
        ]

    class _IO_STATUS_BLOCK(ctypes.Structure):
        _fields_ = [
            ("Status", ctypes.c_void_p),
            ("Information", ctypes.c_size_t),
        ]

    buffer = ctypes.create_unicode_buffer(name)
    encoded_length = len(name.encode("utf-16-le"))
    unicode_name = _UNICODE_STRING(
        encoded_length,
        encoded_length + 2,
        ctypes.cast(buffer, wintypes.LPWSTR),
    )
    attributes = _OBJECT_ATTRIBUTES(
        ctypes.sizeof(_OBJECT_ATTRIBUTES),
        wintypes.HANDLE(parent_handle),
        ctypes.pointer(unicode_name),
        _OBJ_CASE_INSENSITIVE,
        None,
        None,
    )
    io_status = _IO_STATUS_BLOCK()
    handle = wintypes.HANDLE()
    ntdll = ctypes.WinDLL("ntdll", use_last_error=True)
    function = ntdll.NtCreateFile
    function.argtypes = [
        ctypes.POINTER(wintypes.HANDLE),
        wintypes.DWORD,
        ctypes.POINTER(_OBJECT_ATTRIBUTES),
        ctypes.POINTER(_IO_STATUS_BLOCK),
        ctypes.c_void_p,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.DWORD,
        wintypes.LPVOID,
        wintypes.DWORD,
    ]
    function.restype = ctypes.c_long
    status = int(function(
        ctypes.byref(handle),
        desired_access,
        ctypes.byref(attributes),
        ctypes.byref(io_status),
        None,
        _FILE_ATTRIBUTE_NORMAL,
        share_access,
        _FILE_CREATE if create else _FILE_OPEN,
        _FILE_NON_DIRECTORY_FILE
        | _FILE_SYNCHRONOUS_IO_NONALERT
        | _FILE_OPEN_REPARSE_POINT,
        None,
        0,
    ))
    if status < 0:
        converter = ntdll.RtlNtStatusToDosError
        converter.argtypes = [ctypes.c_long]
        converter.restype = wintypes.ULONG
        error = int(converter(status))
        if create and error in (80, 183):
            raise FileExistsError(error, "verified_temp_conflict")
        if not create and error in (2, 3):
            raise FileNotFoundError(error, "verified_file_missing")
        raise ctypes.WinError(error)
    if handle.value is None:
        raise OSError("verified_native_handle_missing")
    return int(handle.value)


def _create_windows_temp_relative(parent_handle: int, name: str) -> int:
    return _nt_relative_file_handle(
        parent_handle,
        name,
        create=True,
        desired_access=(
            _GENERIC_READ
            | _GENERIC_WRITE
            | _DELETE
            | _FILE_READ_ATTRIBUTES
            | _SYNCHRONIZE
        ),
        share_access=_FILE_SHARE_READ | _FILE_SHARE_WRITE | _FILE_SHARE_DELETE,
    )


def _open_windows_file_relative(parent_handle: int, name: str) -> int:
    return _nt_relative_file_handle(
        parent_handle,
        name,
        create=False,
        desired_access=_GENERIC_READ | _FILE_READ_ATTRIBUTES | _SYNCHRONIZE,
        share_access=_FILE_SHARE_READ | _FILE_SHARE_WRITE | _FILE_SHARE_DELETE,
    )


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
    try:
        return os.fdopen(descriptor, "w+b")
    except BaseException as original:
        try:
            os.close(descriptor)
        except BaseException as close_error:
            raise close_error from original
        raise


def _windows_read_file_object(handle: int):
    import msvcrt

    duplicate = _duplicate_windows_handle(handle)
    try:
        descriptor = msvcrt.open_osfhandle(duplicate, os.O_BINARY | os.O_RDONLY)
    except Exception:
        _close_windows_handle(duplicate)
        raise
    try:
        return os.fdopen(descriptor, "rb")
    except BaseException as original:
        try:
            os.close(descriptor)
        except BaseException as close_error:
            raise close_error from original
        raise


def _posix_linkat_function():
    """Return Linux linkat only when anonymous handle publication is available."""
    if not sys.platform.startswith("linux") or not getattr(os, "O_TMPFILE", 0):
        raise OSError(errno.ENOTSUP, "anonymous_temp_unavailable")
    try:
        function = ctypes.CDLL(None, use_errno=True).linkat
    except (AttributeError, OSError) as exc:
        raise OSError(errno.ENOTSUP, "anonymous_publish_unavailable") from exc
    function.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
    ]
    function.restype = ctypes.c_int
    return function


def _link_posix_anonymous_temp_no_replace(
    source_fd: int, parent_fd: int, destination_name: str
) -> None:
    if (
        not destination_name
        or Path(destination_name).name != destination_name
        or "/" in destination_name
        or "\\" in destination_name
        or "\x00" in destination_name
    ):
        raise OSError(errno.EINVAL, "anonymous_publish_name_invalid")
    function = _posix_linkat_function()
    ctypes.set_errno(0)
    result = int(
        function(
            int(source_fd),
            b"",
            int(parent_fd),
            os.fsencode(destination_name),
            _AT_EMPTY_PATH,
        )
    )
    if result == 0:
        return
    error = int(ctypes.get_errno()) or errno.EIO
    if error == errno.EEXIST:
        raise FileExistsError(error, "anonymous_publish_conflict")
    raise OSError(error, "anonymous_publish_failed")


def _posix_duplicate_file_object(handle: int, mode: str):
    duplicate = os.dup(handle)
    try:
        return os.fdopen(duplicate, mode)
    except BaseException as original:
        try:
            os.close(duplicate)
        except BaseException as close_error:
            raise close_error from original
        raise


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


def _manifest_path_component_is_unsafe(component: str) -> bool:
    if not component or component in {".", ".."}:
        return True
    if component.endswith((".", " ")):
        return True
    if any(
        character in _WINDOWS_FORBIDDEN_PATH_CHARACTERS
        or ord(character) < 32
        or 0x7F <= ord(character) <= 0x9F
        for character in component
    ):
        return True
    device_stem = component.split(".", 1)[0].casefold()
    return device_stem in _WINDOWS_DEVICE_NAMES


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
        if rel.startswith(("/", "\\")) or any(
            _manifest_path_component_is_unsafe(part) for part in parts
        ):
            raise SystemExit("Invalid manifest: local_path contains an unsafe component")
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


def _open_parent_capability(
    parent: Path,
    *,
    path_io_error: str,
    path_unsafe_error: str,
) -> _ParentCapability:
    """Pin one verified real directory while omitting Windows delete sharing."""
    try:
        metadata = os.lstat(parent)
        if _is_link_or_reparse(metadata) or not stat.S_ISDIR(metadata.st_mode):
            raise CorpusDownloadError(path_unsafe_error)
        if os.name == "nt":
            handle = _open_windows_lock_parent(parent)
            try:
                raw_identity = _windows_handle_identity(handle)
                identity = _immutable_windows_directory_identity(raw_identity)
                attributes = raw_identity[2]
                if (
                    not attributes & _FILE_ATTRIBUTE_DIRECTORY
                    or attributes & FILE_ATTRIBUTE_REPARSE_POINT
                    or not _same_windows_path(_windows_final_path(handle), parent)
                ):
                    raise CorpusDownloadError(path_unsafe_error)
                if int(metadata.st_ino) != identity[1]:
                    raise CorpusDownloadError(path_unsafe_error)
                return _ParentCapability(parent, handle, identity, True)
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
            if identity[:3] != _immutable_stat_identity(metadata):
                raise CorpusDownloadError(path_unsafe_error)
            return _ParentCapability(parent, handle, identity, False)
        except Exception:
            os.close(handle)
            raise
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError(path_io_error) from exc


def _open_lock_parent_capability(parent: Path) -> _LockParentCapability:
    return _open_parent_capability(
        parent,
        path_io_error="lock_path_io_error",
        path_unsafe_error="lock_path_unsafe",
    )


def _validate_parent_capability(
    capability: _ParentCapability,
    *,
    path_io_error: str,
    path_unsafe_error: str,
) -> None:
    if not isinstance(capability, _ParentCapability) or capability.closed:
        raise CorpusDownloadError(path_unsafe_error)
    try:
        if capability.windows:
            metadata = os.lstat(capability.path)
            if _is_link_or_reparse(metadata) or not stat.S_ISDIR(metadata.st_mode):
                raise CorpusDownloadError(path_unsafe_error)
            current = _immutable_windows_directory_identity(
                _windows_handle_identity(capability.handle)
            )
            if (
                current != capability.identity
                or not _same_windows_path(
                    _windows_final_path(capability.handle), capability.path
                )
                or int(metadata.st_ino) != capability.identity[1]
            ):
                raise CorpusDownloadError(path_unsafe_error)
        elif _immutable_stat_identity(os.fstat(capability.handle)) != capability.identity[:3]:
            raise CorpusDownloadError(path_unsafe_error)
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError(path_io_error) from exc


def _validate_lock_parent_capability(capability: _LockParentCapability) -> None:
    _validate_parent_capability(
        capability,
        path_io_error="lock_path_io_error",
        path_unsafe_error="lock_path_unsafe",
    )


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


def _create_temp_capability(
    parent: _ParentCapability,
    *,
    prefix: str,
    validate_parent,
    path_unsafe_error: str,
    temp_io_error: str,
) -> _TempCapability:
    native_handle: int | None = None
    file_handle = None
    descriptor: int | None = None
    name: str | None = None
    identity: tuple[int, ...] | None = None
    try:
        if parent.windows:
            for _attempt in range(32):
                name = f"{prefix}{uuid.uuid4().hex}.part"
                try:
                    native_handle = _create_windows_temp_relative(parent.handle, name)
                    break
                except FileExistsError:
                    continue
            if native_handle is None:
                raise CorpusDownloadError(temp_io_error)
            identity = _windows_handle_identity(native_handle)
            attributes = identity[2]
            if (
                attributes & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                or identity[3] != 1
            ):
                raise CorpusDownloadError(path_unsafe_error)
            file_handle = _windows_temp_file_object(native_handle)
            if int(os.fstat(file_handle.fileno()).st_ino) != identity[1]:
                raise CorpusDownloadError(path_unsafe_error)
            validate_parent(parent)
            return _TempCapability(
                parent.path / name,
                file_handle,
                identity,
                parent,
                native_handle=native_handle,
            )

        _posix_linkat_function()
        otmpfile = getattr(os, "O_TMPFILE", 0)
        if not otmpfile:
            raise OSError(errno.ENOTSUP, "anonymous_temp_unavailable")
        flags = (
            os.O_RDWR
            | otmpfile
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_BINARY", 0)
        )
        descriptor = os.open(".", flags, 0o600, dir_fd=parent.handle)
        file_handle = os.fdopen(descriptor, "w+b")
        descriptor = None
        identity = _stat_identity(os.fstat(file_handle.fileno()))
        if identity[2] != stat.S_IFREG or identity[3] != 0:
            raise CorpusDownloadError(path_unsafe_error)
        validate_parent(parent)
        return _TempCapability(None, file_handle, identity, parent)
    except Exception as exc:
        if file_handle is not None:
            try:
                file_handle.close()
            except Exception:
                pass
        elif descriptor is not None:
            try:
                os.close(descriptor)
            except Exception:
                pass
        if native_handle is not None:
            try:
                _mark_windows_handle_for_deletion(native_handle)
            except Exception:
                pass
            try:
                _close_windows_handle(native_handle)
            except Exception:
                pass
        if isinstance(exc, CorpusDownloadError):
            raise
        if isinstance(exc, OSError):
            raise CorpusDownloadError(temp_io_error) from exc
        raise


def _create_lock_temp_capability(
    parent: _LockParentCapability,
) -> _LockTempCapability:
    _validate_lock_parent_capability(parent)
    return _create_temp_capability(
        parent,
        prefix=f".{LOCK_NAME}.",
        validate_parent=_validate_lock_parent_capability,
        path_unsafe_error="lock_path_unsafe",
        temp_io_error="lock_publish_io_error",
    )


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


def _publish_temp_no_replace(
    temp: _TempCapability,
    parent: _ParentCapability,
    destination: Path,
    *,
    validate_parent,
    path_unsafe_error: str,
    publish_io_error: str,
) -> None:
    """Create the final hard link from the retained source handle, never replacing."""
    validate_parent(parent)
    if destination.parent != parent.path or temp.parent is not parent:
        raise CorpusDownloadError(path_unsafe_error)
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

        before = _stat_identity(os.fstat(temp.handle.fileno()))
        if (
            before[:3] != temp.identity[:3]
            or before[2] != stat.S_IFREG
            or before[3] != 0
            or before[4] != temp.identity[4]
        ):
            raise CorpusDownloadError(path_unsafe_error)
        _link_posix_anonymous_temp_no_replace(
            temp.handle.fileno(),
            parent.handle,
            destination.name,
        )
        after = _stat_identity(os.fstat(temp.handle.fileno()))
        if (
            after[:3] != before[:3]
            or after[2] != stat.S_IFREG
            or after[3] != 1
            or after[4] != before[4]
        ):
            raise CorpusDownloadError(path_unsafe_error)
        temp.identity = after
    except FileExistsError:
        raise
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError(publish_io_error) from exc


def _publish_lock_temp_no_replace(
    temp: _LockTempCapability,
    parent: _LockParentCapability,
    destination: Path,
) -> None:
    _publish_temp_no_replace(
        temp,
        parent,
        destination,
        validate_parent=_validate_lock_parent_capability,
        path_unsafe_error="lock_path_unsafe",
        publish_io_error="lock_publish_io_error",
    )


def _dispose_temp_capability(temp: _TempCapability, *, cleanup_io_error: str) -> None:
    """Dispose only the current run's already-open anonymous/native temp."""
    if temp.closed:
        return
    failure: BaseException | None = None
    try:
        if temp.parent.windows:
            if temp.native_handle is None:
                raise CorpusDownloadError(cleanup_io_error)
            try:
                temp.handle.close()
            except BaseException as exc:
                failure = exc
            try:
                _mark_windows_handle_for_deletion(temp.native_handle)
            except BaseException as exc:
                if failure is None:
                    failure = exc
            try:
                _close_windows_handle(temp.native_handle)
            except BaseException as exc:
                if failure is None:
                    failure = exc
            finally:
                temp.native_handle = None
        else:
            try:
                temp.handle.close()
            except BaseException as exc:
                failure = exc
        temp.closed = failure is None
        if failure is not None:
            if isinstance(failure, CorpusDownloadError):
                raise failure
            raise CorpusDownloadError(cleanup_io_error) from failure
    except CorpusDownloadError:
        raise
    except BaseException as exc:
        raise CorpusDownloadError(cleanup_io_error) from exc


def _dispose_lock_temp_capability(temp: _LockTempCapability) -> None:
    _dispose_temp_capability(temp, cleanup_io_error="lock_cleanup_io_error")


def _force_close_temp_capability(temp: _TempCapability) -> None:
    if temp.closed:
        return
    try:
        temp.handle.close()
    except Exception:
        pass
    if temp.native_handle is not None:
        try:
            _mark_windows_handle_for_deletion(temp.native_handle)
        except Exception:
            pass
        try:
            _close_windows_handle(temp.native_handle)
        except Exception:
            pass
        temp.native_handle = None
    temp.closed = True


def _force_close_lock_temp_capability(temp: _LockTempCapability) -> None:
    _force_close_temp_capability(temp)


def _read_existing_lock_bytes(
    parent: _LockParentCapability,
    destination: Path,
    *,
    expected_identity: tuple[int, ...] | None = None,
    expected_links: int | tuple[int, ...] = 1,
) -> bytes | None:
    _validate_lock_parent_capability(parent)
    allowed_links = (
        (expected_links,) if isinstance(expected_links, int) else tuple(expected_links)
    )
    try:
        if parent.windows:
            metadata = _lstat_or_none(destination)
            if metadata is None:
                return None
            if _is_link_or_reparse(metadata) or not stat.S_ISREG(metadata.st_mode):
                raise CorpusDownloadError("lock_path_unsafe")
            handle = None
            for attempt in range(50):
                try:
                    handle = _open_windows_file_relative(parent.handle, destination.name)
                    break
                except OSError as exc:
                    if getattr(exc, "winerror", None) not in (32, 33) or attempt == 49:
                        raise
                    time.sleep(0.01)
            if handle is None:
                raise CorpusDownloadError("lock_publish_io_error")
            try:
                identity = _windows_handle_identity(handle)
                attributes = identity[2]
                if (
                    attributes & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                    or identity[3] not in allowed_links
                    or not _same_windows_path(_windows_final_path(handle), destination)
                    or (
                        expected_identity is not None
                        and identity[:2] != expected_identity[:2]
                    )
                ):
                    raise CorpusDownloadError("lock_path_unsafe")
                with _windows_read_file_object(handle) as reader:
                    opened = os.fstat(reader.fileno())
                    if int(opened.st_ino) != identity[1]:
                        raise CorpusDownloadError("lock_path_unsafe")
                    return reader.read()
            finally:
                _close_windows_handle(handle)

        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        handle = os.open(destination.name, flags, dir_fd=parent.handle)
        try:
            opened = os.fstat(handle)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink not in allowed_links
                or (
                    expected_identity is not None
                    and _immutable_stat_identity(opened) != expected_identity[:3]
                )
            ):
                raise CorpusDownloadError("lock_path_unsafe")
            with _posix_duplicate_file_object(handle, "rb") as reader:
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
    owned_link_identity: tuple[int, ...] | None = None
    try:
        parent = _contained_lock_parent(root, create=False)
        if lock_path != parent / LOCK_NAME:
            raise CorpusDownloadError("lock_path_unsafe")
        parent_capability = _open_lock_parent_capability(parent)
        existing = _read_existing_lock_bytes(
            parent_capability, lock_path, expected_links=(1, 2)
        )
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

            existing = _read_existing_lock_bytes(
                parent_capability, lock_path, expected_links=(1, 2)
            )
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
                    owned_link_identity = temp_capability.identity
                except FileExistsError:
                    winner = _read_existing_lock_bytes(
                        parent_capability, lock_path, expected_links=(1, 2)
                    )
                    if winner != payload:
                        raise CorpusDownloadError("lock_publish_conflict") from None
                winner = _read_existing_lock_bytes(
                    parent_capability,
                    lock_path,
                    expected_identity=(
                        temp_capability.identity if linked_current_temp else None
                    ),
                    expected_links=(
                        (2 if parent_capability.windows else 1)
                        if linked_current_temp
                        else (1, 2)
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
                    if _read_existing_lock_bytes(
                        parent_capability,
                        lock_path,
                        expected_identity=owned_link_identity,
                        expected_links=(1 if owned_link_identity is not None else (1, 2)),
                    ) != payload:
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
        token = str(cleanup_error)
        cause = cleanup_error.__cause__
        cleanup_error = None
        raise CorpusDownloadError(token) from cause
    if primary_error is not None:
        token = str(primary_error)
        cause = primary_error.__cause__
        primary_error = None
        raise CorpusDownloadError(token) from cause
    if not published:
        raise CorpusDownloadError("lock_publish_io_error")


def _validate_entry_parent_capability(parent: _ParentCapability) -> None:
    _validate_parent_capability(
        parent,
        path_io_error="entry_path_io_error",
        path_unsafe_error="entry_path_unsafe",
    )


def _open_entry_parent_capability(target: Path) -> _ParentCapability:
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise CorpusDownloadError("entry_path_io_error") from exc
    return _open_parent_capability(
        target.parent,
        path_io_error="entry_path_io_error",
        path_unsafe_error="entry_path_unsafe",
    )


def _create_entry_temp_capability(
    parent: _ParentCapability, target: Path
) -> _TempCapability:
    if target.parent != parent.path:
        raise CorpusDownloadError("entry_path_unsafe")
    _validate_entry_parent_capability(parent)
    return _create_temp_capability(
        parent,
        prefix=f".{target.name}.",
        validate_parent=_validate_entry_parent_capability,
        path_unsafe_error="entry_path_unsafe",
        temp_io_error="download_temp_io_error",
    )


def _write_entry_temp_from_url(
    temp: _TempCapability,
    request: urllib.request.Request,
    timeout: int,
) -> str:
    digest = hashlib.sha256()
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except (OSError, urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as exc:
        raise CorpusDownloadError("download_network_error") from exc
    try:
        with response:
            while True:
                try:
                    chunk = response.read(1024 * 1024)
                except (OSError, urllib.error.URLError, TimeoutError) as exc:
                    raise CorpusDownloadError("download_network_error") from exc
                if not chunk:
                    break
                try:
                    temp.handle.write(chunk)
                except OSError as exc:
                    raise CorpusDownloadError("download_write_io_error") from exc
                digest.update(chunk)
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("download_network_error") from exc
    return digest.hexdigest()


def _fsync_entry_temp_capability(temp: _TempCapability) -> str:
    try:
        temp.handle.flush()
        os.fsync(temp.handle.fileno())
        current = temp.handle.tell()
        temp.handle.seek(0)
        digest = hashlib.sha256()
        for chunk in iter(lambda: temp.handle.read(1024 * 1024), b""):
            digest.update(chunk)
        temp.handle.seek(current)
        if temp.parent.windows:
            if temp.native_handle is None:
                raise CorpusDownloadError("download_fsync_io_error")
            identity = _windows_handle_identity(temp.native_handle)
            if identity[:4] != temp.identity[:4]:
                raise CorpusDownloadError("entry_path_unsafe")
        else:
            identity = _stat_identity(os.fstat(temp.handle.fileno()))
            if identity[:4] != temp.identity[:4]:
                raise CorpusDownloadError("entry_path_unsafe")
        temp.identity = identity
        return digest.hexdigest()
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("download_fsync_io_error") from exc


def _publish_entry_temp_no_replace(
    temp: _TempCapability,
    parent: _ParentCapability,
    destination: Path,
) -> None:
    _publish_temp_no_replace(
        temp,
        parent,
        destination,
        validate_parent=_validate_entry_parent_capability,
        path_unsafe_error="entry_path_unsafe",
        publish_io_error="publish_io_error",
    )


def _read_entry_destination_digest(
    parent: _ParentCapability,
    destination: Path,
    *,
    expected_identity: tuple[int, ...] | None = None,
    expected_links: int | tuple[int, ...] = (1, 2),
) -> str | None:
    _validate_entry_parent_capability(parent)
    if destination.parent != parent.path:
        raise CorpusDownloadError("entry_path_unsafe")
    allowed_links = (
        (expected_links,) if isinstance(expected_links, int) else tuple(expected_links)
    )
    handle: int | None = None
    try:
        if parent.windows:
            try:
                metadata = os.lstat(destination)
            except FileNotFoundError:
                return None
            if _is_link_or_reparse(metadata) or not stat.S_ISREG(metadata.st_mode):
                raise CorpusDownloadError("entry_path_unsafe")
            for attempt in range(50):
                try:
                    handle = _open_windows_file_relative(parent.handle, destination.name)
                    break
                except OSError as exc:
                    if getattr(exc, "winerror", None) not in (32, 33) or attempt == 49:
                        raise
                    time.sleep(0.01)
            if handle is None:
                raise CorpusDownloadError("publish_readback_io_error")
            identity = _windows_handle_identity(handle)
            if (
                identity[2] & (_FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)
                or identity[3] not in allowed_links
                or not _same_windows_path(_windows_final_path(handle), destination)
                or (
                    expected_identity is not None
                    and identity[:2] != expected_identity[:2]
                )
            ):
                raise CorpusDownloadError("entry_path_unsafe")
            reader = _windows_read_file_object(handle)
        else:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            handle = os.open(destination.name, flags, dir_fd=parent.handle)
            opened = os.fstat(handle)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_nlink not in allowed_links
                or (
                    expected_identity is not None
                    and _immutable_stat_identity(opened) != expected_identity[:3]
                )
            ):
                raise CorpusDownloadError("entry_path_unsafe")
            reader = _posix_duplicate_file_object(handle, "rb")

        digest = hashlib.sha256()
        with reader:
            for chunk in iter(lambda: reader.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except FileNotFoundError:
        return None
    except CorpusDownloadError:
        raise
    except OSError as exc:
        raise CorpusDownloadError("publish_readback_io_error") from exc
    finally:
        if handle is not None:
            try:
                if parent.windows:
                    _close_windows_handle(handle)
                else:
                    os.close(handle)
            except OSError as close_error:
                try:
                    if parent.windows:
                        _close_windows_handle(handle)
                    else:
                        os.close(handle)
                except OSError as retry_error:
                    raise CorpusDownloadError("publish_readback_io_error") from retry_error
                raise CorpusDownloadError("publish_readback_io_error") from close_error


def _dispose_entry_temp_capability(temp: _TempCapability) -> None:
    _dispose_temp_capability(temp, cleanup_io_error="download_cleanup_io_error")


def _force_close_entry_temp_capability(temp: _TempCapability) -> None:
    _force_close_temp_capability(temp)


def download_verified(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Acquire one expected byte sequence through retained object capabilities."""
    if not isinstance(expected_sha256, str) or not SHA256_RE.fullmatch(expected_sha256):
        raise CorpusDownloadError("invalid_expected_sha256")

    parent: _ParentCapability | None = None
    temp: _TempCapability | None = None
    primary_error: CorpusDownloadError | None = None
    cleanup_error: CorpusDownloadError | None = None
    result: str | None = None
    owned_link_identity: tuple[int, ...] | None = None
    try:
        try:
            parent = _open_entry_parent_capability(target)
        except CorpusDownloadError:
            raise
        except OSError as exc:
            raise CorpusDownloadError("entry_path_io_error") from exc

        try:
            existing = _read_entry_destination_digest(parent, target)
        except CorpusDownloadError:
            raise
        except OSError as exc:
            raise CorpusDownloadError("publish_readback_io_error") from exc
        if existing is not None:
            if existing != expected_sha256:
                raise CorpusDownloadError("existing_digest_mismatch")
            result = expected_sha256
        else:
            try:
                request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            except (OSError, ValueError) as exc:
                raise CorpusDownloadError("download_network_error") from exc
            try:
                temp = _create_entry_temp_capability(parent, target)
            except CorpusDownloadError:
                raise
            except OSError as exc:
                raise CorpusDownloadError("download_temp_io_error") from exc
            try:
                streamed_digest = _write_entry_temp_from_url(temp, request, timeout)
            except CorpusDownloadError:
                raise
            except OSError as exc:
                raise CorpusDownloadError("download_write_io_error") from exc
            try:
                exact_digest = _fsync_entry_temp_capability(temp)
            except CorpusDownloadError:
                raise
            except OSError as exc:
                raise CorpusDownloadError("download_fsync_io_error") from exc
            if streamed_digest != exact_digest or exact_digest != expected_sha256:
                raise CorpusDownloadError("download_digest_mismatch")

            linked_current_temp = False
            try:
                _publish_entry_temp_no_replace(temp, parent, target)
                linked_current_temp = True
                owned_link_identity = temp.identity
            except FileExistsError:
                try:
                    winner = _read_entry_destination_digest(parent, target)
                except CorpusDownloadError:
                    raise
                except OSError as exc:
                    raise CorpusDownloadError("publish_readback_io_error") from exc
                if winner != expected_sha256:
                    raise CorpusDownloadError("publish_conflict") from None
            except CorpusDownloadError:
                raise
            except OSError as exc:
                raise CorpusDownloadError("publish_io_error") from exc

            try:
                published_digest = _read_entry_destination_digest(
                    parent,
                    target,
                    expected_identity=(temp.identity if linked_current_temp else None),
                    expected_links=(
                        (2 if parent.windows else 1)
                        if linked_current_temp
                        else (1, 2)
                    ),
                )
            except CorpusDownloadError:
                raise
            except OSError as exc:
                raise CorpusDownloadError("publish_readback_io_error") from exc
            if published_digest != expected_sha256:
                raise CorpusDownloadError("published_digest_mismatch")
            result = expected_sha256
    except CorpusDownloadError as exc:
        primary_error = exc
    except OSError as exc:
        primary_error = CorpusDownloadError("entry_io_error")
        primary_error.__cause__ = exc
    finally:
        if temp is not None:
            try:
                _dispose_entry_temp_capability(temp)
            except Exception as exc:
                cleanup_error = CorpusDownloadError("download_cleanup_io_error")
                cleanup_error.__cause__ = exc
            finally:
                _force_close_entry_temp_capability(temp)
        if parent is not None:
            if result is not None and cleanup_error is None:
                try:
                    final_digest = _read_entry_destination_digest(
                        parent,
                        target,
                        expected_identity=owned_link_identity,
                        expected_links=(
                            1 if owned_link_identity is not None else (1, 2)
                        ),
                    )
                    if final_digest != expected_sha256:
                        raise CorpusDownloadError("published_digest_mismatch")
                except CorpusDownloadError as exc:
                    primary_error = exc
            try:
                _close_lock_parent_capability(parent)
            except OSError as exc:
                if cleanup_error is None:
                    cleanup_error = CorpusDownloadError("download_cleanup_io_error")
                    cleanup_error.__cause__ = exc

    if cleanup_error is not None:
        token = str(cleanup_error)
        cause = cleanup_error.__cause__
        cleanup_error = None
        raise CorpusDownloadError(token) from cause
    if primary_error is not None:
        token = str(primary_error)
        cause = primary_error.__cause__
        primary_error = None
        raise CorpusDownloadError(token) from cause
    if result is None:
        raise CorpusDownloadError("entry_io_error")
    return result


def download(url: str, target: Path, timeout: int, expected_sha256: str) -> str:
    """Verified public entry point; the expected hash is mandatory."""
    return download_verified(url, target, timeout, expected_sha256)


def _safe_url_for_evidence(url: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() != "https" or not parsed.hostname:
            return "redacted_url"
        host = parsed.hostname
        try:
            port = parsed.port
        except ValueError:
            return "redacted_url"
        if port is not None:
            host = f"{host}:{port}"
        return urllib.parse.urlunsplit(("https", host, parsed.path, "", ""))
    except (TypeError, ValueError):
        return "redacted_url"


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
                print(f"GET  {entry_id}")
                start = time.time()
                digest = download_verified(url, target, args.timeout, expected)
                elapsed = time.time() - start
                try:
                    size_bytes = target.stat().st_size
                except OSError as exc:
                    raise CorpusDownloadError("entry_result_io_error") from exc
                print(f"OK   {entry_id}: {size_bytes} bytes in {elapsed:.1f}s sha256={digest[:12]}")

            try:
                size_bytes = target.stat().st_size
            except OSError as exc:
                raise CorpusDownloadError("entry_result_io_error") from exc

            lock_entries.append(
                {
                    "id": entry_id,
                    "title": entry.get("title", ""),
                    "source_org": entry.get("source_org", ""),
                    "source_page": entry.get("source_page", ""),
                    "url": _safe_url_for_evidence(url),
                    "local_path": str(target),
                    "size_bytes": size_bytes,
                    "expected_sha256": expected,
                    "sha256": digest,
                    "features": entry.get("features", []),
                    "test_intent": entry.get("test_intent", ""),
                    "license_note": entry.get("license_note", ""),
                    "status": "ok",
                }
            )
        except CorpusDownloadError as exc:
            reason = str(exc)
            failures.append((entry_id, reason))
            print(f"FAIL {entry_id}: {reason}", file=sys.stderr)
            lock_entries.append({"id": entry_id, "status": "failed", "reason": reason})
        except (OSError, urllib.error.URLError, urllib.error.HTTPError, TimeoutError):
            reason = "entry_io_error"
            failures.append((entry_id, reason))
            print(f"FAIL {entry_id}: {reason}", file=sys.stderr)
            lock_entries.append({"id": entry_id, "status": "failed", "reason": reason})

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
