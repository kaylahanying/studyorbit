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
    var due = dayOnly(now).add(const Duration(days: 1));
    if (line.contains('今天') || RegExp(r'\btoday\b').hasMatch(lower)) {
      due = dayOnly(now);
    }
    if (lower.contains('tomorrow')) {
      due = dayOnly(now).add(const Duration(days: 1));
    }
    if (line.contains('后天') ||
        RegExp(r'\b(?:the )?day after tomorrow\b').hasMatch(lower)) {
      due = dayOnly(now).add(const Duration(days: 2));
    }
    final date = RegExp(r'(\d{1,2})[月/\-](\d{1,2})日?').firstMatch(line);
    if (date != null) {
      final m = int.parse(date[1]!);
      final d = int.parse(date[2]!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        final candidate = DateTime(now.year, m, d);
        if (candidate.month == m && candidate.day == d) due = candidate;
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
