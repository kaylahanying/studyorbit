import 'task.dart';

/// Offline draft extraction. Every inferred field must be confirmed by the student.
List<StudyTask> parseDrafts(String input, DateTime now) {
  var draftIndex = 0;
  return input.split(RegExp(r'[\n；;]+')).where((s) => s.trim().isNotEmpty).map((
    line,
  ) {
    final lower = line.toLowerCase();
    var subject = 'Other';
    const aliases = {
      'Math': ['数学', 'math', 'algebra', 'calculus'],
      'English': ['英语', 'english'],
      'Physics': ['物理', 'physics'],
      'Chemistry': ['化学', 'chemistry'],
      'Biology': ['生物', 'biology'],
      'History': ['历史', 'history'],
      'Chinese': ['语文', 'chinese'],
    };
    for (final entry in aliases.entries) {
      if (entry.value.any((s) => lower.contains(s))) {
        subject = entry.key;
        break;
      }
    }
    final duration = RegExp(
      r'(\d+)\s*(?:分钟|mins?\b|minutes?\b)',
      caseSensitive: false,
    ).firstMatch(line);
    DateTime? due;
    if (line.contains('今天') || RegExp(r'\btoday\b').hasMatch(lower)) {
      due = dayOnly(now);
    } else if (line.contains('后天') ||
        RegExp(r'\b(?:the )?day after tomorrow\b').hasMatch(lower)) {
      due = calendarDayAfter(now, 2);
    } else if (line.contains('明天') || RegExp(r'\btomorrow\b').hasMatch(lower)) {
      due = calendarDayAfter(now);
    }
    // A question range such as 1-8 is not a date. Hyphens are accepted only
    // inside a complete ISO date; slash and Chinese dates remain supported.
    final iso = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b').firstMatch(line);
    final date = RegExp(r'(?<![\d/])(\d{1,2})(?:月|/)(\d{1,2})日?(?![\d/])')
        .firstMatch(line);
    if (iso != null || date != null) {
      final year = iso == null ? now.year : int.parse(iso[1]!);
      final month = int.parse(iso == null ? date![1]! : iso[2]!);
      final day = int.parse(iso == null ? date![2]! : iso[3]!);
      final candidate = DateTime(year, month, day);
      if (year >= 1900 && year <= 2200 &&
          candidate.month == month && candidate.day == day) {
        due = candidate;
      }
    }
    var dueTimeKnown = false;
    final time = RegExp(r'\b(\d{1,2}):(\d{2})\s*(am|pm)?\b',
        caseSensitive: false).firstMatch(line);
    if (due != null && time != null) {
      var hour = int.parse(time[1]!);
      final minute = int.parse(time[2]!);
      final period = time[3]?.toLowerCase();
      if (minute <= 59 && (period == null ? hour <= 23 : hour >= 1 && hour <= 12)) {
        if (period != null) hour = hour % 12 + (period == 'pm' ? 12 : 0);
        due = DateTime(due.year, due.month, due.day, hour, minute);
        dueTimeKnown = true;
      }
    }
    final kind =
        line.contains('考试') || RegExp(r'\b(?:exam|test|quiz)\b').hasMatch(lower)
        ? TaskKind.exam
        : line.contains('预习') ||
              RegExp(r'\b(?:preview|prepare|preparation|read ahead)\b')
                  .hasMatch(lower)
        ? TaskKind.preview
        : line.contains('复习') ||
              line.contains('订正') ||
              RegExp(r'\b(?:review|revise|revision|correct|corrections)\b')
                  .hasMatch(lower)
        ? TaskKind.review
        : TaskKind.homework;
    final minutes = duration == null
        ? 30
        : int.parse(duration[1]!).clamp(5, 600);
    return StudyTask(
      id: '${now.microsecondsSinceEpoch}-${draftIndex++}',
      title: line.trim(),
      subject: subject,
      due: due,
      dueTimeKnown: dueTimeKnown,
      sourceQuote: line.trim(),
      minutes: minutes,
      kind: kind,
      steps: minutes >= 60
          ? [
              'Gather instructions and materials',
              'Complete the first part',
              'Finish the remaining work',
              'Check and submit',
            ]
          : [],
    );
  }).toList();
}
