import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:studyorbit/domain/task.dart';
import 'package:studyorbit/domain/study_state.dart';
import 'package:studyorbit/services/hosted_ai.dart';
import 'package:studyorbit/services/study_ai.dart';

final now = DateTime(2026, 11, 15, 17);
const source = 'Math worksheet due tomorrow at 17:00.';
Map<String, dynamic> generatedTask() => {
  'title': 'Math worksheet', 'subject': 'Math', 'kind': 'homework',
  'origin': 'assigned', 'minutes': 30, 'difficulty': 2,
  'dueAt': '2026-11-16T17:00:00', 'dueTimeKnown': true,
  'sourceQuote': source, 'reason': 'The source assigns a worksheet.',
  'steps': ['Read the worksheet'], 'evidenceCaptureId': '', 'basis': '', 'basisValue': '',
};
Map<String, dynamic> emptyAdvice() => {
  'order': <String>[], 'dependencies': <String, dynamic>{},
  'reasons': <String, dynamic>{}, 'suggestions': <dynamic>[],
};
http.Response jsonResponse(Object value, {int status = 200, Map<String, String>? headers}) =>
  http.Response(jsonEncode(value), status, headers: {'content-type': 'application/json', ...?headers});

StudyAiClient clientFor(Map<String, dynamic> Function(Map<String, dynamic>) respond, {
  void Function(http.Request)? inspect,
  String finish = 'stop',
}) {
  final csrf = List.filled(64, 'c').join();
  final cookie = 'studyorbit_session=${List.filled(43, 's').join()}';
  final gateway = HostedAiGateway(origin: Uri.parse('http://127.0.0.1:8787'),
    client: MockClient((request) async {
      inspect?.call(request);
      if (request.url.path == '/api/session') {
        return jsonResponse({
          'authenticated': true, 'configured': true, 'requiresInvite': false,
          'provider': 'test.invalid', 'model': 'test-model', 'remaining': 20,
          'dailyLimit': 20, 'csrfToken': csrf,
        }, headers: {'set-cookie': '$cookie; HttpOnly; SameSite=Strict; Path=/'});
      }
      expect(request.headers['X-CSRF-Token'], csrf);
      expect(request.headers['Cookie'], cookie);
      expect(request.headers['Origin'], 'http://127.0.0.1:8787');
      expect(request.headers.containsKey('Authorization'), isFalse);
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'operation', 'input', 'consent'});
      expect(body['consent'], isTrue);
      return jsonResponse({'choices': [{
        'finish_reason': finish,
        'message': {'content': jsonEncode(respond(body))},
      }]});
    }));
  addTearDown(gateway.close);
  final client = StudyAiClient(gateway: gateway);
  addTearDown(client.close);
  return client;
}
Future<List<StudyTask>> extract(StudyAiClient client, {
  String text = source, bool consent = true, StudySnapshot? context,
}) => client.extractTasks(text: text, captureId: 'capture', now: now,
  context: context ?? StudySnapshot(), consent: consent);
Future<PlanAdvice> plan(StudyAiClient client, StudySnapshot context, {DateTime? day}) =>
  client.advisePlan(context: context, day: day ?? now, now: now, consent: true);
Matcher get responseError => throwsA(isA<AiException>().having((error) => error.code, 'code', 'response'));
StudyTask localTask(String id, {int remainingSeconds = 900, bool done = false, DateTime? deferred}) =>
  StudyTask(id: id, title: 'Work $id', subject: 'Math', due: null,
    minutes: 60, remainingSeconds: remainingSeconds, spentSeconds: 2700,
    done: done, deferredUntil: deferred, steps: ['Read source']);

