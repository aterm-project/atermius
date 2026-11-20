import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:uuid/uuid.dart';

import '../attachments/attachment_file_saver.dart';
import '../domain/sftp_entries.dart';
import '../domain/sftp_transfer.dart';
import '../sftp/dart_sftp_text_file_system.dart';
import '../sftp/remote_file_operations.dart';
import '../sftp/sftp_text_editor_service.dart';
import 'ssh_service.dart';
import 'peer_file_copy.dart';
import '../domain/models.dart' show HostRecord;
import '../l10n/l10n.dart';

const localProfileSftpMaxDownloadBytes = 256 * 1024 * 1024;

/// Narrow transport surface for API-free LocalVault SFTP and its tests.
abstract interface class LocalProfileSftpTransport {
  Future<List<SftpName>> listDirectory(String path);

  Future<void> createDirectory(String path);

  Future<void> uploadExclusive(String path, Uint8List bytes);

  Future<Uint8List> downloadRegularFile(String path, {required int maxBytes});

  Future<int> downloadRegularFileTo(
    String path, {
    required int maxBytes,
    required Future<void> Function(Uint8List chunk) onChunk,
  });

  Future<void> removeFile(String path);

  Future<void> removeDirectory(String path);

  Future<SftpTextEditorService> textEditor({required String sessionId});

  Future<void> close();
}

typedef LocalProfileSftpTransportFactory =
    Future<LocalProfileSftpTransport> Function(SshConnection connection);

/// SFTP operations bound to one direct LocalVault SSH connection.
///
/// It has no account API, sync repository, or Relay dependency. Disposing the
/// controller closes its SFTP channel and prevents later operations.
final class LocalProfileSftpController {
  LocalProfileSftpController({
    required this.connection,
    LocalProfileSftpTransportFactory? transportFactory,
  }) : _transportFactory = transportFactory ?? _openDartSftp;

  final SshConnection connection;
  final LocalProfileSftpTransportFactory _transportFactory;
  final String sessionId = const Uuid().v4();

  Future<LocalProfileSftpTransport>? _transportOpening;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<List<SftpName>> listDirectory(String path) async {
    final safePath = _validateRemotePath(path);
    final transport = await _requireTransport();
    final entries = await transport.listDirectory(safePath);
    _ensureOpen();
    return visibleSftpEntries(entries);
  }

  Future<void> createDirectory(String parent, String name) async {
    final safeName = name.trim();
    if (!isSafeSftpBasename(safeName)) {
      throw FormatException(currentL10n.invalidFolderNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), safeName);
    final transport = await _requireTransport();
    await transport.createDirectory(path);
    _ensureOpen();
  }

  Future<void> uploadFile({
    required String parent,
    required String name,
    required Uint8List bytes,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.theLocalFileNameIsntA);
    }
    if (bytes.length > attachmentSmallSaveLimitBytes) {
      throw FormatException(currentL10n.theFileExceedsThisPlatformsSftp);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    await transport.uploadExclusive(path, bytes);
    _ensureOpen();
  }

