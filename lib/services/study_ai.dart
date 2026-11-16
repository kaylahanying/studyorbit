import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../domain/task.dart';
import '../domain/study_state.dart';
import 'hosted_ai.dart';

class AiException implements Exception {
  const AiException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Text-only hosted operations. All generated tasks still require local review.
class StudyAiClient {
  StudyAiClient({HostedAiGateway? gateway})
    : gateway = gateway ?? HostedAiGateway(), _ownsGateway = gateway == null;
  final HostedAiGateway gateway;
  final bool _ownsGateway;
  bool _closed = false;
  static final _random = Random.secure();

  Future<List<StudyTask>> extractTasks({
    required String text,
    required String captureId,
    required DateTime now,
    required StudySnapshot context,
    required bool consent,
  }) async {
    _authorize(consent);
    if (text.trim().isEmpty || text.length > 100000 ||
        captureId.isEmpty || captureId.length > 200) {
      _fail('input', 'Provide text of at most 100,000 characters and a valid capture identifier.');
    }
    final wire = _context(context, now, now);
    final response = await _request('extract', {
      'now': now.toIso8601String(), 'captureId': captureId,
      'sourceText': text, 'context': wire,
    });
    _keys(response, {'tasks'});
    return List.unmodifiable(_list(response['tasks'], 30).map((value) => _task(
      _object(value), now: now, sourceText: text, captureId: captureId,
      wireContext: wire, suggestionOnly: false,
    )));
  }

