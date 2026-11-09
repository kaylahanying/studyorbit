import 'task.dart';

/// Offline draft extraction. Every inferred field must be confirmed by the student.
List<StudyTask> parseDrafts(String input, DateTime now) {
  var draftIndex = 0;
  return input.split(RegExp(r'[\n；;]+')).where((s) => s.trim().isNotEmpty).map((
    line,
  ) {
    var subject = '其他';
    const aliases = {
      '数学': ['数学', 'math', 'algebra', 'calculus'],
      '英语': ['英语', 'english'],
      '物理': ['物理', 'physics'],
      '化学': ['化学', 'chemistry'],
      '生物': ['生物', 'biology'],
      '历史': ['历史', 'history'],
      '语文': ['语文', 'chinese'],
    };
    for (final entry in aliases.entries) {
      if (entry.value.any((s) => line.toLowerCase().contains(s))) {
        subject = entry.key;
        break;
      }
    }
    final duration = RegExp(
      r'(\d+)\s*(?:分钟|min(?:utes)?)',
      caseSensitive: false,
    ).firstMatch(line);
    var due = dayOnly(now).add(const Duration(days: 1));
    if (line.contains('今天') || line.toLowerCase().contains('today')) {
      due = dayOnly(now);
    }
    if (line.contains('后天')) due = dayOnly(now).add(const Duration(days: 2));
    final date = RegExp(r'(\d{1,2})[月/\-](\d{1,2})日?').firstMatch(line);
    if (date != null) {
      final m = int.parse(date[1]!);
      final d = int.parse(date[2]!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        final candidate = DateTime(now.year, m, d);
        if (candidate.month == m && candidate.day == d) due = candidate;
      }
    }
    final kind = line.contains('考试') || line.toLowerCase().contains('exam')
        ? TaskKind.exam
        : line.contains('预习')
        ? TaskKind.preview
        : line.contains('复习') || line.contains('订正')
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
      steps: minutes >= 60 ? ['整理要求与材料', '完成第一部分', '完成剩余内容', '检查与提交'] : [],
    );
  }).toList();
}