  Future<Uint8List> downloadFile({
    required String parent,
    required String name,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    final bytes = await transport.downloadRegularFile(
      path,
      maxBytes: localProfileSftpMaxDownloadBytes,
    );
    try {
      _ensureOpen();
      return bytes;
    } catch (_) {
      bytes.fillRange(0, bytes.length, 0);
      rethrow;
    }
  }

  Future<int> downloadFileTo({
    required String parent,
    required String name,
    required AttachmentStreamingSaveWriter destination,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    try {
      final transport = await _requireTransport();
      final byteCount = await transport.downloadRegularFileTo(
        path,
        maxBytes: attachmentStreamingSaveLimitBytes,
        onChunk: (chunk) async {
          _ensureOpen();
          await destination.write(chunk);
        },
      );
      _ensureOpen();
      await destination.commit();
      return byteCount;
    } catch (_) {
      await destination.abort();
      rethrow;
    }
  }

  Future<void> deleteEntry({
    required String parent,
    required SftpName item,
  }) async {
    if (!isSafeSftpBasename(item.filename)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), item.filename);
    final transport = await _requireTransport();
    if (item.attr.isDirectory == true) {
      await transport.removeDirectory(path);
    } else {
      await transport.removeFile(path);
    }
    _ensureOpen();
  }

  Future<SftpTextDocument> openTextFile({
    required String parent,
    required String name,
  }) async {
    if (!isSafeSftpBasename(name)) {
      throw FormatException(currentL10n.invalidRemoteFileNameFormat2);
    }
    final path = sftpChildPath(_validateRemotePath(parent), name);
    final transport = await _requireTransport();
    final editor = await transport.textEditor(sessionId: sessionId);
    final document = await editor.open(path);
    try {
      _ensureOpen();
      return document;
    } catch (_) {
      document.dispose();
      rethrow;
    }
  }

  Future<SftpTextSaveResult> saveTextFile(
    SftpTextDocument document,
    String text, {
    Uint8List? expectedRemoteBytes,
    String? saveAsName,
  }) async {
    if (document.sessionId != sessionId) {
      throw StateError(currentL10n.theSftpDocumentBelongsToA);
    }
    if (saveAsName != null && !isSafeSftpBasename(saveAsName.trim())) {
      throw FormatException(currentL10n.invalidFileNameFormat);
    }
    final transport = await _requireTransport();
    final editor = await transport.textEditor(sessionId: sessionId);
    final result = saveAsName == null
        ? await editor.save(
            document,
            text,
            expectedRemoteBytes: expectedRemoteBytes,
          )
        : await editor.saveAs(
            sftpChildPath(_parentPath(document.path), saveAsName.trim()),
            text,
            permissionBits: document.permissionBits,
          );
    _ensureOpen();
    return result;
  }

  /// Byte-level filesystem of this controller's own SFTP channel for
  /// external editing: the same bounded regular-file reads, exclusive 0600
  /// staging and posix-rename atomic replace as the text editor.
  Future<SftpTextFileSystem> externalEditFileSystem() async {
    final transport = await _requireTransport();
    final editor = await transport.textEditor(sessionId: sessionId);
    _ensureOpen();
    return editor.filesystem;
  }

  /// File-manager rename/move/copy/delete bound to this controller's own
  /// SFTP channel. Every remote step re-checks that the controller is open.
  Future<RemoteFileOperations> fileOperations() async {
    final transport = await _requireTransport();
    if (transport is! RemoteFileSystemOperations) {
      throw UnsupportedError(currentL10n.fileManagerOperationUnsupported);
    }
    return RemoteFileOperations(
      transport as RemoteFileSystemOperations,
      ensureOpen: _ensureOpen,
    );
  }

  /// Binds both ends before copying. A failed peer connection switches the
  /// remainder of this copy to streaming over the two existing SFTP channels.
  Future<RemoteFileCopier> copierFrom(
    LocalProfileSftpController source, {
    required FileCopyRoute route,
    required HostRecord? destinationHost,
    required void Function() onFallback,
  }) async {
    final reader = await source._requireTransport();
    final writer = await _requireTransport();
    if (reader is! _DartLocalProfileSftpTransport ||
        writer is! _DartLocalProfileSftpTransport) {
      throw UnsupportedError(currentL10n.fileManagerOperationUnsupported);
    }
    var direct = route == FileCopyRoute.direct;
    return (
      from,
      to, {
      required maxBytes,
      required cancellation,
      onBytes,
    }) async {
      if (direct) {
        try {
          final bytes = await writer.receiveDirect(
            reader,
            source.connection,
            connection,
            destinationHost,
            from,
            to,
            maxBytes,
            cancellation,
          );
          onBytes?.call(bytes);
          return bytes;
        } on RemoteFileOperationException {
          rethrow;
        } catch (_) {
          cancellation.check();
          source._ensureOpen();
          _ensureOpen();
          direct = false;
          onFallback();
        }
      }
      return reader._streamFileTo(
        writer,
        from,
        to,
        maxBytes: maxBytes,
        cancellation: cancellation,
        onBytes: onBytes,
      );
    };
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final opening = _transportOpening;
    if (opening == null) return;
    try {
      await (await opening).close();
    } catch (_) {
      // The parent SSH transport may already have closed the SFTP channel.
    }
  }

  Future<LocalProfileSftpTransport> _requireTransport() async {
    _ensureOpen();
    final opening = _transportOpening ??= _transportFactory(connection);
    try {
      final transport = await opening;
      _ensureOpen();
      return transport;
    } catch (_) {
      if (identical(_transportOpening, opening)) _transportOpening = null;
      rethrow;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError(currentL10n.theSshSftpSessionIsClosed);
  }

  static String _validateRemotePath(String path) {
    if (path.isEmpty ||
        path.length > 4096 ||
        containsSftpControlCharacters(path)) {
      throw FormatException(currentL10n.invalidRemoteFolderPath);
    }
    return path;
  }

  static String _parentPath(String path) {
    final separator = path.lastIndexOf('/');
    if (separator <= 0) return '/';
    return path.substring(0, separator);
  }

  static Future<LocalProfileSftpTransport> _openDartSftp(
    SshConnection connection,
  ) async {
    final client = await connection.client.sftp();
    try {
      final handshake = await client.handshake;
      return _DartLocalProfileSftpTransport(client, handshake);
    } catch (_) {
      await client.close();
      rethrow;
    }
  }
}

final class _DartLocalProfileSftpTransport
    implements LocalProfileSftpTransport, RemoteFileSystemOperations {
  _DartLocalProfileSftpTransport(this._client, this._handshake);

  final SftpClient _client;
  final SftpHandsake _handshake;

  @override
  Future<List<SftpName>> listDirectory(String path) => _client.listdir(path);

  @override
  Future<void> createDirectory(String path) => _client.mkdir(path);

  @override
  Future<void> uploadExclusive(String path, Uint8List bytes) async {
    if (!supportsSftpExclusiveCreate(_handshake.version)) {
      throw UnsupportedError(currentL10n.theSftpServerVersionDoesntSupport);
    }
    await writeSftpFileWithoutOverwrite(
      remotePath: path,
      bytes: bytes,
      createExclusive: () async {
        try {
          return DartSftpUploadHandle(
            await _client.open(path, mode: sftpExclusiveCreateMode),
          );
        } on SftpStatusError catch (error) {
          throw StateError(currentL10n.couldntSafelyCreateTheRemoteFile(error));
        }
      },
      removePartial: () => _client.remove(path),
    );
  }

  @override
  Future<Uint8List> downloadRegularFile(
    String path, {
    required int maxBytes,
  }) async {
    if (maxBytes < 1) throw RangeError.value(maxBytes, 'maxBytes');
    final attributes = await _client.stat(path, followLink: false);
    if (attributes.mode?.type != SftpFileType.regularFile) {
      throw FormatException(currentL10n.onlyRegularFilesCanBeDownloaded);
    }
    if ((attributes.size ?? 0) > maxBytes) {
      throw FormatException(currentL10n.theRemoteFileExceedsTheLocal);
    }
    final file = await _client.open(path);
    try {
      final handleAttributes = await file.stat();
      if (handleAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsntARegular2);
      }
      final latestAttributes = await _client.stat(path, followLink: false);
      if (latestAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsNoLonger);
      }
      final bytes = await file.readBytes(length: maxBytes + 1);
      if (bytes.length > maxBytes) {
        bytes.fillRange(0, bytes.length, 0);
        throw FormatException(currentL10n.theRemoteFileExceedsTheLocal);
      }
      return bytes;
    } finally {
      await file.close();
    }
  }

