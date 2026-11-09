import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:studyorbit/app.dart';
import 'package:studyorbit/services/store.dart';

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });
  testWidgets(
    'Phone: enter a task, confirm draft, persist it and navigate calendar',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = StudyStore();
      await store.load();
      await tester.pumpWidget(StudyOrbitApp(store: store));
      expect(find.text('Study Executive Assistant'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Add study tasks'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'Math exercises due tomorrow, 30 minutes',
      );
      await tester.ensureVisible(find.text('Create task drafts'));
      await tester.tap(find.text('Create task drafts'));
      await tester.pumpAndSettle();
      expect(find.text('Review your task drafts'), findsOneWidget);
      await tester.ensureVisible(find.text('Confirm and add 1 task'));
      await tester.tap(find.text('Confirm and add 1 task'));
      await tester.pumpAndSettle();
      expect(store.tasks.length, 1);
      final restored = StudyStore();
      await restored.load();
      expect(
        restored.tasks.single.title,
        'Math exercises due tomorrow, 30 minutes',
      );
      await tester.tap(find.text('Tasks', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(
        find.text('Math exercises due tomorrow, 30 minutes'),
        findsOneWidget,
      );
      await tester.tap(find.text('Calendar'));
      await tester.pumpAndSettle();
      expect(find.text('See your days ahead.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Desktop layout renders sidebar and empty state without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = StudyStore();
      await store.load();
      await tester.pumpWidget(StudyOrbitApp(store: store));
      expect(find.text('My study space'), findsOneWidget);
      expect(find.text('Your evening starts here'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('English screens and task editor fit a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = StudyStore();
    await store.sample();
    await tester.pumpWidget(StudyOrbitApp(store: store));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Tasks', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit task'));
    await tester.pumpAndSettle();
    expect(find.text('Edit study task'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Edit study task'))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Focus').first);
    await tester.tap(find.text('Focus').first);
    await tester.pumpAndSettle();
    expect(find.text('Focus mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.text('Focus mode'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('My space'));
    await tester.pumpAndSettle();
    expect(find.text('Your study space'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'Tasks, settings and completion history survive reload and deletion',
    () async {
      final store = StudyStore();
      await store.load();
      await store.sample();
      store.tomorrowSubjects = {'Math'};
      store.deletePhotos = false;
      await store.toggle(store.tasks.first);
      await store.save();
      final copy = StudyStore();
      await copy.load();
      expect(copy.tasks.length, 3);
      expect(copy.tasks.first.done, isTrue);
      expect(copy.history.length, 2);
      expect(copy.tomorrowSubjects, {'Math'});
      expect(copy.deletePhotos, isFalse);
      await copy.clear();
      final empty = StudyStore();
      await empty.load();
      expect(empty.tasks, isEmpty);
      expect(empty.history, isEmpty);
    },
  );
  test('Corrupt local data blocks automatic overwrite', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'studyorbit.v1': 'invalid-json',
        });
    final store = StudyStore();
    await store.load();
    expect(store.error, isNotNull);
    expect(store.save(), throwsStateError);
  });

  test(
    'Legacy subjects load in English without changing user content',
    () async {
      final original = StudyStore();
      await original.sample();
      final saved = jsonDecode(original.encode()) as Map<String, dynamic>;
      saved['tasks'][0]['subject'] = '数学';
      saved['tasks'][0]['title'] = '我的练习';
      saved['tasks'][0]['steps'] = ['保留我的步骤'];
      saved['tomorrowSubjects'] = ['数学', '物理'];
      saved['history'] = [
        {'message': '完成：我的练习', 'time': DateTime(2026, 11, 9).toIso8601String()},
      ];
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
            'studyorbit.v1': jsonEncode(saved),
          });
      final restored = StudyStore();
      await restored.load();
      expect(restored.error, isNull);
      expect(restored.tasks.first.subject, 'Math');
      expect(restored.tomorrowSubjects, {'Math', 'Physics'});
      expect(restored.tasks.first.title, '我的练习');
      expect(restored.tasks.first.steps, ['保留我的步骤']);
      expect(restored.history.single.message, 'Completed: 我的练习');
      await restored.save();
      final reloaded = StudyStore();
      await reloaded.load();
      expect(reloaded.tasks.first.subject, 'Math');
      expect(reloaded.tomorrowSubjects, {'Math', 'Physics'});
    },
  );
}
