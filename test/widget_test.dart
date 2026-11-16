import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/app.dart';
import 'package:studyorbit/domain/task.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/services/study_controller.dart';

import 'ui_test_support.dart';

void main() {
  void size(WidgetTester tester, [double width = 390]) {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).first);
    await tester.tap(find.text(text).first);
    // Consent/password dialogs intentionally keep an indeterminate progress
    // indicator active. Advance the route transition, not all app animations.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<StudyController> controller({MemoryStudyRepository? repository,
      FakeHostedGateway? gateway}) async {
    final value = StudyController(repository: repository ?? MemoryStudyRepository(),
        gateway: gateway ?? FakeHostedGateway());
    await value.load();
    return value;
  }

  Future<void> openCapture(WidgetTester tester, StudyController store) async {
    await tester.pumpWidget(StudyOrbitApp(store: store));
    await tapText(tester, 'Add study tasks');
  }

  testWidgets('Desktop keeps sidebar navigation and the local empty timeline', (tester) async {
    size(tester, 1440);
    final store = await controller();
    await tester.pumpWidget(StudyOrbitApp(store: store));
    expect(find.text('My study space'), findsOneWidget);
    expect(find.text('Your evening starts here'), findsOneWidget);
    await tapText(tester, 'Tasks');
    expect(find.text('Every small task is a step forward.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Local drafts persist without becoming assignments until reviewed', (tester) async {
    size(tester);
    final repository = MemoryStudyRepository();
    final gateway = FakeHostedGateway();
    final store = await controller(repository: repository, gateway: gateway);
    await openCapture(tester, store);
    await tester.enterText(find.byType(TextField), 'Math exercises, 30 minutes');
    await tapText(tester, 'Create basic drafts locally');
    expect(find.text('Review your task drafts'), findsOneWidget);
    expect(store.tasks, isEmpty);
    expect(store.drafts.single.due, isNull);
    expect(store.drafts.single.sourceQuote, 'Math exercises, 30 minutes');
    expect(gateway.requests, isEmpty);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Confirm and add 1 task'));
    expect(button.onPressed, isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    final restored = await controller(repository: repository, gateway: gateway);
    await tester.pumpWidget(StudyOrbitApp(key: UniqueKey(), store: restored));
    await tapText(tester, '1 saved drafts to review');
    await tapText(tester, 'I checked the source, deadlines and time estimates');
    await tapText(tester, 'Confirm and add 1 task');
    expect(restored.tasks.single.title, 'Math exercises, 30 minutes');
    expect(restored.drafts, isEmpty);
    await tapText(tester, 'Calendar');
    expect(find.text('See your days ahead.'), findsOneWidget);
    await tester.ensureVisible(find.text('No deadline').last);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Every extraction asks named-provider consent and cancellation sends nothing', (tester) async {
    size(tester);
    final gateway = FakeHostedGateway();
    gateway.respond = (operation, input) => {'tasks': [
      {'title': 'Math exercises', 'subject': 'Math', 'kind': 'homework',
        'origin': 'assigned', 'minutes': 30, 'difficulty': 2,
        'dueAt': null, 'dueTimeKnown': false,
        'sourceQuote': 'Math exercises', 'reason': 'Explicit requirement',
        'steps': <String>[], 'evidenceCaptureId': '', 'basis': '', 'basisValue': ''},
    ]};
    final store = await controller(gateway: gateway);
    await openCapture(tester, store);
    await tester.enterText(find.byType(TextField), 'Math exercises');
    await tapText(tester, 'Extract tasks with AI');
    expect(find.textContaining('Provider: Test provider'), findsOneWidget);
    expect(find.textContaining('Model: Test model'), findsOneWidget);
    expect(gateway.requests, isEmpty);
    await tapText(tester, 'Not now');
    expect(store.tasks, isEmpty);
    expect(store.evidence.single.text, 'Math exercises');
    await tapText(tester, 'Extract tasks with AI');
    expect(find.text('Share text for AI task extraction?'), findsOneWidget);
    await tapText(tester, 'Share text once');
    expect(gateway.requests, hasLength(1));
    expect(store.drafts.single.title, 'Math exercises');
    expect(store.tasks, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('AI failure preserves input and local source without silently parsing', (tester) async {
    size(tester);
    final gateway = FakeHostedGateway()..respond = (operation, input) => throw StateError('Provider unavailable');
    final store = await controller(gateway: gateway);
    await openCapture(tester, store);
    await tester.enterText(find.byType(TextField), 'Physics corrections');
    await tapText(tester, 'Extract tasks with AI');
    await tapText(tester, 'Share text once');
    expect(find.textContaining('Unable to create drafts.'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Physics corrections');
    expect(store.evidence.single.text, 'Physics corrections');
    expect(store.tasks, isEmpty);
    expect(store.drafts, isEmpty);
    expect(gateway.requests, hasLength(1));
    await tapText(tester, 'Create basic drafts locally');
    expect(store.drafts, hasLength(1));
    expect(gateway.requests, hasLength(1));
  });

  testWidgets('Marked feedback saves evidence without fabricated assignments or upload', (tester) async {
    size(tester);
    final gateway = FakeHostedGateway();
    final store = await controller(gateway: gateway);
    await openCapture(tester, store);
    await tester.enterText(find.byType(TextField), 'Check signs when rearranging equations.');
    await tapText(tester, 'This is marked work / feedback, not new assignments');
    await tapText(tester, 'Save feedback locally');
    expect(store.evidence.single.feedback, isTrue);
    expect(store.tasks, isEmpty);
    expect(store.drafts, isEmpty);
    expect(gateway.requests, isEmpty);
    expect(gateway.statusCalls, 0);
  });

  testWidgets('Task editor returns an immutable copy with independent remaining estimate', (tester) async {
    size(tester, 320);
    final original = StudyTask(id: 'edit', title: 'Read chapter', subject: 'English',
        due: DateTime(2026, 11, 20), minutes: 60, remainingSeconds: 1800, spentSeconds: 600);
    StudyTask? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(
      body: TextButton(onPressed: () async {
        result = await showModalBottomSheet<StudyTask>(context: ctx, isScrollControlled: true,
            useSafeArea: true, builder: (_) => TaskEditor(task: original));
      }, child: const Text('Edit')),
    ))));
    await tapText(tester, 'Edit');
    await tapText(tester, 'Clear deadline');
    await tester.enterText(find.widgetWithText(TextFormField, 'Remaining-work minutes'), '20');
    await tapText(tester, 'Save changes');
    expect(original.due, DateTime(2026, 11, 20));
    expect(original.remainingSeconds, 1800);
    expect(result!.due, isNull);
    expect(result!.remainingSeconds, 1200);
    expect(result!.spentSeconds, 600);
    expect(result!.minutes, 60);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Narrow navigation exposes hosted status, encrypted backups and dated courses', (tester) async {
    size(tester, 320);
    final store = await controller();
    await store.add([StudyTask(id: 'unknown', title: 'Review notes', subject: 'Math', due: null, minutes: 20)]);
    await store.updateCourses({'Math'}, DateTime(2020));
    await tester.pumpWidget(StudyOrbitApp(store: store));
    expect(tester.takeException(), isNull);
    await tapText(tester, 'Tasks');
    expect(find.text('Review notes'), findsOneWidget);
    await tapText(tester, 'Calendar');
    expect(find.text('See your days ahead.'), findsOneWidget);
    await tapText(tester, 'My space');
    expect(find.text('Your study space'), findsOneWidget);
    expect(find.textContaining('Test provider'), findsOneWidget);
    await tester.ensureVisible(find.text('Export backup'));
    expect(find.text('Import backup'), findsOneWidget);
    await tester.ensureVisible(find.text('Set or reconfirm courses'));
    expect(find.textContaining('not for tomorrow'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Future planning day survives local and approved AI actions and schedules deferred work', (tester) async {
    size(tester);
    final gateway = FakeHostedGateway();
    final store = await controller(gateway: gateway);
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final key = '${tomorrow.year.toString().padLeft(4, '0')}-'
        '${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';
    await store.add([StudyTask(id: 'plan', title: 'Future-only review', subject: 'English',
        due: null, deferredUntil: tomorrow, minutes: 20)]);
    await tester.pumpWidget(StudyOrbitApp(store: store));
    await tapText(tester, 'Tomorrow');
    await tapText(tester, 'Use local plan');
    expect(gateway.requests, isEmpty);
    expect(find.text('Local plan · deterministic scheduling'), findsOneWidget);
    expect(find.text('Future-only review'), findsOneWidget);
    expect(find.text('16:00'), findsOneWidget);
    expect(find.text('Planning day: ${tomorrow.year}/${tomorrow.month}/${tomorrow.day}'), findsOneWidget);
    await tapText(tester, 'AI plan');
    expect(find.text('Share text for AI planning?'), findsOneWidget);
    expect(find.text('Planning date: ${tomorrow.year}/${tomorrow.month}/${tomorrow.day}'), findsOneWidget);
    await tapText(tester, 'Not now');
    expect(gateway.requests, isEmpty);
    await tapText(tester, 'AI plan');
    await tapText(tester, 'Share text once');
    expect(gateway.requests.single['operation'], 'plan');
    expect((gateway.requests.single['input'] as Map<String, dynamic>)['day'], key);
    expect(store.snapshot.adviceByDate.keys, contains(key));
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Tomorrow')).selected, isTrue);
    expect(find.text('Future-only review'), findsOneWidget);
    expect(find.text('16:00'), findsOneWidget);
    await tapText(tester, 'Use local plan');
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Tomorrow')).selected, isTrue);
    expect(find.text('Future-only review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Backup import is nonmutating until decrypted preview is explicitly confirmed', (tester) async {
    size(tester);
    final repository = MemoryStudyRepository();
    repository.imported = StudySnapshot(tasks: [
      StudyTask(id: 'restored', title: 'Restored task', subject: 'Math', due: null, minutes: 20),
    ]);
    final store = await controller(repository: repository);
    await store.add([StudyTask(id: 'existing', title: 'Existing task', subject: 'English', due: null, minutes: 30)]);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: BackupControls(store: store,
        selectBackup: () async => XFile.fromData(Uint8List.fromList([1]), name: 'test.studyorbit')))));
    await tapText(tester, 'Import backup');
    await tester.enterText(find.byType(TextFormField), 'wrong password');
    await tapText(tester, 'Decrypt and preview');
    expect(find.textContaining('Backup failed.'), findsOneWidget);
    expect(store.tasks.single.id, 'existing');
    await tapText(tester, 'Import backup');
    await tester.enterText(find.byType(TextFormField), 'correct password');
    await tapText(tester, 'Decrypt and preview');
    expect(find.text('Replace local library?'), findsOneWidget);
    expect(find.textContaining('Backup preview: 1 tasks, 0 drafts'), findsOneWidget);
    expect(store.tasks.single.id, 'existing');
    await tapText(tester, 'Cancel');
    expect(store.tasks.single.id, 'existing');
    await tapText(tester, 'Import backup');
    await tester.enterText(find.byType(TextFormField), 'correct password');
    await tapText(tester, 'Decrypt and preview');
    await tapText(tester, 'Replace library');
    expect(store.tasks.single.id, 'restored');
    expect(find.text('Backup restored.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Failed focus save blocks leaving and retry uses the same segment ID', (tester) async {
    size(tester);
    final repository = MemoryStudyRepository();
    final store = RecordingStudyController(repository: repository, gateway: FakeHostedGateway());
    await store.load();
    final task = StudyTask(id: 'focus', title: 'Practice equations', subject: 'Math', due: null, minutes: 30);
    await store.add([task]);
    var now = DateTime(2026, 11, 15, 16);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (ctx) => Scaffold(
      body: TextButton(onPressed: () => Navigator.of(ctx).push<void>(MaterialPageRoute(
          builder: (_) => FocusPage(task: task, store: store, now: () => now))),
          child: const Text('Open focus')),
    ))));
    await tapText(tester, 'Open focus');
    await tapText(tester, 'Start');
    now = now.add(const Duration(seconds: 47));
    repository.failWrites = true;
    await tester.tap(find.byTooltip('Save and go back'));
    await tester.pumpAndSettle();
    expect(find.text('Focus mode'), findsOneWidget);
    expect(store.tasks.single.spentSeconds, 0);
    expect(store.attempts, hasLength(1));
    repository.failWrites = false;
    await tester.tap(find.byTooltip('Save and go back'));
    await tester.pumpAndSettle();
    expect(find.text('Open focus'), findsOneWidget);
    expect(store.attempts, hasLength(2));
    expect(store.attempts.first, store.attempts.last);
    expect(store.tasks.single.spentSeconds, 47);
    expect(store.tasks.single.remainingSeconds, 1800 - 47);
    expect(store.tasks.single.done, isFalse);
    expect(store.focusRecords.single.focusedSeconds, 47);
    expect(tester.takeException(), isNull);
  });
}
