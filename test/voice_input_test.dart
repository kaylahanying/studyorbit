import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:studyorbit/app.dart';

const speech = MethodChannel('si.studyorbit/offline_speech');

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('si.studyorbit/task_understanding'),
      (_) async => {
        'available': false,
        'message': 'Basic splitting is available.',
      },
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(speech, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('si.studyorbit/task_understanding'),
      null,
    );
  });

  Future<void> openVoice(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: CapturePage(mode: 2, deletePhotos: true)),
    );
    await tester.ensureVisible(find.text('Start voice input'));
  }

  Future<void> nativeEvent(
    WidgetTester tester,
    String method, [
    String? text,
  ]) async {
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      speech.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, text)),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets('Voice input previews words and appends the final result once', (
    tester,
  ) async {
    final result = Completer<String?>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(speech, (
      call,
    ) async {
      if (call.method == 'recognize') {
        expect(call.arguments, {'locale': 'en-US'});
        return result.future;
      }
      if (call.method == 'stop') {
        result.complete('Math review tomorrow, 30 minutes');
      }
      return null;
    });
    await openVoice(tester);
    await tester.enterText(find.byType(TextField), 'Existing task');
    await tester.ensureVisible(find.text('Start voice input'));
    await tester.tap(find.text('Start voice input'));
    await tester.pump();
    expect(find.text('Stop recording'), findsOneWidget);
    await nativeEvent(tester, 'listening');
    expect(
      find.text('Listening. Speak now, then tap Stop recording.'),
      findsOneWidget,
    );
    await nativeEvent(tester, 'partialResult', 'Math review');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Existing task\nMath review',
    );
    await tester.tap(find.text('Stop recording'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Existing task\nMath review tomorrow, 30 minutes',
    );
    expect(find.text('Start voice input'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'Denied permission appears beside voice controls with Settings recovery',
    (tester) async {
      var openedSettings = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(speech, (
        call,
      ) async {
        if (call.method == 'recognize') {
          throw PlatformException(
            code: 'permission_denied',
            message: 'Enable Microphone for this app in Settings.',
          );
        }
        if (call.method == 'openSettings') openedSettings = true;
        return null;
      });
      await openVoice(tester);
      await tester.tap(find.text('Start voice input'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enable Microphone for this app in Settings.'),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(
              find.text('Enable Microphone for this app in Settings.'),
            )
            .dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      await tester.ensureVisible(find.text('Open Settings'));
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(openedSettings, isTrue);
      expect(find.text('Start voice input'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'Stopping errors cancel capture without trapping the recording UI',
    (tester) async {
      final result = Completer<String?>();
      var cancelled = false;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(speech, (
        call,
      ) async {
        if (call.method == 'recognize') return result.future;
        if (call.method == 'stop') {
          throw PlatformException(
            code: 'stop_failed',
            message: 'Unable to stop recording. Please try again.',
          );
        }
        if (call.method == 'cancel') {
          cancelled = true;
          result.complete(null);
        }
        return null;
      });
      await openVoice(tester);
      await tester.tap(find.text('Start voice input'));
      await tester.pump();
      await tester.tap(find.text('Stop recording'));
      await tester.pumpAndSettle();
      expect(cancelled, isTrue);
      expect(find.text('Start voice input'), findsOneWidget);
      expect(
        find.text('Unable to stop recording. Please try again.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('A silent native session times out and releases voice controls', (
    tester,
  ) async {
    final result = Completer<String?>();
    var cancelled = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(speech, (
      call,
    ) async {
      if (call.method == 'recognize') return result.future;
      if (call.method == 'cancel') {
        cancelled = true;
        result.complete(null);
      }
      return null;
    });
    await openVoice(tester);
    await tester.tap(find.text('Start voice input'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 76));
    await tester.pumpAndSettle();
    expect(cancelled, isTrue);
    expect(find.text('Start voice input'), findsOneWidget);
    expect(
      find.text(
        'Voice input timed out. Check microphone permissions and try again.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
