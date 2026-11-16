import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/data/backup_codec.dart';
import 'package:studyorbit/data/snapshot_codec.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/domain/task.dart';

void main() {
  final codec = BackupCodec();
  const password = 'synthetic-test-password';
  final snapshot = StudySnapshot(
    tasks: [StudyTask(id: 'a', title: 'Synthetic homework', subject: 'Math',
      due: null, minutes: 30, spentSeconds: 60, remainingSeconds: 1740)],
    evidence: [TextEvidence(id: 'capture', text: 'Synthetic evidence',
      createdAt: DateTime(2026, 11, 2))],
    focusRecords: [StudyFocusRecord(id: 'segment', taskId: 'a',
      taskTitle: 'Synthetic homework', subject: 'Math',
      startedAt: DateTime(2026, 11, 2, 16), endedAt: DateTime(2026, 11, 2, 16, 1),
      focusedSeconds: 60)],
    tomorrowSubjects: {'Math'}, coursesDate: DateTime(2026, 11, 3),
  );
  late Uint8List encrypted;
  setUpAll(() async { encrypted = await codec.encode(snapshot, password); });

  test('Password backup round-trips this app schema without plaintext content', () async {
    expect(utf8.decode(encrypted), isNot(contains('Synthetic homework')));
    expect(utf8.decode(encrypted), isNot(contains('Synthetic evidence')));
    final restored = await codec.decode(encrypted, password);
    expect(restored.toJson(), snapshot.toJson());
    expect(restored.tasks.single.due, isNull);
    expect(restored.focusRecords.single.focusedSeconds, 60);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Wrong password and altered ciphertext fail authentication', () async {
    await expectLater(codec.decode(encrypted, 'another-test-password'),
      throwsA(isA<RepositoryException>().having((error) => error.code, 'code', 'authentication')));
    final json = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    final ciphertext = base64Decode(json['ciphertext'] as String);
    ciphertext[ciphertext.length ~/ 2] ^= 1;
    final changed = Uint8List.fromList(utf8.encode(jsonEncode({
      ...json, 'ciphertext': base64Encode(ciphertext),
    })));
    await expectLater(codec.decode(changed, password),
      throwsA(isA<RepositoryException>().having((error) => error.code, 'code', 'authentication')));
    expect(snapshot.tasks.single.remainingSeconds, 1740);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Malformed headers, unsupported work factors, truncation, and short passwords are rejected', () async {
    final json = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
    await expectLater(codec.decode(Uint8List.fromList([1, 2, 3]), password),
      throwsA(isA<RepositoryException>()));
    for (final header in [
      {...json, 'iterations': 1}, {...json, 'version': 1},
      {...json, 'cipher': 'none'}, {...json, 'apiKey': 'forbidden'},
      {...json, 'nonce': base64Encode([1])},
    ]) {
      await expectLater(codec.decode(Uint8List.fromList(utf8.encode(jsonEncode(header))), password),
        throwsA(isA<RepositoryException>()));
    }
    await expectLater(codec.encode(snapshot, 'short'), throwsA(isA<RepositoryException>()));
    await expectLater(codec.decode(Uint8List(BackupCodec.maxBackupBytes + 1), password),
      throwsA(isA<RepositoryException>()));
  });
}
