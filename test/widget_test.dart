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
      expect(find.text('StudyOrbit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('录入学习任务'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '数学 明天完成练习 30分钟');
      await tester.ensureVisible(find.text('生成任务草稿'));
      await tester.tap(find.text('生成任务草稿'));
      await tester.pumpAndSettle();
      expect(find.text('确认你的任务草稿'), findsOneWidget);
      await tester.ensureVisible(find.text('确认并添加 1 个任务'));
      await tester.tap(find.text('确认并添加 1 个任务'));
      await tester.pumpAndSettle();
      expect(store.tasks.length, 1);
      final restored = StudyStore();
      await restored.load();
      expect(restored.tasks.single.title, '数学 明天完成练习 30分钟');
      await tester.tap(find.text('任务', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(find.text('数学 明天完成练习 30分钟'), findsOneWidget);
      await tester.tap(find.text('日历'));
      await tester.pumpAndSettle();
      expect(find.text('让未来，清晰一点。'), findsOneWidget);
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
      expect(find.text('我的学习空间'), findsOneWidget);
      expect(find.text('今晚的计划，从这里开始'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'Tasks, settings and completion history survive reload and deletion',
    () async {
      final store = StudyStore();
      await store.load();
      await store.sample();
      store.tomorrowSubjects = {'数学'};
      store.deletePhotos = false;
      await store.toggle(store.tasks.first);
      await store.save();
      final copy = StudyStore();
      await copy.load();
      expect(copy.tasks.length, 3);
      expect(copy.tasks.first.done, isTrue);
      expect(copy.history.length, 2);
      expect(copy.tomorrowSubjects, {'数学'});
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
}