void main() {
  test('consent prevents even session traffic and closed client cannot send', () async {
    var calls = 0;
    final client = clientFor((_) => {'tasks': []}, inspect: (_) => calls++);
    await expectLater(extract(client, consent: false),
      throwsA(isA<AiException>().having((e) => e.code, 'code', 'consent')));
    expect(calls, 0);
    client.close();
    await expectLater(extract(client), throwsA(isA<AiException>().having((e) => e.code, 'code', 'closed')));
    expect(calls, 0);
  });

  test('grounded extraction returns reviewable immutable task with precise deadline', () async {
    final client = clientFor((_) => {'tasks': [generatedTask()]});
    final tasks = await extract(client);
    expect(tasks.single.done, isFalse);
    expect(tasks.single.suggested, isFalse);
    expect(tasks.single.remainingSeconds, 1800);
    expect(tasks.single.due, DateTime(2026, 11, 16, 17));
    expect(tasks.single.dueTimeKnown, isTrue);
    expect(tasks.single.sourceCaptureId, 'capture');
    expect(tasks.single.sourceQuote, source);
  });

  test('completed feedback may correctly produce no new assigned work', () async {
    final client = clientFor((_) => {'tasks': []});
    expect(await extract(client, text: 'Graded worksheet returned. All assigned work completed.'), isEmpty);
  });

  for (final invalid in ['quote', 'deadline', 'clock', 'assignedSuggestion', 'unknownField', 'missingField', 'timezone', 'nonzeroSeconds']) {
    test('rejects ungrounded or malformed $invalid as a whole', () async {
      final task = generatedTask();
      switch (invalid) {
        case 'quote': task['sourceQuote'] = 'Invented quote';
        case 'deadline': task['dueAt'] = '2026-11-18T17:00:00';
        case 'clock': task['dueAt'] = '2026-11-16T18:00:00';
        case 'assignedSuggestion': task['origin'] = 'suggested';
        case 'unknownField': task['apiKey'] = 'not-allowed';
        case 'missingField': task.remove('dueAt');
        case 'timezone': task['dueAt'] = '2026-11-16T17:00:00Z';
        case 'nonzeroSeconds': task['dueAt'] = '2026-11-16T17:00:23';
      }
      final client = clientFor((_) => {'tasks': [generatedTask(), task]});
      await expectLater(extract(client), responseError);
    });
  }

  test('partial provider completion is never accepted', () async {
    final client = clientFor((_) => {'tasks': [generatedTask()]}, finish: 'length');
    await expectLater(extract(client), responseError);
  });

  for (final fixture in [
    ('Worksheet due tomorrow.', '2026-11-16', false),
    ('Worksheet due 11/16.', '2026-11-16', false),
    ('Worksheet due November 16.', '2026-11-16', false),
    ('Worksheet due 16 November 2026.', '2026-11-16', false),
    ('Worksheet due Nov 16, 2027.', '2027-11-16', false),
    ('Worksheet due next Sunday.', '2026-11-22', false),
    ('Worksheet due 2026-11-16 at 5 pm.', '2026-11-16T17:00:00', true),
  ]) {
    test('grounds supported date ${fixture.$1}', () async {
      final task = generatedTask()..addAll({
        'sourceQuote': fixture.$1, 'dueAt': fixture.$2, 'dueTimeKnown': fixture.$3,
      });
      final client = clientFor((_) => {'tasks': [task]});
      final result = (await extract(client, text: fixture.$1)).single;
      expect(result.due, DateTime.parse(fixture.$2));
      expect(result.dueTimeKnown, fixture.$3);
    });
  }
  for (final text in ['Worksheet questions 11/16.', 'Assigned today, worksheet due tomorrow at 17:00.',
    'Worksheet due tomorrow at 17:00 or 18:00.']) {
    test('ambiguous dates and question fractions cannot ground a chosen deadline: $text', () async {
      final task = generatedTask()..['sourceQuote'] = text;
      final client = clientFor((_) => {'tasks': [task]});
      await expectLater(extract(client, text: text), responseError);
    });
  }

  test('explicit years outside the model range cannot turn into this year', () async {
    for (final quote in [
      'Worksheet due 16 November 1999.',
      'Worksheet due November 16, 2101.',
    ]) {
      final task = generatedTask()..addAll({
        'sourceQuote': quote,
        'dueAt': '2026-11-16',
        'dueTimeKnown': false,
      });
      final client = clientFor((_) => {'tasks': [task]});
      await expectLater(extract(client, text: quote), responseError);
    }
  });

  test('unknown dates remain null, date-only does not invent a clock', () async {
    final task = generatedTask()..addAll({'sourceQuote': 'Read chapter 4.', 'dueAt': null, 'dueTimeKnown': false});
    final client = clientFor((_) => {'tasks': [task]});
    final result = (await extract(client, text: 'Read chapter 4.')).single;
    expect(result.due, isNull);
    expect(result.dueTimeKnown, isFalse);
  });

  test('context sends confirmed remaining work and actual evidence/focus, never drafts or invented task dates', () async {
    final state = StudySnapshot(
      tasks: [localTask('ready'), localTask('exhausted', remainingSeconds: 0),
        localTask('done', done: true), localTask('later', deferred: DateTime(2026, 11, 18))],
      drafts: [localTask('secret-draft')],
      tomorrowSubjects: {'Math'}, coursesDate: DateTime(2026, 11, 16),
      history: [HistoryEntry('Focus saved', DateTime(2026, 11, 15, 16, 30))],
      evidence: [TextEvidence(id: 'graded', text: 'Feedback: review fractions.', createdAt: DateTime(2026, 11, 15, 15), feedback: true)],
      focusRecords: [StudyFocusRecord(id: 'focus', taskId: 'ready', taskTitle: 'Work ready',
        subject: 'Math', startedAt: DateTime(2026, 11, 15, 16),
        endedAt: DateTime(2026, 11, 15, 16, 20), focusedSeconds: 900)],
    );
    final client = clientFor((body) {
      final input = body['input'] as Map<String, dynamic>;
      expect(input['eligibleTaskIds'], ['ready']);
      final context = input['context'] as Map<String, dynamic>;
      final tasks = context['confirmedTasks'] as List;
      expect(tasks.length, 4);
      expect(tasks.first['minutes'], 15);
      expect(tasks.first['remainingSeconds'], 900);
      expect(tasks.first['spentSeconds'], 2700);
      expect(tasks.first.containsKey('createdAt'), isFalse);
      expect(tasks.first.containsKey('updatedAt'), isFalse);
      expect(tasks.first['steps'][0]['id'], 'ready-step-0');
      expect(tasks[1]['stage'], 'ready');
      expect(context['recentFocusRecords'][0]['focusedSeconds'], 900);
      expect(context['recentTextEvidence'][0]['feedback'], isTrue);
      expect(context['preferences']['coursesDate'], '2026-11-16');
      expect(context['preferences']['tomorrowCourses'], ['Math']);
      expect(jsonEncode(context), isNot(contains('secret-draft')));
      return emptyAdvice();
    });
    await plan(client, state);
  });

  for (final date in [null, DateTime(2026, 11, 14), DateTime(2026, 11, 19)]) {
    test('undated/stale/unrelated course context is excluded: $date', () async {
      final client = clientFor((body) {
        final prefs = body['input']['context']['preferences'];
        expect(prefs['tomorrowCourses'], isEmpty);
        expect(prefs['coursesDate'], isNull);
        return emptyAdvice();
      });
      await plan(client, StudySnapshot(tomorrowSubjects: {'Math'}, coursesDate: date));
    });
  }

  for (final invalid in ['unknownOrder', 'duplicateOrder', 'unknownDependency', 'cycle', 'unknownReason', 'doneOrder', 'exhaustedOrder']) {
    test('rejects invalid advisory graph $invalid', () async {
      final advice = emptyAdvice();
      switch (invalid) {
        case 'unknownOrder': advice['order'] = ['other'];
        case 'duplicateOrder': advice['order'] = ['a', 'a'];
        case 'unknownDependency': advice['dependencies'] = {'a': ['other']};
        case 'cycle': advice['dependencies'] = {'a': ['b'], 'b': ['a']};
        case 'unknownReason': advice['reasons'] = {'other': 'invented'};
        case 'doneOrder': advice['order'] = ['done'];
        case 'exhaustedOrder': advice['order'] = ['exhausted'];
      }
      final client = clientFor((_) => advice);
      await expectLater(plan(client, StudySnapshot(tasks: [localTask('a'), localTask('b'),
        localTask('done', done: true), localTask('exhausted', remainingSeconds: 0)])), responseError);
    });
  }

  test('feedback-grounded review is an optional undated suggestion, not assigned work', () async {
    const feedback = 'Teacher feedback: revisit fraction division.';
    final suggestion = generatedTask()..addAll({
      'kind': 'revision', 'origin': 'suggested', 'dueAt': null, 'dueTimeKnown': false,
      'sourceQuote': feedback, 'evidenceCaptureId': 'feedback',
    });
    final client = clientFor((_) => emptyAdvice()..['suggestions'] = [suggestion]);
    final result = await plan(client, StudySnapshot(evidence: [TextEvidence(
      id: 'feedback', text: feedback, createdAt: DateTime(2026, 11, 14), feedback: true)]));
    expect(result.suggestions.single.kind, TaskKind.review);
    expect(result.suggestions.single.suggested, isTrue);
    expect(result.suggestions.single.done, isFalse);
    expect(result.suggestions.single.due, isNull);
  });

  for (final invalid in ['unknownEvidence', 'unsentEvidence', 'unsentQuoteTail', 'staleCourse', 'deadline', 'assigned']) {
    test('rejects suggestion with $invalid', () async {
      final suggestion = generatedTask()..addAll({'kind': 'revision', 'origin': 'suggested',
        'dueAt': null, 'dueTimeKnown': false, 'evidenceCaptureId': 'unknown'});
      var state = StudySnapshot();
      switch (invalid) {
        case 'unknownEvidence': break;
        case 'unsentEvidence':
          state = StudySnapshot(evidence: List.generate(21, (i) => TextEvidence(
            id: '$i', text: source, createdAt: DateTime(2026, 11, 15, 10, i))));
          suggestion['evidenceCaptureId'] = '0';
        case 'unsentQuoteTail':
          state = StudySnapshot(evidence: [TextEvidence(id: 'tail',
            text: '${List.filled(12000, 'x').join()}$source', createdAt: DateTime(2026, 11, 15))]);
          suggestion['evidenceCaptureId'] = 'tail';
        case 'staleCourse': suggestion.addAll({'evidenceCaptureId': '', 'sourceQuote': '',
          'basis': 'tomorrowCourse', 'basisValue': 'Math'});
          state = StudySnapshot(tomorrowSubjects: {'Math'}, coursesDate: DateTime(2026, 11, 14));
        case 'deadline': suggestion.addAll({'evidenceCaptureId': '', 'sourceQuote': '',
          'basis': 'weakSubject', 'basisValue': 'Math', 'dueAt': '2026-11-16'});
          state = StudySnapshot(tasks: [localTask('weak').copyWith(weak: true)]);
        case 'assigned': suggestion['origin'] = 'assigned';
      }
      final client = clientFor((_) => emptyAdvice()..['suggestions'] = [suggestion]);
      await expectLater(plan(client, state), responseError);
    });
  }

  test('partial completion never creates drafts', () async {
    final client = clientFor((_) => {'tasks': [generatedTask()]}, finish: 'length');
    await expectLater(extract(client), responseError);
  });

  for (final entry in <String, String>{
    'Finish worksheet due 11/16.': '2026-11-16',
    'Finish worksheet due Nov 16, 2026.': '2026-11-16',
    'Finish worksheet due 2026-11-16.': '2026-11-16',
    'Finish worksheet due Monday.': '2026-11-16',
    'Finish worksheet due next Sunday.': '2026-11-22',
    'Finish worksheet due in 2 days.': '2026-11-17',
    'Finish worksheet due the day after tomorrow.': '2026-11-17',
  }.entries) {
    test('date-only grounding: ${entry.key}', () async {
      final value = generatedTask()..addAll({
        'sourceQuote': entry.key, 'dueAt': entry.value, 'dueTimeKnown': false,
      });
      final client = clientFor((_) => {'tasks': [value]});
      final result = (await extract(client, text: entry.key)).single;
      expect(result.due, DateTime.parse(entry.value));
      expect(result.dueTimeKnown, isFalse);
    });
  }

  for (final entry in <String, String>{
    'Questions 11/16 and 12/16.': '2026-11-16',
    'Assigned today, due tomorrow at 17:00.': '2026-11-16T17:00:00',
    'Due tomorrow at 17:00 or 18:00.': '2026-11-16T17:00:00',
    'The worksheet is not due tomorrow.': '2026-11-16',
  }.entries) {
    test('ambiguous or invalid date evidence rejected: ${entry.key}', () async {
      final value = generatedTask()..addAll({
        'sourceQuote': entry.key, 'dueAt': entry.value,
        'dueTimeKnown': entry.value.contains('T'),
      });
      final client = clientFor((_) => {'tasks': [value]});
      await expectLater(extract(client, text: entry.key), responseError);
    });
  }

  for (final basis in ['weakSubject', 'tomorrowCourse']) {
    test('exact $basis supports optional preparation but never a deadline', () async {
      final suggestion = generatedTask()..addAll({
        'kind': 'preparation', 'origin': 'suggested', 'dueAt': null,
        'dueTimeKnown': false, 'sourceQuote': '', 'basis': basis, 'basisValue': 'Math',
      });
      final client = clientFor((_) => emptyAdvice()..['suggestions'] = [suggestion]);
      final advice = await plan(client, StudySnapshot(
        tasks: [localTask('weak').copyWith(weak: true)],
        tomorrowSubjects: {'Math'}, coursesDate: DateTime(2026, 11, 16),
      ));
      expect(advice.suggestions.single.kind, TaskKind.preview);
      expect(advice.suggestions.single.suggested, isTrue);
      expect(advice.suggestions.single.due, isNull);
    });
  }

  test('injected gateway remains usable after client closes', () async {
    final client = clientFor((_) => {'tasks': []});
    client.close();
    expect((await client.gateway.status()).authenticated, isTrue);
  });
}
