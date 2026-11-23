import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/task.dart';

class TaskModelAvailability {
  const TaskModelAvailability(this.available, this.message);
  final bool available;
  final String message;
}

/// Uses the iPhone's Foundation Models framework. Input never leaves the device.
class TaskUnderstanding {
  static const channel = MethodChannel('si.studyorbit/task_understanding');
  static const maxInputLength = 3000;

  Future<TaskModelAvailability> availability() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      return const TaskModelAvailability(
        false,
        'Apple Intelligence task drafting requires a supported iPhone with iOS 26 or later. Basic splitting is available here.',
      );
    }
    try {
      final response = await channel
          .invokeMapMethod<String, dynamic>('availability')
          .timeout(const Duration(seconds: 5));
      return TaskModelAvailability(
        response?['available'] == true,
        response?['message'] as String? ??
            'Apple Intelligence is unavailable. You can use basic splitting.',
      );
    } catch (_) {
      return const TaskModelAvailability(
        false,
        'Apple Intelligence is unavailable in this app version. Update the app, or use basic splitting.',
      );
    }
  }

  Future<List<StudyTask>> understand(
    String source,
    DateTime now, {
    List<StudyTask> savedTasks = const [],
    List<HistoryEntry> history = const [],
  }) async {
    final text = source.trim();
    if (text.isEmpty || text.length > maxInputLength) {
      throw const FormatException('Enter between 1 and 3,000 characters.');
    }
    final active = savedTasks.where((task) => !task.done).toList()
      ..sort((a, b) => a.due.compareTo(b.due));
    final references = active.take(12).toList();
    final recent = history
        .take(6)
        .map(
          (entry) => {
            'date': _dateText(entry.time),
            'event': _excerpt(entry.message, 100),
          },
        )
        .toList();
    final context = {
      'openTasks': [
        for (final (index, task) in references.indexed)
          {
            'reference': index + 1,
            'title': _excerpt(task.title, 80),
            'subject': task.subject,
            'due': _dateText(task.due),
            'kind': task.kind.name,
            'minutesRemaining': task.remaining,
            if (task.weak) 'needsPractice': true,
            if (task.deferredUntil case final start?) 'start': _dateText(start),
          },
      ],
      'needsPractice': savedTasks
          .where((task) => task.weak)
          .map((task) => task.subject)
          .toSet()
          .toList(),
      'recentActivity': recent,
    };
    List<dynamic>? response;
    try {
      response = await channel
          .invokeListMethod<dynamic>('understand', {
            'text': text,
            'referenceDate': _dateText(now),
            if (references.isNotEmpty ||
                recent.isNotEmpty ||
                savedTasks.any((task) => task.weak))
              'context': jsonEncode(context),
          })
          .timeout(const Duration(seconds: 90));
    } on TimeoutException {
      await cancel();
      rethrow;
    }
    if (response == null || response.isEmpty || response.length > 15) {
      throw const FormatException(
        'No task drafts were returned. Try describing your assignments more clearly.',
      );
    }
    // Validate the complete response before displaying any drafts. Do not
    // silently drop an assignment or replace malformed dates with guesses.
    final drafts = [
      for (var i = 0; i < response.length; i++)
        _task(response[i], now, i, references),
    ];
    if (drafts.map((task) => task.id).toSet().length != drafts.length) {
      throw const FormatException(
        'The same task was updated more than once. Please retry.',
      );
    }
    return drafts;
  }

  static String _dateText(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  static String _excerpt(String value, int length) =>
      String.fromCharCodes(value.runes.take(length));

  static DateTime? _parseDate(Object? value) {
    if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      return null;
    }
    final date = DateTime.tryParse(value);
    return date != null &&
            date.year >= 2020 &&
            date.year <= 2100 &&
            _dateText(date) == value
        ? date
        : null;
  }

  StudyTask _task(
    dynamic raw,
    DateTime now,
    int index,
    List<StudyTask> references,
  ) {
    if (raw is! Map) {
      throw const FormatException('Invalid task draft. Please retry.');
    }
    final title = raw['title'];
    final subject = raw['subject'];
    final kind = raw['kind'];
    final minutes = raw['minutes'];
    final steps = raw['steps'];
    final due = _parseDate(raw['dueDate']);
    final startText = raw['startDate'];
    final start = startText == null || startText == ''
        ? null
        : _parseDate(startText);
    final reference = raw['taskReference'] ?? 0;
    final weak = raw['needsPractice'];
    const subjects = {
      'Math',
      'English',
      'Physics',
      'Chemistry',
      'Biology',
      'History',
      'Chinese',
      'Other',
    };
    const kinds = {
      'homework': TaskKind.homework,
      'exam': TaskKind.exam,
      'review': TaskKind.review,
      'preview': TaskKind.preview,
    };
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 200 ||
        !subjects.contains(subject) ||
        !kinds.containsKey(kind) ||
        minutes is! int ||
        minutes < 5 ||
        minutes > 600 ||
        steps is! List ||
        steps.length > 4 ||
        steps.any((s) => s is! String || s.trim().isEmpty || s.length > 200) ||
        due == null ||
        (startText != null &&
            startText != '' &&
            (start == null || start.isAfter(due))) ||
        reference is! int ||
        reference < 0 ||
        reference > references.length ||
        (weak != null && weak is! bool)) {
      throw const FormatException(
        'Apple Intelligence returned an incomplete draft. Please retry or use basic splitting.',
      );
    }
    final existing = reference == 0 ? null : references[reference - 1];
    return StudyTask(
      id: existing?.id ?? '${now.microsecondsSinceEpoch}-ai-$index',
      title: title.trim(),
      subject: subject as String,
      kind: kinds[kind]!,
      due: due,
      minutes: minutes + (existing?.spentSeconds ?? 0) ~/ 60,
      difficulty: existing?.difficulty ?? 2,
      weak: weak as bool? ?? existing?.weak ?? false,
      spentSeconds: existing?.spentSeconds ?? 0,
      deferredUntil: start ?? existing?.deferredUntil,
      steps: List<String>.from(steps),
    );
  }

  Future<Map<String, String>> photoRequest(
    String method,
    String source, {
    String? goal,
  }) async {
    if (!{'classifyPhoto', 'photoGuide'}.contains(method) ||
        source.trim().isEmpty ||
        source.length > maxInputLength) {
      throw const FormatException(
        'Use a readable photo with up to 3,000 characters.',
      );
    }
    if (method == 'photoGuide' &&
        !{'study', 'practice', 'solve'}.contains(goal)) {
      throw const FormatException('Choose study, practice, or solve.');
    }
    final today = DateTime.now();
    final referenceDate =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    try {
      final value = await channel
          .invokeMapMethod<String, dynamic>(method, {
            'text': source.trim(),
            'referenceDate': referenceDate,
            'goal': ?goal,
          })
          .timeout(const Duration(seconds: 90));
      final keys = method == 'classifyPhoto'
          ? ['category', 'subject', 'topic', 'contentType']
          : ['title', 'body'];
      if (value == null ||
          keys.any(
            (key) =>
                value[key] is! String ||
                (value[key] as String).trim().isEmpty ||
                (value[key] as String).length > 12000,
          ) ||
          (method == 'classifyPhoto' &&
              (!{
                    'academic',
                    'nonAcademic',
                    'unclear',
                  }.contains(value['category']) ||
                  !{
                    'notes',
                    'problems',
                    'reading',
                    'exam',
                    'other',
                  }.contains(value['contentType'])))) {
        throw const FormatException(
          'Unable to understand this photo. Please retry.',
        );
      }
      return {for (final key in keys) key: (value[key] as String).trim()};
    } on TimeoutException {
      await cancel();
      rethrow;
    }
  }

  Future<void> cancel() async {
    try {
      await channel
          .invokeMethod<void>('cancel')
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      // Cancelling a dismissed or unavailable platform service is best effort.
    }
  }
}
