import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/study_state.dart';
import 'backup_codec.dart';
import 'snapshot_codec.dart';

export 'snapshot_codec.dart' show RepositoryException;

abstract class LegacyStore {
  Future<String?> read();
  Future<void> remove();
}

class _SharedPreferencesLegacy implements LegacyStore {
  late final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  @override
  Future<String?> read() => _preferences.getString('studyorbit.v1');
  @override
  Future<void> remove() => _preferences.remove('studyorbit.v1');
}

/// Serialized authenticated snapshots, with an inactive slot flushed before the
/// active pointer. Credentials are never included in the library or backups.
class LocalRepository {
  LocalRepository({FlutterSecureStorage? secureStorage, LegacyStore? legacy,
    this._initialize, this.boxName = 'studyorbit_library_v2'})
      : _secure = secureStorage ?? const FlutterSecureStorage(),
        _legacy = legacy ?? _SharedPreferencesLegacy();
  final FlutterSecureStorage _secure;
  final LegacyStore _legacy;
  final Future<void> Function()? _initialize;
  final String boxName;
  final AesGcm _cipher = AesGcm.with256bits();
  final BackupCodec _backups = BackupCodec();
  Future<void> _tail = Future.value();
  Box<dynamic>? _box;
  SecretKey? _key;
  bool _initialized = false;
  bool _loaded = false;
  bool _uncertain = false;
  String? warning;
  String get _keyName => '$boxName.encryption_key';

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _initHive() async {
    if (_initialized) return;
    if (_initialize != null) {
      await _initialize();
    } else if (!kIsWeb) {
      Hive.init((await getApplicationSupportDirectory()).path);
    }
    _initialized = true;
  }

  Future<Box<dynamic>> _open() async {
    if (_box != null && _box!.isOpen) return _box!;
    try {
      await _initHive();
      var encoded = await _secure.read(key: _keyName);
      if (encoded == null) {
        if (await Hive.boxExists(boxName)) {
          throw const RepositoryException('missing_key',
            'The encrypted library exists but its device key is unavailable. Explicitly clear local data, then restore an encrypted backup.');
        }
        encoded = base64Encode(BackupCodec.randomBytes(32));
        await _secure.write(key: _keyName, value: encoded);
        if (await _secure.read(key: _keyName) != encoded) {
          throw const RepositoryException('secure_storage',
            'Device secure storage could not retain the key. No library was created.');
        }
      }
      final key = base64Decode(encoded);
      if (key.length != 32) throw const FormatException();
      _key = SecretKey(key);
      _box = await Hive.openBox<dynamic>(boxName,
        encryptionCipher: HiveAesCipher(key), crashRecovery: false);
      if (_box!.isEmpty) {
        await _box!.put('active', -1);
        await _box!.flush();
      }
      return _box!;
    } on RepositoryException {
      rethrow;
    } catch (_) {
      throw const RepositoryException('open_failed',
        'Cannot open the encrypted library. Check device storage and secure-storage access. Existing data was preserved.');
    }
  }

  Future<StudySnapshot> load() => _serialized(_load);

  Future<StudySnapshot> _load() async {
    _loaded = false;
    warning = null;
    final box = await _open();
    final active = box.get('active');
    if (active != -1 && active != 0 && active != 1) _corrupt();
    if (active == -1) {
      String? raw;
      try {
        raw = await _legacy.read();
      } catch (_) {
        throw const RepositoryException('legacy_read',
          'Previous local data could not be read. No records were replaced.');
      }
      if (raw != null) {
        final migrated = SnapshotCodec.decodeLegacy(raw);
        await _saveVault(migrated);
        _loaded = true;
        _uncertain = false;
        await _removeLegacy();
        return migrated;
      }
      _loaded = true;
      _uncertain = false;
      return StudySnapshot();
    }
    try {
      final value = box.get('snapshot_$active');
      if (value is! String || value.length > BackupCodec.maxBackupBytes) _corrupt();
      final data = jsonDecode(value) as Map<String, dynamic>;
      if (data.length != 3 || !data.keys.toSet().containsAll({'nonce', 'tag', 'ciphertext'})) _corrupt();
      final nonce = base64Decode(data['nonce'] as String);
      final tag = base64Decode(data['tag'] as String);
      final ciphertext = base64Decode(data['ciphertext'] as String);
      if (nonce.length != 12 || tag.length != 16 || ciphertext.length > SnapshotCodec.maxPayloadBytes) _corrupt();
      final payload = await _cipher.decrypt(SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: _key!, aad: utf8.encode('$boxName|2'));
      final result = SnapshotCodec.decode(payload);
      _loaded = true;
      _uncertain = false;
      await _removeLegacy();
      return result;
    } catch (_) {
      _corrupt();
    }
  }

