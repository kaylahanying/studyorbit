import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/app.dart';
import 'package:studyorbit/domain/task.dart';
import 'package:studyorbit/services/task_understanding.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final service = TaskUnderstanding();
  final now = DateTime(2026, 11, 2, 16);
  const input =
      'Tomorrow I need to finish my math exercises and research and write an English essay.';
  Map<String, dynamic> draft(
    String title, {
    String subject = 'Math',
    String date = '2026-11-03',
    int minutes = 30,
  }) => {
    'title': title,
    'subject': subject,
    'kind': 'homework',
    'dueDate': date,
    'minutes': minutes,
    'steps': <String>[],
  };
  final response = [
    draft('Finish math exercises'),
    draft('Research English essay', subject: 'English', minutes: 20),
    draft('Write English essay', subject: 'English', minutes: 40),
  ];
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      TaskUnderstanding.channel,
      null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('si.studyorbit/offline_speech'),
      null,
    );
  });

  test(
    'Photo classification preserves academic, unrelated and unclear results',
    () async {
      for (final category in ['academic', 'nonAcademic', 'unclear']) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          TaskUnderstanding.channel,
          (call) async {
            expect(call.method, 'classifyPhoto');
            expect(call.arguments['text'], 'Solve x + 2 = 5');
            return {
              'category': category,
              'subject': 'Math',
              'topic': 'Linear equations',
              'contentType': 'problems',
            };
          },
        );
        final result = await service.photoRequest(
          'classifyPhoto',
          'Solve x + 2 = 5',
        );
        expect(result['category'], category);
        expect(result['contentType'], 'problems');
      }
    },
  );

  test('Photo guide sends the chosen learning goal and original OCR', () async {
    for (final goal in ['study', 'practice', 'solve']) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (call) async {
          expect(call.method, 'photoGuide');
          expect(call.arguments['goal'], goal);
          expect(call.arguments['text'], 'Solve x + 2 = 5');
          return {
            'title': 'Linear equations',
            'body': 'Subtract 2 from both sides.',
          };
        },
      );
      final result = await service.photoRequest(
        'photoGuide',
        'Solve x + 2 = 5',
        goal: goal,
      );
      expect(result['body'], 'Subtract 2 from both sides.');
    }
  });

  test(
    'Rejects malformed photo classifications and incomplete guides',
    () async {
      for (final value in [
        {
          'category': 'invented',
          'subject': 'Math',
          'topic': 'Equations',
          'contentType': 'problems',
        },
        {
          'category': 'academic',
          'subject': 'Math',
          'topic': '',
          'contentType': 'problems',
        },
        {
          'category': 'academic',
          'subject': 'Math',
          'topic': 'Equations',
          'contentType': 'invented',
        },
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          TaskUnderstanding.channel,
          (_) async => value,
        );
        await expectLater(
          service.photoRequest('classifyPhoto', 'x + 2 = 5'),
          throwsFormatException,
        );
      }
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (_) async => {'title': 'Guide', 'body': ''},
      );
      await expectLater(
        service.photoRequest('photoGuide', 'x + 2 = 5', goal: 'solve'),
        throwsFormatException,
      );
    },
  );

  test(
    'Rejects empty and oversized photo text before native inference',
    () async {
      var called = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (_) async {
          called = true;
          return null;
        },
      );
      for (final text in [' ', 'a' * 3001]) {
        await expectLater(
          service.photoRequest('classifyPhoto', text),
          throwsFormatException,
        );
      }
      expect(called, isFalse);
    },
  );

  test('Uses existing tasks and history to draft a dated update without losing progress', () async {
    final saved = StudyTask(
      id: 'physics-test',
      title: 'Practice forces',
      subject: 'Physics',
      due: now,
      minutes: 40,
      spentSeconds: 600,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      TaskUnderstanding.channel,
      (call) async {
        expect(call.arguments['context'], contains('Practice forces'));
        expect(
          call.arguments['context'],
          contains('Completed: Force diagrams'),
        );
        return [
          {
            ...draft('Practice forces', subject: 'Physics', date: '2026-11-16'),
            'taskReference': 1,
            'needsPractice': true,
            'startDate': '2026-11-14',
          },
        ];
      },
    );
    final result = await service.understand(
      'Move the physics test to two weeks from today. I need more physics practice.',
      now,
      savedTasks: [saved],
      history: [HistoryEntry('Completed: Force diagrams', now)],
    );
    expect(result.single.id, saved.id);
    expect(result.single.remaining, 30);
    expect(result.single.spentSeconds, 600);
    expect(result.single.weak, isTrue);
    expect(result.single.deferredUntil, DateTime(2026, 11, 14));
    expect(saved.due, now);
  });

  test('Sends a complete paragraph and local reference date to native understanding', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      TaskUnderstanding.channel,
      (call) async {
        expect(call.method, 'understand');
        expect(call.arguments, {'text': input, 'referenceDate': '2026-11-02'});
        return response;
      },
    );
    final tasks = await service.understand(input, now);
    expect(tasks.map((t) => t.title), [
      'Finish math exercises',
      'Research English essay',
      'Write English essay',
    ]);
    expect(tasks.map((t) => t.subject), ['Math', 'English', 'English']);
    expect(tasks.map((t) => t.minutes), [30, 20, 40]);
    expect(tasks.every((t) => t.due == DateTime(2026, 11, 3)), isTrue);
    expect(tasks.every((t) => t.kind == TaskKind.homework), isTrue);
    expect(tasks.map((t) => t.id).toSet(), hasLength(3));
  });

  test(
    'Rejects malformed output as a whole instead of dropping an assignment',
    () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (_) async => [
          draft('Valid first task'),
          draft('Invalid date', date: '2026-02-30'),
        ],
      );
      await expectLater(service.understand(input, now), throwsFormatException);
    },
  );

  test(
    'Rejects unsupported subjects, excessive durations, and empty task lists',
    () async {
      for (final output in [
        [draft('Task', subject: 'Invented subject')],
        [draft('Task', minutes: 900)],
        <Map<String, dynamic>>[],
      ]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          TaskUnderstanding.channel,
          (_) async => output,
        );
        await expectLater(
          service.understand(input, now),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'Does not call the model with empty or excessively long input',
    () async {
      var called = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (_) async {
          called = true;
          return response;
        },
      );
      await expectLater(service.understand(' ', now), throwsFormatException);
      await expectLater(
        service.understand('a' * 3001, now),
        throwsFormatException,
      );
      expect(called, isFalse);
    },
  );

  testWidgets(
    'One paragraph becomes multiple editable Apple Intelligence drafts',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (call) async {
          if (call.method == 'availability') {
            return {
              'available': true,
              'message': 'Task understanding is available on this iPhone.',
            };
          }
          if (call.method == 'understand') {
            expect(call.arguments['text'], input);
            return response;
          }
          return null;
        },
      );
      await tester.pumpWidget(
        const MaterialApp(home: CapturePage(mode: 0, deletePhotos: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apple Intelligence · On device'), findsOneWidget);
      await tester.enterText(find.byType(TextField), input);
      await tester.ensureVisible(find.text('Create task drafts'));
      await tester.tap(find.text('Create task drafts'));
      await tester.pumpAndSettle();
      for (final task in response) {
        expect(find.text(task['title'] as String), findsOneWidget);
      }
      expect(find.text('Confirm and add 3 tasks'), findsOneWidget);
      expect(
        find.textContaining('Apple Intelligence used your input'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Completed voice input automatically starts native task understanding',
    (tester) async {
      var understood = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (call) async {
          if (call.method == 'availability') {
            return {'available': true, 'message': 'Ready'};
          }
          if (call.method == 'understand') {
            understood = true;
            return response;
          }
          return null;
        },
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('si.studyorbit/offline_speech'),
        (call) async => call.method == 'recognize' ? input : null,
      );
      await tester.pumpWidget(
        const MaterialApp(home: CapturePage(mode: 2, deletePhotos: true)),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Start voice input'));
      await tester.tap(find.text('Start voice input'));
      await tester.pumpAndSettle();
      expect(understood, isTrue);
      expect(find.text('Review your task drafts'), findsOneWidget);
      expect(find.text('Confirm and add 3 tasks'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Unavailable Apple Intelligence is labeled and basic splitting stays usable',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (_) async => {
          'available': false,
          'message': 'Turn on Apple Intelligence in Settings.',
        },
      );
      await tester.pumpWidget(
        const MaterialApp(home: CapturePage(mode: 0, deletePhotos: true)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Turn on Apple Intelligence in Settings.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextField),
        'Math review tomorrow, 20 min\nEnglish reading, 30 min',
      );
      await tester.ensureVisible(find.text('Create task drafts'));
      await tester.tap(find.text('Create task drafts'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm and add 2 tasks'), findsOneWidget);
      expect(
        find.textContaining('Basic drafts use one task per line.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Apple Intelligence used your input'),
        findsNothing,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Model failure preserves original text and offers explicit basic fallback',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        TaskUnderstanding.channel,
        (call) async {
          if (call.method == 'availability') {
            return {'available': true, 'message': 'Ready'};
          }
          throw PlatformException(
            code: 'generation_failed',
            message: 'Try a shorter description.',
          );
        },
      );
      await tester.pumpWidget(
        const MaterialApp(home: CapturePage(mode: 0, deletePhotos: true)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), input);
      await tester.ensureVisible(find.text('Create task drafts'));
      await tester.tap(find.text('Create task drafts'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        input,
      );
      expect(find.text('Try a shorter description.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Try a shorter description.')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      expect(find.text('Use basic splitting instead'), findsOneWidget);
      expect(find.text('Review your task drafts'), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
