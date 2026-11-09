import 'dart:async';

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

  Future<List<StudyTask>> understand(String source, DateTime now) async {
    final text = source.trim();
    if (text.isEmpty || text.length > maxInputLength) {
      throw const FormatException('Enter between 1 and 3,000 characters.');
    }
    final date =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    List<dynamic>? response;
    try {
      response = await channel
          .invokeListMethod<dynamic>('understand', {
            'text': text,
            'referenceDate': date,
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
    return [
      for (var i = 0; i < response.length; i++) _task(response[i], now, i),
    ];
  }

  StudyTask _task(dynamic raw, DateTime now, int index) {
    if (raw is! Map) {
      throw const FormatException('Invalid task draft. Please retry.');
    }
    final title = raw['title'];
    final subject = raw['subject'];
    final kind = raw['kind'];
    final minutes = raw['minutes'];
    final steps = raw['steps'];
    final date = raw['dueDate'];
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
        date is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw const FormatException(
        'Apple Intelligence returned an incomplete draft. Please retry or use basic splitting.',
      );
    }
    final due = DateTime.tryParse(date);
    if (due == null ||
        due.year < 2020 ||
        due.year > 2100 ||
        '${due.year.toString().padLeft(4, '0')}-${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')}' !=
            date) {
      throw const FormatException(
        'A draft has an invalid due date. Please retry.',
      );
    }
    return StudyTask(
      id: '${now.microsecondsSinceEpoch}-ai-$index',
      title: title.trim(),
      subject: subject as String,
      kind: kinds[kind]!,
      due: due,
      minutes: minutes,
      steps: List<String>.from(steps),
    );
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