  Future<void> _removeLegacy() async {
    try {
      await _legacy.remove();
    } catch (_) {
      // The encrypted commit already succeeded. Do not report it as a failed
      // save or cause a retry to duplicate content; retry cleanup on next load.
      warning = 'The encrypted library was saved, but the old plaintext copy could not be removed. Reopen the app to retry cleanup.';
    }
  }

  Future<void> save(StudySnapshot snapshot) => _serialized(() async {
    if (!_loaded) await _load();
    if (_uncertain) {
      throw const RepositoryException('commit_uncertain',
        'Reopen the library before saving after an uncertain storage commit.');
    }
    await _saveVault(snapshot);
  });

  /// Explicitly confirmed backup replacement may recover a damaged payload,
  /// but never guesses a missing key or a damaged commit marker.
  Future<void> replace(StudySnapshot snapshot) => _serialized(() async {
    if (_uncertain) {
      throw const RepositoryException('commit_uncertain',
        'Reopen the library before replacing an uncertain storage commit.');
    }
    await _saveVault(snapshot);
    _loaded = true;
    await _removeLegacy();
  });

  Future<void> _saveVault(StudySnapshot snapshot) async {
    final bytes = SnapshotCodec.encode(snapshot);
    final box = await _open();
    final active = box.get('active');
    if (active != -1 && active != 0 && active != 1) _corrupt();
    final next = active == 0 ? 1 : 0;
    final sealed = await _cipher.encrypt(bytes, secretKey: _key!,
      nonce: BackupCodec.randomBytes(12), aad: utf8.encode('$boxName|2'));
    final envelope = jsonEncode({'nonce': base64Encode(sealed.nonce),
      'tag': base64Encode(sealed.mac.bytes), 'ciphertext': base64Encode(sealed.cipherText)});
    try {
      await box.put('snapshot_$next', envelope);
      await box.flush();
    } catch (_) {
      throw const RepositoryException('save_failed',
        'The new library could not be saved. Previous committed records are retained. Free device storage and retry.');
    }
    try {
      await box.put('active', next);
      await box.flush();
    } catch (_) {
      try {
        await box.put('active', active);
        await box.flush();
      } catch (_) {
        _uncertain = true;
        throw const RepositoryException('commit_uncertain',
          'Storage failed during commit and rollback. Reopen the library before making further changes.');
      }
      throw const RepositoryException('save_failed',
        'The commit failed. Previous committed records remain active. Free device storage and retry.');
    }
    warning = null;
    try {
      await box.delete('snapshot_${1 - next}');
      await box.flush();
      await box.compact();
    } catch (_) {
      warning = 'The new library was saved, but older encrypted frames could not be removed. Free device storage and save again.';
    }
  }

  Future<Uint8List> exportBackup(StudySnapshot snapshot, String password) =>
      _backups.encode(snapshot, password);
  Future<StudySnapshot> importBackup(Uint8List bytes, String password) =>
      _backups.decode(bytes, password);

  Future<void> deleteAll() => _serialized(() async {
    var failed = false;
    try {
      await _initHive();
      if (_box != null && _box!.isOpen) await _box!.close();
      _box = null;
      await Hive.deleteBoxFromDisk(boxName);
    } catch (_) {
      failed = true;
    }
    try {
      await _legacy.remove();
    } catch (_) {
      failed = true;
    }
    // Remove the key only after the vault is gone. A failed delete must not
    // destroy the only key for records that remain on disk.
    if (!failed) {
      try {
        await _secure.delete(key: _keyName);
      } catch (_) {
        failed = true;
      }
    }
    _key = null;
    _loaded = false;
    _uncertain = false;
    warning = null;
    if (failed) {
      throw const RepositoryException('delete_failed',
        'Some local data could not be deleted. Retry deletion before using this device for another student.');
    }
  });

  Future<void> close() => _serialized(() async {
    if (_box != null && _box!.isOpen) await _box!.close();
    _box = null;
    _key = null;
    _loaded = false;
  });

  static Never _corrupt() => throw const RepositoryException('corrupt',
    'The encrypted library failed its integrity/schema check. It was not replaced. Restore a backup or explicitly clear local data.');
}