  @override
  Future<int> downloadRegularFileTo(
    String path, {
    required int maxBytes,
    required Future<void> Function(Uint8List chunk) onChunk,
  }) async {
    if (maxBytes < 1) throw RangeError.value(maxBytes, 'maxBytes');
    final pathAttributes = await _client.stat(path, followLink: false);
    if (pathAttributes.mode?.type != SftpFileType.regularFile ||
        (pathAttributes.size ?? 0) > maxBytes) {
      throw FormatException(currentL10n.onlySizeBoundedRegularFilesCan);
    }
    final file = await _client.open(path);
    try {
      final handleAttributes = await file.stat();
      if (handleAttributes.mode?.type != SftpFileType.regularFile ||
          (handleAttributes.size ?? 0) > maxBytes) {
        throw FormatException(currentL10n.theRemotePathIsntASize);
      }
      final latestAttributes = await _client.stat(path, followLink: false);
      if (latestAttributes.mode?.type != SftpFileType.regularFile) {
        throw FormatException(currentL10n.theRemotePathIsNoLonger);
      }
      var total = 0;
      await for (final chunk in file.read()) {
        total += chunk.length;
        try {
          if (total > maxBytes) {
            throw FormatException(currentL10n.theRemoteFileExceedsTheStreaming);
          }
          await onChunk(chunk);
        } finally {
          chunk.fillRange(0, chunk.length, 0);
        }
      }
      return total;
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> removeFile(String path) => _client.remove(path);

  @override
  Future<void> removeDirectory(String path) => _client.rmdir(path);

  @override
  Stream<List<SftpName>> readDirectory(String path) =>
      // Fork: readdir closes its handle when the subscription is cancelled.
      _client.readdir(path);

  @override
  Future<SftpFileAttrs?> lstat(String path) async {
    try {
      return await _client.stat(path, followLink: false);
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  @override
  Future<void> renameNoReplace(String from, String to) =>
      // Never the posix-rename extension: it would replace [to].
      _client.renameNoReplace(from, to);

  @override
  Future<int> copyRegularFileExclusive(
    String from,
    String to, {
    required int maxBytes,
    required RemoteFileCancellation cancellation,
    void Function(int bytes)? onBytes,
  }) => _streamFileTo(
    this,
    from,
    to,
    maxBytes: maxBytes,
    cancellation: cancellation,
    onBytes: onBytes,
  );

  Future<int> _streamFileTo(
    _DartLocalProfileSftpTransport target,
    String from,
    String to, {
    required int maxBytes,
    required RemoteFileCancellation cancellation,
    void Function(int bytes)? onBytes,
  }) async {
    if (!supportsSftpExclusiveCreate(target._handshake.version)) {
      throw UnsupportedError(currentL10n.theSftpServerVersionDoesntSupport);
    }
    void requireRegular(SftpFileAttrs attributes) {
      if (attributes.mode?.type != SftpFileType.regularFile) {
        throw const RemoteFileOperationException(
          RemoteFileOperationError.sourceChanged,
        );
      }
      if ((attributes.size ?? 0) > maxBytes) {
        throw const RemoteFileOperationException(
          RemoteFileOperationError.fileTooLarge,
        );
      }
    }

    requireRegular(await _client.stat(from, followLink: false));
    final source = await _client.open(from);
    try {
      final handle = await source.stat();
      requireRegular(handle);
      requireRegular(await _client.stat(from, followLink: false));
      final SftpFile destination;
      try {
        destination = await target._client.open(
          to,
          mode: sftpExclusiveCreateMode,
        );
      } on SftpStatusError {
        if (await target.lstat(to) != null) {
          throw const RemoteFileOperationException(
            RemoteFileOperationError.destinationExists,
          );
        }
        rethrow;
      }
      var complete = false;
      var closed = false;
      try {
        // Owner-only until every byte is written.
        await destination.setStat(
          SftpFileAttrs(mode: const SftpFileMode.value(0x8000 | 0x180)),
        );
        var offset = 0;
        await for (final chunk in source.read()) {
          try {
            cancellation.check();
            if (offset + chunk.length > maxBytes) {
              throw const RemoteFileOperationException(
                RemoteFileOperationError.fileTooLarge,
              );
            }
            await destination.writeBytes(chunk, offset: offset);
            offset += chunk.length;
            onBytes?.call(chunk.length);
          } finally {
            chunk.fillRange(0, chunk.length, 0);
          }
        }
        cancellation.check();
        final permissions = (handle.mode?.value ?? 0x180) & 0x1ff;
        if (permissions != 0x180) {
          try {
            await destination.setStat(
              SftpFileAttrs(mode: SftpFileMode.value(0x8000 | permissions)),
            );
          } catch (_) {
            // Keep the safe owner-only mode if the server refuses the change.
          }
        }
        await destination.close();
        closed = true;
        complete = true;
        return offset;
      } finally {
        if (!closed) {
          try {
            await destination.close();
          } catch (_) {}
        }
        if (!complete) {
          try {
            // Only this call's exclusive-created file is removed.
            await target._client.remove(to);
          } catch (_) {}
        }
      }
    } finally {
      await source.close();
    }
  }

  Future<int> receiveDirect(
    _DartLocalProfileSftpTransport source,
    SshConnection sender,
    SshConnection receiver,
    HostRecord? host,
    String from,
    String to,
    int maxBytes,
    RemoteFileCancellation cancellation,
  ) async {
    final key = receiver.client.verifiedHostKey;
    if (host == null || key == null) {
      throw const FormatException('Missing peer endpoint');
    }
    final attrs = await source.lstat(from);
    if (attrs?.mode?.type != SftpFileType.regularFile) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.sourceChanged,
      );
    }
    final size = attrs?.size;
    if (size == null || size < 0) {
      throw const FormatException('Missing file size');
    }
    if (size > maxBytes) {
      throw const RemoteFileOperationException(
        RemoteFileOperationError.fileTooLarge,
      );
    }
    final stage = sftpChildPath(
      LocalProfileSftpController._parentPath(to),
      '.atermius-peer-${const Uuid().v4()}',
    );
    final payload = sftpChildPath(stage, 'payload');
    final command = peerFileCopyCommand(
      from: from,
      stage: stage,
      address: host.address,
      port: host.port,
      username: receiver.client.username,
      hostKey: key,
      size: size,
    );
    cancellation.check();
    await _client.mkdir(
      stage,
      SftpFileAttrs(mode: const SftpFileMode.value(0x1c0)),
    );
    final exec = SshExecCancellation();
    cancellation.onCancel = exec.cancel;
    try {
      cancellation.check();
      final result = await sender.executeRemoteCommand(
        'sh -s',
        stdinData: utf8.encode(command),
        cancellation: exec,
        timeout: const Duration(minutes: 30),
      );
      cancellation.check();
      if (result.exitCode != 0) throw const FormatException('Peer copy failed');
      final received = await lstat(payload);
      if (received?.mode?.type != SftpFileType.regularFile ||
          received?.size != size) {
        throw const FormatException('Incomplete peer copy');
      }
      final mode = attrs?.mode;
      if (mode != null) {
        await _client.setStat(
          payload,
          SftpFileAttrs(mode: SftpFileMode.value(mode.value & 0x1ff)),
        );
      }
      cancellation.check();
      await _client.renameNoReplace(payload, to);
      return size;
    } finally {
      cancellation.onCancel = null;
      try {
        await _client.remove(payload);
      } on SftpStatusError catch (_) {}
      try {
        await _client.rmdir(stage);
      } on SftpStatusError catch (_) {}
    }
  }

  @override
  Future<SftpTextEditorService> textEditor({required String sessionId}) async {
    if (!supportsSftpExclusiveCreate(_handshake.version)) {
      throw UnsupportedError(currentL10n.theSftpServerVersionIsBelow);
    }
    return SftpTextEditorService(
      filesystem: DartSftpTextFileSystem(
        _client,
        supportsAtomicReplaceExtension:
            _handshake.extensions['posix-rename@openssh.com'] == '1',
      ),
      sessionId: sessionId,
    );
  }

  @override
  Future<void> close() => _client.close();
}
