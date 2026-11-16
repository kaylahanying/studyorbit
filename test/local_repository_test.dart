import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:studyorbit/data/local_repository.dart';
import 'package:studyorbit/data/snapshot_codec.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/domain/task.dart';

class MemoryLegacy implements LegacyStore {
  MemoryLegacy(this.raw);
  String? raw;
  bool failRemove = false;
  int removals = 0;
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> remove() async {
    removals++;
    if (failRemove) throw StateError('Storage unavailable');
    raw = null;
  }
}

class DiscardingSecureStorage extends FlutterSecureStorage {
  @override
  Future<void> write({required String key, required String? value,
    AppleOptions? iOptions, AndroidOptions? aOptions, LinuxOptions? lOptions,
    WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MemoryLegacy legacy;
  late LocalRepository repository;
  const boxName = 'repository_regression';
  Map<String, dynamic> oldTask() => {
    'id': 'task-1', 'title': 'Sensitive study title', 'subject': '数学',
    'due': '2026-11-03T00:00:00.000', 'minutes': 30, 'kind': 0,
    'difficulty': 2, 'weak': false, 'done': false, 'spentSeconds': 90,
    'steps': ['Read notes'], 'deferredUntil': null,
  };
  Map<String, dynamic> oldLibrary() => {
    'version': 1, 'tasks': [oldTask()], 'history': [],
    'tomorrowSubjects': ['数学'], 'deletePhotos': true,
  };

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('studyorbit-vault-');
    legacy = MemoryLegacy(jsonEncode(oldLibrary()));
    repository = LocalRepository(boxName: boxName, legacy: legacy,
      initialize: () async => Hive.init(directory.path));
  });
  tearDown(() async {
    await repository.close();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('Migration commits encrypted data before removing legacy and never dates undated courses', () async {
    final migrated = await repository.load();
    expect(migrated.tasks.single.subject, 'Math');
    expect(migrated.tasks.single.spentSeconds, 90);
    expect(migrated.tasks.single.remainingSeconds, 1710);
    expect(migrated.tasks.single.dueTimeKnown, isFalse);
    expect(migrated.tasks.single.toJson()['due'], '2026-11-03');
    expect(migrated.tomorrowSubjects, {'Math'});
    expect(migrated.coursesDate, isNull);
    expect(legacy.raw, isNull);
    final box = Hive.box<dynamic>(boxName);
    final envelope = box.get('snapshot_${box.get('active')}') as String;
    expect(envelope, isNot(contains('Sensitive study title')));
    await repository.close();
    final reopened = await repository.load();
    expect(reopened.toJson(), migrated.toJson());
  });

  test('Malformed, unknown-version, duplicate, and incomplete legacy data remain untouched', () async {
    final invalid = <String>[
      '{broken',
      jsonEncode({...oldLibrary(), 'version': 99}),
      jsonEncode({...oldLibrary(), 'apiKey': 'not-allowed'}),
      jsonEncode({...oldLibrary(), 'tasks': [oldTask(), oldTask()]}),
      jsonEncode({...oldLibrary(), 'tasks': [{...oldTask(), 'due': '2026-02-30T00:00:00.000'}]}),
      jsonEncode({...oldLibrary(), 'tasks': [{...oldTask()}..remove('steps')]}),
      jsonEncode({...oldLibrary(), 'tasks': [{...oldTask(), 'done': 'false'}]}),
    ];
    for (final raw in invalid) {
      legacy.raw = raw;
      await expectLater(repository.load(), throwsA(isA<RepositoryException>()));
      expect(legacy.raw, raw);
      expect(legacy.removals, 0);
      expect(Hive.box<dynamic>(boxName).get('active'), -1);
    }
  });

  test('Secure storage failure never falls back to plaintext or removes legacy', () async {
    await repository.close();
    repository = LocalRepository(boxName: boxName, legacy: legacy,
      secureStorage: DiscardingSecureStorage(), initialize: () async => Hive.init(directory.path));
    final raw = legacy.raw;
    await expectLater(repository.load(), throwsA(isA<RepositoryException>()));
    expect(legacy.raw, raw);
    expect(legacy.removals, 0);
    expect(await Hive.boxExists(boxName), isFalse);
  });

  test('Failed legacy cleanup is a warning after success, not duplicate migration', () async {
    legacy.failRemove = true;
    final migrated = await repository.load();
    expect(migrated.tasks.length, 1);
    expect(repository.warning, contains('plaintext copy'));
    expect(legacy.raw, isNotNull);
    final reloaded = await repository.load();
    expect(reloaded.tasks.length, 1);
    expect(legacy.removals, 2);
    legacy.failRemove = false;
    expect((await repository.load()).tasks.length, 1);
    expect(legacy.raw, isNull);
  });

  test('Vault authentication failure refuses ordinary writes; confirmed replacement recovers', () async {
    final saved = await repository.load();
    final box = Hive.box<dynamic>(boxName);
    final active = box.get('active');
    final key = 'snapshot_$active';
    final envelope = jsonDecode(box.get(key) as String) as Map<String, dynamic>;
    final tag = base64Decode(envelope['tag'] as String)..[0] ^= 1;
    await box.put(key, jsonEncode({...envelope, 'tag': base64Encode(tag)}));
    await expectLater(repository.load(), throwsA(isA<RepositoryException>()));
    await expectLater(repository.save(StudySnapshot()), throwsA(isA<RepositoryException>()));
    expect(box.get('active'), active);
    await repository.replace(saved);
    expect((await repository.load()).tasks.single.title, 'Sensitive study title');
  });

  test('A missing key never creates an empty vault over existing data', () async {
    await repository.load();
    await repository.close();
    await const FlutterSecureStorage().delete(key: '$boxName.encryption_key');
    await expectLater(repository.load(), throwsA(isA<RepositoryException>()));
    expect(await Hive.boxExists(boxName), isTrue);
  });

  test('Snapshot validation rejects impossible dates, cycles, duplicate ids, and secrets', () {
    final task = StudyTask(id: 'a', title: 'Read', subject: 'English', due: null, minutes: 30);
    final snapshot = StudySnapshot(tasks: [task]);
    expect(() => SnapshotCodec.encode(snapshot.copyWith(tasks: [task, task])),
      throwsA(isA<RepositoryException>()));
    final json = snapshot.toJson();
    expect(() => StudySnapshot.fromJson({...json, 'credentials': {}}), throwsFormatException);
    expect(() => StudyTask.fromJson({...task.toJson(), 'due': '2026-02-30'}), throwsFormatException);
    expect(() => StudySnapshot.fromJson({...json, 'coursesDate': '2026-13-01'}), throwsFormatException);
    expect(() => PlanAdvice.fromJson({
      'order': ['a', 'b'], 'dependencies': {'a': ['b'], 'b': ['a']},
      'reasons': {}, 'suggestions': [],
    }), throwsFormatException);
  });
}
