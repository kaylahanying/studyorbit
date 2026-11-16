import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:studyorbit/data/local_repository.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/domain/task.dart';
import 'package:studyorbit/services/hosted_ai.dart';
import 'package:studyorbit/services/study_controller.dart';

class MemoryRepository extends LocalRepository {
  MemoryRepository([StudySnapshot? initial]) : saved = initial ?? StudySnapshot();
  StudySnapshot saved;
  bool failSave = false, failLoad = false;
  int writes = 0;
  Completer<void>? saveGate;
  @override
  Future<StudySnapshot> load() async {
    if (failLoad) throw const RepositoryException('corrupt', 'Cannot read saved records.');
    return saved;
  }
  @override
  Future<void> save(StudySnapshot snapshot) async {
    writes++;
    final gate = saveGate;
    saveGate = null;
    if (gate != null) await gate.future;
    if (failSave) throw const RepositoryException('save_failed', 'Storage is full.');
    saved = snapshot;
  }
  @override
  Future<void> replace(StudySnapshot snapshot) => save(snapshot);
  @override
  Future<void> deleteAll() async { saved = StudySnapshot(); }
  @override
  Future<void> close() async {}
}

class OfflineGateway extends HostedAiGateway {
  OfflineGateway() : super(origin: Uri.parse('https://example.invalid'));
  bool signedOut = false;
  @override
  Future<void> signOut() async {
    signedOut = true;
    throw const HostedAiException('network', 'Offline');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final day = DateTime(2026, 11, 2);
  StudyTask task(String id, {int remaining = 1800}) => StudyTask(id: id,
    title: id, subject: 'Math', due: null, minutes: 30, remainingSeconds: remaining);
  late MemoryRepository repository;
  late OfflineGateway gateway;
  late StudyController controller;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty();
    repository = MemoryRepository();
    gateway = OfflineGateway();
    controller = StudyController(repository: repository, gateway: gateway);
    await controller.load();
  });
  tearDown(() {
    controller.dispose();
    gateway.close();
  });

  test('Failed save publishes no task, draft removal, or activity', () async {
    await controller.saveDrafts([task('a')]);
    final before = controller.snapshot;
    repository.failSave = true;
    await expectLater(controller.add([task('a')]), throwsA(isA<RepositoryException>()));
    expect(identical(controller.snapshot, before), isTrue);
    expect(controller.tasks, isEmpty);
    expect(controller.drafts.single.id, 'a');
    expect(controller.history, isEmpty);
    expect(controller.error, 'Storage is full.');
    repository.failSave = false;
    await controller.add([task('a')]);
    expect(controller.tasks.single.id, 'a');
    expect(controller.drafts, isEmpty);
    expect(controller.error, isNull);
  });

  test('Queued writes compose on committed state and do not publish early', () async {
    final gate = Completer<void>();
    repository.saveGate = gate;
    final first = controller.add([task('a')]);
    final second = controller.updateCourses({'Physics'}, calendarDayAfter(day));
    await Future<void>.delayed(Duration.zero);
    expect(controller.tasks, isEmpty);
    expect(controller.tomorrowSubjects, isEmpty);
    expect(controller.busy, isTrue);
    gate.complete();
    await Future.wait([first, second]);
    expect(controller.tasks.single.id, 'a');
    expect(controller.tomorrowSubjects, {'Physics'});
    expect(repository.saved.tasks.single.id, 'a');
    expect(repository.saved.tomorrowSubjects, {'Physics'});
    expect(controller.busy, isFalse);
  });

  test('A busy-state listener cannot bypass mutation serialization', () async {
    final gate = Completer<void>();
    repository.saveGate = gate;
    Future<void>? reentrant;
    var queued = false;
    void listener() {
      if (!queued && controller.busy) {
        queued = true;
        reentrant = controller.updateCourses({'English'}, calendarDayAfter(day));
      }
    }
    controller.addListener(listener);
    final first = controller.add([task('a')]);
    await Future<void>.delayed(Duration.zero);
    expect(repository.writes, 1);
    gate.complete();
    await first;
    await reentrant;
    controller.removeListener(listener);
    expect(controller.tasks.single.id, 'a');
    expect(controller.tomorrowSubjects, {'English'});
    expect(repository.saved.tasks.single.id, 'a');
  });

  test('A failed queued operation does not poison later mutations', () async {
    final first = controller.add([task('a'), task('a')]);
    final second = controller.add([task('b')]);
    await expectLater(first, throwsA(isA<RepositoryException>()));
    await second;
    expect(controller.tasks.map((task) => task.id), ['b']);
  });

  test('Load failure retains prior snapshot and blocks accidental overwrite', () async {
    await controller.add([task('a')]);
    final before = controller.snapshot;
    repository.failLoad = true;
    await controller.load();
    expect(identical(controller.snapshot, before), isTrue);
    final writes = repository.writes;
    await expectLater(controller.add([task('b')]), throwsA(isA<RepositoryException>()));
    expect(repository.writes, writes);
    repository.failLoad = false;
    await controller.load();
    await controller.add([task('b')]);
    expect(controller.tasks.length, 2);
  });

  test('Focus retries atomically count actual seconds exactly once', () async {
    await controller.add([task('a', remaining: 60)]);
    Future<void> record() => controller.recordFocus(recordId: 'segment', taskId: 'a',
      seconds: 90, startedAt: day, endedAt: day.add(const Duration(seconds: 120)));
    final before = controller.snapshot;
    repository.failSave = true;
    await expectLater(record(), throwsA(isA<RepositoryException>()));
    expect(identical(controller.snapshot, before), isTrue);
    expect(controller.focusRecords, isEmpty);
    expect(controller.tasks.single.spentSeconds, 0);
    repository.failSave = false;
    await Future.wait([record(), record()]);
    expect(controller.focusRecords.length, 1);
    expect(controller.tasks.single.spentSeconds, 90);
    expect(controller.tasks.single.remainingSeconds, 0);
    expect(controller.tasks.single.done, isFalse);
    expect(controller.planFor(day).needsEstimates, ['a']);
    final writes = repository.writes;
    await record();
    expect(repository.writes, writes);
    await expectLater(controller.recordFocus(recordId: 'segment', taskId: 'a',
      seconds: 60, startedAt: day, endedAt: day.add(const Duration(seconds: 120))),
      throwsA(isA<RepositoryException>()));
    expect(controller.tasks.single.spentSeconds, 90);
  });

  test('Focus cannot exceed wall time and feed deletion retains actual time and ids', () async {
    await controller.add([task('a')]);
    await expectLater(controller.recordFocus(recordId: 'bad', taskId: 'a',
      seconds: 61, startedAt: day, endedAt: day.add(const Duration(minutes: 1))),
      throwsA(isA<FormatException>()));
    Future<void> record() => controller.recordFocus(recordId: 'valid', taskId: 'a',
      seconds: 60, startedAt: day, endedAt: day.add(const Duration(minutes: 1)));
    await record();
    await controller.clearHistory();
    await record();
    expect(controller.history, isEmpty);
    expect(controller.tasks.single.spentSeconds, 60);
    expect(controller.focusRecords.length, 1);
    await controller.saveTask(controller.tasks.single.copyWith(remainingSeconds: 2400, spentSeconds: 0));
    expect(controller.tasks.single.spentSeconds, 60);
    expect(controller.tasks.single.remainingSeconds, 2400);
  });

  test('Stale task references cannot undo another toggle', () async {
    await controller.add([task('a')]);
    final stale = controller.tasks.single;
    await Future.wait([controller.toggle(stale), controller.toggle(stale)]);
    expect(controller.tasks.single.done, isFalse);
  });

  test('Draft edits upsert, and confirmation removes only selected ids', () async {
    await controller.saveDrafts([task('a'), task('b')]);
    await controller.saveDrafts([task('a').copyWith(title: 'Edited')]);
    expect(controller.drafts.length, 2);
    expect(controller.drafts.first.title, 'Edited');
    await controller.add([controller.drafts.first]);
    expect(controller.tasks.single.title, 'Edited');
    expect(controller.drafts.single.id, 'b');
    expect(() => controller.tasks.add(task('illegal')), throwsUnsupportedError);
    expect(() => controller.tasks.first.steps.add('illegal'), throwsUnsupportedError);
  });

  test('Dated courses apply only to their exact calendar tomorrow', () async {
    repository.saved = StudySnapshot(tomorrowSubjects: {'Math'});
    await controller.load();
    expect(controller.tomorrowSubjects, {'Math'});
    expect(controller.effectiveTomorrowSubjects(day), isEmpty);
    await controller.updateCourses({'Physics'}, DateTime(2026, 11, 3, 17));
    expect(controller.coursesDate, DateTime(2026, 11, 3));
    expect(controller.effectiveTomorrowSubjects(day), {'Physics'});
    expect(controller.effectiveTomorrowSubjects(calendarDayAfter(day)), isEmpty);
    await controller.updateCourses({'English'}, DateTime(2027, 1, 1));
    expect(controller.effectiveTomorrowSubjects(DateTime(2026, 12, 31)), {'English'});
  });

  test('Advice persists dependencies and deduplicates suggested fingerprints', () async {
    await controller.add([task('a'), task('b')]);
    PlanAdvice advice(String id) => PlanAdvice(order: ['b', 'a'],
      dependencies: {'b': ['a']}, reasons: {'b': 'After a'},
      suggestions: [task(id).copyWith(title: 'Review feedback', suggested: true)]);
    await controller.applyAdvice(day, advice('suggestion-1'));
    await controller.applyAdvice(day, advice('suggestion-2'));
    expect(controller.drafts.length, 1);
    expect(controller.drafts.single.suggested, isTrue);
    expect(controller.tasks.length, 2);
    expect(controller.planFor(day).blocks.first.taskId, 'a');
    final reopened = StudyController(repository: repository, gateway: gateway);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.planFor(day).blocks.first.taskId, 'a');
    expect(reopened.snapshot.adviceByDate.containsKey('2026-11-02'), isTrue);
    final before = controller.snapshot;
    await expectLater(controller.applyAdvice(day, PlanAdvice(order: ['missing'],
      dependencies: {}, reasons: {}, suggestions: [])), throwsA(isA<RepositoryException>()));
    expect(identical(controller.snapshot, before), isTrue);
  });

  test('Failed backup replacement preserves the prior committed library', () async {
    await controller.add([task('a')]);
    final before = controller.snapshot;
    repository.failSave = true;
    await expectLater(controller.restoreBackup(StudySnapshot(tasks: [task('b')])),
      throwsA(isA<RepositoryException>()));
    expect(identical(controller.snapshot, before), isTrue);
    expect(repository.saved.tasks.single.id, 'a');
  });

  test('Offline session failure does not prevent local erasure and is visible', () async {
    await controller.add([task('a')]);
    await controller.clear();
    expect(gateway.signedOut, isTrue);
    expect(controller.tasks, isEmpty);
    expect(repository.saved.tasks, isEmpty);
    expect(controller.error, contains('hosted session could not be ended'));
  });
}
