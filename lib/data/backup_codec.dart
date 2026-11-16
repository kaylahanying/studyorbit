import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../domain/study_state.dart';
import 'snapshot_codec.dart';

/// This app has a distinct authenticated format; prototype backups are not
/// wire-compatible and cannot be interpreted as this application's records.
class BackupCodec {
  static const iterations = 600000;
  static const maxBackupBytes = 23 * 1024 * 1024;
  static const _header =
      'StudyOrbit study library|2|PBKDF2-HMAC-SHA256|600000|AES-256-GCM';
  final AesGcm _cipher = AesGcm.with256bits();

  Future<Uint8List> encode(StudySnapshot snapshot, String password) async {
    _checkPassword(password);
    final payload = SnapshotCodec.encode(snapshot);
    final salt = randomBytes(16);
    final key = await _key(password, salt);
    final box = await _cipher.encrypt(payload, secretKey: key,
      nonce: randomBytes(12), aad: utf8.encode(_header));
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 'StudyOrbit study library', 'version': 2,
      'kdf': 'PBKDF2-HMAC-SHA256', 'iterations': iterations,
      'cipher': 'AES-256-GCM', 'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce), 'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    })));
  }

  Future<StudySnapshot> decode(Uint8List bytes, String password) async {
    _checkPassword(password);
    if (bytes.isEmpty || bytes.length > maxBackupBytes) {
      throw const RepositoryException('invalid_backup', 'Backup is empty or exceeds 23 MiB.');
    }
    try {
      final text = utf8.decode(bytes);
      SnapshotCodec.checkJsonDepth(text);
      final data = jsonDecode(text);
      const fields = {'format', 'version', 'kdf', 'iterations', 'cipher',
        'salt', 'nonce', 'ciphertext', 'tag'};
      if (data is! Map<String, dynamic> || data.length != fields.length ||
          data.keys.any((key) => !fields.contains(key)) ||
          data['format'] != 'StudyOrbit study library' || data['version'] != 2 ||
          data['kdf'] != 'PBKDF2-HMAC-SHA256' || data['iterations'] != iterations ||
          data['cipher'] != 'AES-256-GCM') {
        throw const RepositoryException('unsupported_backup',
          'Unsupported backup format or encryption parameters.');
      }
      List<int> decode(String name, {int? length, int? maximum}) {
        final raw = data[name];
        if (raw is! String) throw const FormatException();
        final value = base64Decode(raw);
        if ((length != null && value.length != length) ||
            (maximum != null && value.length > maximum)) {
          throw const FormatException();
        }
        return value;
      }
      final salt = decode('salt', length: 16);
      final nonce = decode('nonce', length: 12);
      final tag = decode('tag', length: 16);
      final ciphertext = decode('ciphertext', maximum: SnapshotCodec.maxPayloadBytes);
      final key = await _key(password, salt);
      final payload = await _cipher.decrypt(
        SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
        secretKey: key, aad: utf8.encode(_header));
      return SnapshotCodec.decode(payload);
    } on RepositoryException {
      rethrow;
    } on SecretBoxAuthenticationError {
      throw const RepositoryException('authentication',
        'The password is incorrect or the backup was modified. Existing local data was not changed.');
    } catch (_) {
      throw const RepositoryException('invalid_backup',
        'Backup is malformed or damaged. Existing local data was not changed.');
    }
  }

  Future<SecretKey> _key(String password, List<int> salt) => Pbkdf2(
    macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256,
  ).deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);

  void _checkPassword(String password) {
    if (password.runes.length < 12 || password.length > 1024) {
      throw const RepositoryException('password',
        'Use a backup password of at least 12 characters (maximum 1,024).');
    }
  }

  static Uint8List randomBytes(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
  }
}