  Future<PlanAdvice> advisePlan({
    required StudySnapshot context,
    required DateTime day,
    required DateTime now,
    required bool consent,
  }) async {
    _authorize(consent);
    final selected = _dateOnly(day);
    if (selected.isBefore(_dateOnly(now)) ||
        selected.isAfter(DateTime(now.year, now.month, now.day + 30))) {
      _fail('input', 'AI planning is available for today and the next 30 days only.');
    }
    final eligible = context.tasks.where((task) => !task.done &&
      task.remainingSeconds > 0 && (task.deferredUntil == null ||
        !_dateOnly(task.deferredUntil!).isAfter(selected))).toList();
    if (eligible.length > 200) {
      _fail('context', 'More than 200 tasks are eligible. Review old work before requesting AI planning.');
    }
    final wire = _context(context, now, selected);
    final response = await _request('plan', {
      'now': now.toIso8601String(), 'day': _dateKey(selected),
      'eligibleTaskIds': eligible.map((task) => task.id).toList(),
      'context': wire,
    });
    _keys(response, {'order', 'dependencies', 'reasons', 'suggestions'});
    final known = eligible.map((task) => task.id).toSet();
    final order = _list(response['order'], 200)
      .map((value) => _string(value, 200)).toList();
    if (order.toSet().length != order.length || order.any((id) => !known.contains(id))) {
      _fail('response', 'The provider returned duplicate or unknown task identifiers. No advice was applied.');
    }
    final dependencies = <String, List<String>>{};
    final rawDependencies = _object(response['dependencies']);
    if (rawDependencies.length > 200) _fail('response', 'Too many dependency records.');
    for (final entry in rawDependencies.entries) {
      final values = _list(entry.value, 200).map((value) => _string(value, 200)).toList();
      if (!known.contains(entry.key) || values.any((id) => !known.contains(id) || id == entry.key) ||
          values.toSet().length != values.length) {
        _fail('response', 'The provider returned an invalid task dependency.');
      }
      dependencies[entry.key] = values;
    }
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) _fail('response', 'The provider returned circular dependencies. No advice was applied.');
      for (final dependency in dependencies[id] ?? <String>[]) { visit(dependency); }
      visiting.remove(id);
      visited.add(id);
    }
    for (final id in known) { visit(id); }
    final rawReasons = _object(response['reasons']);
    if (rawReasons.length > 200) _fail('response', 'Too many task explanations.');
    final reasons = <String, String>{};
    for (final entry in rawReasons.entries) {
      if (!known.contains(entry.key)) _fail('response', 'The provider explained an unknown task.');
      reasons[entry.key] = _string(entry.value, 1000);
    }
    return PlanAdvice(
      order: order, dependencies: dependencies, reasons: reasons,
      suggestions: _list(response['suggestions'], 12).map((value) => _task(
        _object(value), now: now, wireContext: wire, suggestionOnly: true,
      )).toList(),
    );
  }

  void _authorize(bool consent) {
    if (_closed) _fail('closed', 'The AI client is closed.');
    if (!consent) _fail('consent', 'Allow text-only AI processing before contacting the hosted provider. Photos and audio are never sent.');
  }

  Future<Map<String, dynamic>> _request(String operation, Map<String, dynamic> input) async {
    try {
      final envelope = await gateway.send(operation, input, consent: true)
        .timeout(const Duration(seconds: 45));
      final choices = _list(envelope['choices'], 8);
      if (choices.isEmpty) _fail('response', 'The provider returned no completion.');
      final choice = _object(choices.first);
      final message = _object(choice['message']);
      if (choice['finish_reason'] != 'stop' || message['refusal'] != null) {
        _fail('response', 'The provider did not complete a safe structured response. No drafts or advice were applied.');
      }
      final content = _string(message['content'], 180000);
      _checkDepth(content);
      return _object(jsonDecode(content));
    } on AiException { rethrow;
    } on HostedAiException catch (error) { _fail(error.code, error.message);
    } on TimeoutException { _fail('timeout', 'The study provider timed out. No drafts or advice were applied.');
    } on FormatException { _fail('response', 'The provider returned malformed JSON. No drafts or advice were applied.');
    } catch (_) { _fail('network', 'The hosted study request failed. No drafts or advice were applied.'); }
  }

  Map<String, dynamic> _context(StudySnapshot state, DateTime now, DateTime day) {
    if (state.tasks.length > 1000) _fail('context', 'The confirmed-task context exceeds 1,000 records. Review old work before requesting AI.');
    final ids = state.tasks.map((task) => task.id).toSet();
    if (ids.length != state.tasks.length) _fail('context', 'Confirmed tasks must have unique identifiers.');
    final evidence = state.evidence.where((item) => item.text.trim().isNotEmpty &&
      !item.createdAt.isAfter(now)).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final history = state.history.where((item) => !item.time.isAfter(now)).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    final focus = state.focusRecords.where((item) => !item.endedAt.isAfter(now)).toList()
      ..sort((a, b) => b.endedAt.compareTo(a.endedAt));
    final coursesDate = state.coursesDate;
    final relevantCourses = coursesDate != null &&
      (_sameDay(coursesDate, day) || _sameDay(coursesDate, DateTime(day.year, day.month, day.day + 1))) &&
      !_dateOnly(coursesDate).isBefore(_dateOnly(now));
    return {
      'preferences': {
        'energy': 'steady', 'focusMinutes': 45, 'breakMinutes': 10,
        'mealStartMinute': 1080, 'mealMinutes': 30, 'leisureMinutes': 20,
        'weakSubjects': state.tasks.where((task) => task.weak).map((task) => task.subject).toSet().toList(),
        'weakTopics': <String>[],
        'tomorrowCourses': relevantCourses ? state.tomorrowSubjects.toList() : <String>[],
        'coursesDate': relevantCourses ? _dateKey(coursesDate) : null,
      },
      'confirmedTasks': state.tasks.map((task) => {
        'id': task.id, 'title': task.title, 'subject': task.subject,
        'kind': _wireKind(task.kind),
        'stage': task.done ? 'done' : task.deferredUntil == null ? 'ready' : 'deferred',
        'minutes': task.remaining, 'remainingSeconds': task.remainingSeconds,
        'spentSeconds': task.spentSeconds, 'difficulty': task.difficulty, 'weak': task.weak,
        'dueAt': task.due == null ? null : task.dueTimeKnown ? task.due!.toIso8601String() : _dateKey(task.due!),
        'dueTimeKnown': task.dueTimeKnown, 'deferUntil': task.deferredUntil?.toIso8601String(),
        'sourceCaptureId': task.sourceCaptureId, 'sourceQuote': task.sourceQuote, 'reason': task.reason,
        'steps': task.steps.asMap().entries.map((entry) => {
          'id': '${task.id}-step-${entry.key}', 'title': entry.value,
        }).toList(),
      }).toList(),
      'recentHistory': history.take(100).toList().asMap().entries.map((entry) => {
        'id': 'history-${entry.key}-${entry.value.time.microsecondsSinceEpoch}',
        'kind': 'localActivity', 'summary': entry.value.message,
        'occurredAt': entry.value.time.toIso8601String(), 'taskId': null,
      }).toList(),
      'recentFocusRecords': focus.take(100).map((record) => {
        'id': record.id, 'taskId': record.taskId, 'taskTitle': record.taskTitle,
        'subject': record.subject, 'startedAt': record.startedAt.toIso8601String(),
        'endedAt': record.endedAt.toIso8601String(), 'focusedSeconds': record.focusedSeconds,
      }).toList(),
      'recentTextEvidence': evidence.take(20).map((item) => {
        'id': item.id, 'createdAt': item.createdAt.toIso8601String(),
        'text': item.text.length <= 12000 ? item.text : item.text.substring(0, 12000),
        'truncated': item.text.length > 12000, 'feedback': item.feedback,
      }).toList(),
      'contextLimits': {
        'historyIncluded': history.length.clamp(0, 100), 'historyTotal': history.length,
        'capturesIncluded': evidence.length.clamp(0, 20), 'capturesTotal': evidence.length,
        'focusIncluded': focus.length.clamp(0, 100), 'focusTotal': focus.length,
      },
    };
  }

  StudyTask _task(Map<String, dynamic> value, {
    required DateTime now, required Map<String, dynamic> wireContext,
    required bool suggestionOnly, String? sourceText, String captureId = '',
  }) {
    _keys(value, {'title', 'subject', 'kind', 'origin', 'minutes', 'difficulty',
      'dueAt', 'dueTimeKnown', 'sourceQuote', 'reason', 'steps', 'evidenceCaptureId', 'basis', 'basisValue'});
    final title = _string(value['title'], 240);
    final subject = _string(value['subject'], 120);
    final kind = switch (_string(value['kind'], 30)) {
      'homework' => TaskKind.homework, 'exam' => TaskKind.exam,
      'revision' => TaskKind.review, 'preparation' => TaskKind.preview,
      _ => _fail('response', 'The provider returned an unsupported task kind.'),
    };
    final origin = _string(value['origin'], 20);
    if (origin != 'assigned' && origin != 'suggested') _fail('response', 'Assigned work and suggestions must be distinguished.');
    if ((suggestionOnly || origin == 'suggested') &&
        (origin != 'suggested' || (kind != TaskKind.review && kind != TaskKind.preview))) {
      _fail('response', 'Suggested work must be review or preparation, never a fabricated assignment.');
    }
    final quote = _string(value['sourceQuote'], 4000, allowEmpty: true);
    final citedId = _string(value['evidenceCaptureId'], 200, allowEmpty: true);
    final basis = _string(value['basis'], 40, allowEmpty: true);
    final basisValue = _string(value['basisValue'], 240, allowEmpty: true);
    if (suggestionOnly) {
      captureId = citedId;
      if (citedId.isNotEmpty) {
        final evidence = (wireContext['recentTextEvidence'] as List).cast<Map<String, dynamic>>()
          .where((item) => item['id'] == citedId);
        if (evidence.length != 1 || basis.isNotEmpty || basisValue.isNotEmpty) {
          _fail('response', 'A suggestion cited unknown or unsent evidence.');
        }
        sourceText = evidence.single['text'] as String;
      } else {
        final prefs = wireContext['preferences'] as Map<String, dynamic>;
        final values = switch (basis) {
          'weakTopic' => prefs['weakTopics'] as List,
          'weakSubject' => prefs['weakSubjects'] as List,
          'tomorrowCourse' => prefs['tomorrowCourses'] as List,
          _ => <dynamic>[],
        };
        if (!values.contains(basisValue) || quote.isNotEmpty) {
          _fail('response', 'The suggestion is not grounded in shared feedback, weak subjects, or dated courses.');
        }
      }
    } else if (citedId.isNotEmpty || basis.isNotEmpty || basisValue.isNotEmpty) {
      _fail('response', 'Extraction must cite only the current source.');
    }
    if (sourceText != null && (quote.isEmpty || !sourceText.contains(quote))) {
      _fail('response', 'A task quote was not found verbatim in its shared source. No drafts were applied.');
    }
    final minutes = _integer(value['minutes'], 5, 240);
    final difficulty = _integer(value['difficulty'], 1, 3);
    if (value['dueTimeKnown'] is! bool) _fail('response', 'The provider omitted deadline precision.');
    final knownTime = value['dueTimeKnown'] as bool;
    DateTime? due;
    if (value['dueAt'] != null) {
      final raw = _string(value['dueAt'], 40);
      due = DateTime.tryParse(raw);
      if (due == null || due.year < 2000 || due.year > 2100 ||
          !_validLocalDate(raw) || sourceText == null ||
          !_supportsDate(quote, due, now) || (knownTime && (!raw.contains('T') || !_supportsTime(quote, due))) ||
          (!knownTime && (due.hour != 0 || due.minute != 0 || due.second != 0))) {
        _fail('response', 'A proposed deadline is not supported by the quoted source. Keep unknown dates empty.');
      }
      if (!knownTime) due = _dateOnly(due);
    } else if (knownTime) { _fail('response', 'A known deadline time needs a supported date.'); }
    if (origin == 'suggested' && due != null) _fail('response', 'Suggested work cannot invent an assignment deadline.');
    final reason = _string(value['reason'], 1000);
    final steps = _list(value['steps'], 12).map((item) => _string(item, 240)).toList();
    return StudyTask(
      id: _id(), title: title, subject: subject, kind: kind, due: due,
      minutes: minutes, remainingSeconds: minutes * 60, difficulty: difficulty,
      sourceCaptureId: captureId, sourceQuote: quote, dueTimeKnown: knownTime,
      suggested: origin == 'suggested',
      reason: origin == 'suggested' ? 'Suggested work · $reason' : 'Assigned work · source review required: $reason',
      steps: steps,
    );
  }

  static String _wireKind(TaskKind kind) => switch (kind) {
    TaskKind.review => 'revision', TaskKind.preview => 'preparation',
    TaskKind.homework => 'homework', TaskKind.exam => 'exam',
  };
  static DateTime _dateOnly(DateTime value) => DateTime(value.year, value.month, value.day);
  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;
  static String _dateKey(DateTime value) => '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  static bool _validLocalDate(String raw) {
    final match = RegExp(r'^(20\d{2})-(\d{2})-(\d{2})(?:T([01]\d|2[0-3]):([0-5]\d)(?::([0-5]\d)(?:\.0{1,6})?)?)?$').firstMatch(raw);
    if (match == null) return false;
    final date = DateTime(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
    return date.year == int.parse(match[1]!) && date.month == int.parse(match[2]!) && date.day == int.parse(match[3]!);
  }

  bool _supportsDate(String quote, DateTime due, DateTime now) {
    final q = quote.toLowerCase();
    if (RegExp(r'\bnot\s+due\b|\bno\s+deadline\b|\b(?:date|deadline)\s*(?:is|:)?\s*(?:unknown|tbd|unspecified)\b').hasMatch(q)) {
      return false;
    }
    final candidates = <String>{};
    void add(int year, int month, int day) {
      final value = DateTime(year, month, day);
      if (value.year == year && value.month == month && value.day == day) {
        candidates.add(_dateKey(value));
      }
    }
    // Remove explicit-year dates before looking for shorter MM/DD expressions.
    final withoutYearDates = q.replaceAllMapped(RegExp(
      r'\b(20\d{2})[-/](\d{1,2})[-/](\d{1,2})\b|(?<!\d)(20\d{2})年(\d{1,2})月(\d{1,2})日?',
    ), (m) {
      final offset = m[1] == null ? 3 : 0;
      add(int.parse(m[1 + offset]!), int.parse(m[2 + offset]!), int.parse(m[3 + offset]!));
      return '';
    });
    for (final m in RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(20\d{2}))?\b').allMatches(withoutYearDates)) {
      final prefix = withoutYearDates.substring(0, m.start);
      // Bare exercise/page fractions are not dates. Require a deadline/date cue.
      if (!RegExp(r'(?:\bdue|\bdeadline|\bby|\bbefore|\bon|\bdate)\s*(?:on|is|:)?\s*$').hasMatch(prefix)) continue;
      add(m[3] == null ? now.year : int.parse(m[3]!), int.parse(m[1]!), int.parse(m[2]!));
    }
    const months = ['january', 'february', 'march', 'april', 'may', 'june',
      'july', 'august', 'september', 'october', 'november', 'december'];
    for (var i = 0; i < months.length; i++) {
      final name = '(?:${months[i]}|${months[i].substring(0, 3)})\\.?';
      for (final m in RegExp(
        '\\b(?:$name\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(\\d{4}))?'
        '|(\\d{1,2})(?:st|nd|rd|th)?\\s+$name(?:,?\\s+(\\d{4}))?)\\b',
      ).allMatches(q)) {
        add(int.parse(m[2] ?? m[4] ?? '${now.year}'), i + 1, int.parse(m[1] ?? m[3]!));
      }
    }
    if (RegExp(r'\b(?:today|tonight)\b').hasMatch(q) || q.contains('今天')) candidates.add(_dateKey(now));
    final relative = q.replaceAllMapped(RegExp(r'\b(?:the\s+)?day after tomorrow\b|后天'), (_) {
      candidates.add(_dateKey(DateTime(now.year, now.month, now.day + 2)));
      return '';
    });
    if (RegExp(r'\btomorrow\b').hasMatch(relative) || relative.contains('明天')) {
      candidates.add(_dateKey(DateTime(now.year, now.month, now.day + 1)));
    }
    for (final m in RegExp(r'\bin (\d{1,2}) days?\b').allMatches(q)) {
      candidates.add(_dateKey(DateTime(now.year, now.month, now.day + int.parse(m[1]!))));
    }
    const weekdays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    for (var i = 0; i < weekdays.length; i++) {
      for (final m in RegExp('\\b(next\\s+)?${weekdays[i]}\\b').allMatches(q)) {
        var delta = (i + 1 - now.weekday + 7) % 7;
        if (m[1] != null && delta == 0) delta = 7;
        candidates.add(_dateKey(DateTime(now.year, now.month, now.day + delta)));
      }
    }
    // A broad quote with conflicting dates cannot verify one chosen deadline.
    return candidates.length == 1 && candidates.single == _dateKey(due);
  }

  bool _supportsTime(String quote, DateTime due) {
    final clocks = <int>{};
    for (final m in RegExp(
      r'\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b([01]?\d|2[0-3]):([0-5]\d)\b',
    ).allMatches(quote.toLowerCase())) {
      var hour = int.parse(m[1] ?? m[4]!);
      final minute = int.parse(m[2] ?? m[5] ?? '0');
      if (minute > 59) continue;
      if (m[3] != null) {
        if (hour < 1 || hour > 12) continue;
        hour = hour % 12 + (m[3] == 'pm' ? 12 : 0);
      }
      clocks.add(hour * 60 + minute);
    }
    return clocks.length == 1 && clocks.single == due.hour * 60 + due.minute &&
      due.second == 0 && due.millisecond == 0 && due.microsecond == 0;
  }


  void close() {
    _closed = true;
    if (_ownsGateway) gateway.close();
  }

  static String _id() =>
      'ai-${DateTime.now().microsecondsSinceEpoch}-${List.generate(12, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  static Never _fail(String code, String message) =>
      throw AiException(code, message);
  static Map<String, dynamic> _object(dynamic value) {
    if (value is! Map<String, dynamic>) {
      _fail('response', 'The provider returned a non-object structured value.');
    }
    return value;
  }

  static List<dynamic> _list(dynamic value, int max) {
    if (value is! List || value.length > max) {
      _fail(
        'response',
        'The provider returned an invalid or oversized collection.',
      );
    }
    return value;
  }

  static String _string(dynamic value, int max, {bool allowEmpty = false}) {
    if (value is! String ||
        value.length > max ||
        (!allowEmpty && value.trim().isEmpty)) {
      _fail('response', 'The provider returned missing or oversized text.');
    }
    return value;
  }

  static int _integer(dynamic value, int min, int max) {
    if (value is! int || value < min || value > max) {
      _fail(
        'response',
        'The provider returned an out-of-bounds task estimate.',
      );
    }
    return value;
  }

  static void _keys(Map<String, dynamic> value, Set<String> allowed) {
    if (value.length != allowed.length || allowed.any((key) => !value.containsKey(key))) {
      _fail('response', 'The provider returned unsupported structured fields.');
    }
  }

  static void _checkDepth(String text) {
    var depth = 0;
    var quoted = false;
    var escaped = false;
    for (final c in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (c == 92) {
          escaped = true;
        } else if (c == 34) {
          quoted = false;
        }
      } else if (c == 34) {
        quoted = true;
      } else if (c == 123 || c == 91) {
        if (++depth > 32) {
          _fail('response', 'Provider JSON is nested too deeply.');
        }
      } else if (c == 125 || c == 93) {
        depth--;
      }
    }
  }

}
