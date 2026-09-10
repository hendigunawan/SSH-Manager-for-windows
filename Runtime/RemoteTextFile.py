"""Small Linux/Python 3 helper, executed over SSH; never installed on the node."""
import base64
import datetime
import fcntl
import hashlib
import json
import os
import stat
import sys
import tempfile

MAX_BYTES = 2 * 1024 * 1024


class EditorError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fingerprint(info, data):
    metadata = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns,
                info.st_ctime_ns, info.st_mode, info.st_uid, info.st_gid, info.st_nlink)
    return hashlib.sha256(repr(metadata).encode('ascii') + b'\0' + data).hexdigest()


def snapshot(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise EditorError('NOT_FILE', 'Pilih file teks biasa, bukan folder atau special file.')
        if before.st_size > MAX_BYTES:
            raise EditorError('TOO_LARGE', 'Editor mendukung file maksimal 2 MiB. Gunakan SCP untuk file besar.')
        data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise EditorError('TOO_LARGE', 'File melebihi batas 2 MiB.')
        after = os.fstat(stream.fileno())
        if fingerprint(before, data) != fingerprint(after, data):
            raise EditorError('CONFLICT', 'File berubah saat dibaca. Silakan muat ulang.')
        return data, after, fingerprint(after, data)


def stage_file(directory, prefix, data, source_path, source_stat, preserve_time=False):
    descriptor, path = tempfile.mkstemp(prefix=prefix, dir=directory)
    try:
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(data)
            stream.flush()
            info = os.fstat(stream.fileno())
            if (info.st_uid, info.st_gid) != (source_stat.st_uid, source_stat.st_gid):
                os.fchown(stream.fileno(), source_stat.st_uid, source_stat.st_gid)
            os.fchmod(stream.fileno(), stat.S_IMODE(source_stat.st_mode))
            # Preserve ACL/SELinux/user attributes; refuse rather than silently drop them.
            source_attributes = set(os.listxattr(source_path))
            for name in set(os.listxattr(path)) - source_attributes:
                os.removexattr(path, name)
            for name in source_attributes:
                value = os.getxattr(source_path, name)
                try:
                    existing = os.getxattr(path, name)
                except OSError:
                    existing = None
                if existing != value:
                    os.setxattr(path, name, value)
            if preserve_time:
                os.utime(path, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
            os.fsync(stream.fileno())
        return path
    except BaseException:
        os.unlink(path)
        raise


def handle(request):
    requested = request.get('path', '')
    if not isinstance(requested, str) or not requested or any(c in requested for c in '\0\r\n'):
        raise EditorError('PATH', 'Path file remote tidak valid.')
    path = os.path.realpath(os.path.expanduser(requested))
    operation = request.get('operation')
    if operation not in ('read', 'save'):
        raise EditorError('OPERATION', 'Operasi editor tidak dikenal.')
    if operation == 'read':
        return operate_on_file(request, path, operation)
    # A directory lock remains stable across atomic file replacements, needs no
    # lock-file cleanup, and serializes saves by all editor helpers in this folder.
    # External writers must use the same advisory lock for full coordination.
    directory_fd = os.open(os.path.dirname(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(directory_fd, fcntl.LOCK_EX)
        return operate_on_file(request, path, operation)
    finally:
        os.close(directory_fd)


def operate_on_file(request, path, operation):
    original, info, version = snapshot(path)
    if operation == 'read':
        return dict(ok=True, path=path, version=version, size=len(original),
                    content=base64.b64encode(original).decode('ascii'))
    if request.get('expected') != version:
        raise EditorError('CONFLICT', 'File di server sudah berubah sejak dibuka. Muat ulang atau simpan salinan lokal; perubahan server tidak ditimpa.')
    if info.st_nlink != 1:
        raise EditorError('HARDLINK', 'File memiliki hard link. Penyimpanan editor dibatalkan agar hubungan hard link tetap utuh.')
    if not os.access(path, os.W_OK):
        raise EditorError('PERMISSION', 'User SSH tidak memiliki izin menulis file ini.')
    try:
        data = base64.b64decode(request.get('content', ''), validate=True)
    except (ValueError, TypeError):
        raise EditorError('CONTENT', 'Isi file tidak valid.')
    if len(data) > MAX_BYTES:
        raise EditorError('TOO_LARGE', 'Isi file melebihi batas 2 MiB.')
    directory = os.path.dirname(path)
    staged = None
    backup = None
    committed = False
    try:
        staged = stage_file(directory, '.proper-edit-', data, path, info)
        if request.get('backup', True):
            prefix = '.proper-backup-' + datetime.datetime.utcnow().strftime('%Y%m%d-%H%M%S-')
            backup = stage_file(directory, prefix, original, path, info, preserve_time=True)
        _, _, current_version = snapshot(path)
        if current_version != version:
            raise EditorError('CONFLICT', 'File berubah sebelum penyimpanan selesai. Muat ulang file terlebih dahulu.')
        os.replace(staged, path)
        staged = None
        committed = True
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        saved_data, _, saved_version = snapshot(path)
        if saved_data != data:
            raise EditorError('CONFLICT', 'File berubah lagi setelah disimpan. Muat ulang untuk memeriksa versi server.')
        return dict(ok=True, path=path, version=saved_version, size=len(data), backup=backup or '')
    finally:
        if staged is not None:
            os.unlink(staged)
        if backup is not None and not committed:
            os.unlink(backup)


def main():
    try:
        if os.name != 'posix':
            raise EditorError('PLATFORM', 'Editor remote membutuhkan server Linux dengan Python 3.')
        raw = sys.stdin.read(MAX_BYTES * 4 // 3 + 65537)
        if len(raw) > MAX_BYTES * 4 // 3 + 65536:
            raise EditorError('TOO_LARGE', 'Permintaan editor terlalu besar.')
        result = handle(json.loads(raw))
    except EditorError as error:
        result = dict(ok=False, code=error.code, message=str(error))
    except Exception as error:
        result = dict(ok=False, code='IO', message=str(error))
    print('__PSM_TEXT__' + json.dumps(result, ensure_ascii=True, separators=(',', ':')))


if __name__ == '__main__':
    main()
