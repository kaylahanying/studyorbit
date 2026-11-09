import 'task.dart';

class PlanBlock {
  const PlanBlock(
    this.start,
    this.end,
    this.title, {
    this.taskId,
    this.subtitle = '',
    this.part = 1,
  });
  final DateTime start, end;
  final String title, subtitle;
  final String? taskId;
  final int part;
  int get minutes => end.difference(start).inMinutes;
}

class EveningPlan {
  EveningPlan(this.blocks, this.unscheduledMinutes);
  final List<PlanBlock> blocks;
  final Map<String, int> unscheduledMinutes;
}

/// Deterministic, inspectable prioritization. Never extends the evening past 21:00.
class Planner {
  double score(StudyTask t, DateTime day, Set<String> tomorrowSubjects) {
    final days = dayOnly(t.due).difference(dayOnly(day)).inDays;
    return (days < 0
            ? 150
            : days == 0
            ? 120
            : days == 1
            ? 90
            : 60 / (days + 1)) +
        (t.weak ? 25 : 0) +
        t.difficulty * 4 +
        (tomorrowSubjects.contains(t.subject) ? 12 : 0) +
        (t.kind == TaskKind.exam ? 8 : 0) +
        10 / (t.remaining + 1);
  }

  EveningPlan generate(
    List<StudyTask> tasks,
    DateTime day, {
    DateTime? from,
    Set<String> tomorrowSubjects = const {},
  }) {
    final start = DateTime(day.year, day.month, day.day, 16);
    final end = DateTime(day.year, day.month, day.day, 21);
    var cursor = from != null && from.isAfter(start) ? from : start;
    if (cursor.isAfter(end)) cursor = end;
    final eligible =
        tasks
            .where(
              (t) =>
                  !t.done &&
                  t.remaining > 0 &&
                  (t.deferredUntil == null ||
                      !dayOnly(t.deferredUntil!).isAfter(dayOnly(day))),
            )
            .toList()
          ..sort((a, b) {
            final c = score(
              b,
              day,
              tomorrowSubjects,
            ).compareTo(score(a, day, tomorrowSubjects));
            return c != 0 ? c : a.id.compareTo(b.id);
          });
    final remaining = {for (final t in eligible) t.id: t.remaining};
    final blocks = <PlanBlock>[];
    final fixed = [
      PlanBlock(
        DateTime(day.year, day.month, day.day, 18),
        DateTime(day.year, day.month, day.day, 18, 30),
        'Dinner',
        subtitle: 'Put your books away and enjoy your meal',
      ),
      PlanBlock(
        DateTime(day.year, day.month, day.day, 20, 40),
        end,
        'Free time',
        subtitle: 'Wind down at the end of the day',
      ),
    ];
    var studySinceBreak = 0;
    final parts = <String, int>{};
    while (cursor.isBefore(end)) {
      final active = fixed.where(
        (b) => !cursor.isBefore(b.start) && cursor.isBefore(b.end),
      );
      if (active.isNotEmpty) {
        final b = active.first;
        blocks.add(PlanBlock(cursor, b.end, b.title, subtitle: b.subtitle));
        cursor = b.end;
        studySinceBreak = 0;
        continue;
      }
      final nextFixed = fixed.firstWhere(
        (b) => b.start.isAfter(cursor),
        orElse: () => PlanBlock(end, end, ''),
      );
      final available = nextFixed.start.difference(cursor).inMinutes;
      if (available <= 0) break;
      final pending = eligible.where((t) => remaining[t.id]! > 0);
      if (pending.isEmpty) {
        blocks.add(
          PlanBlock(
            cursor,
            nextFixed.start,
            'Independent study / Free time',
            subtitle: 'Your time, your choice',
          ),
        );
        cursor = nextFixed.start;
        continue;
      }
      if (studySinceBreak >= 45) {
        final length = available < 10 ? available : 10;
        final until = cursor.add(Duration(minutes: length));
        blocks.add(
          PlanBlock(
            cursor,
            until,
            'Take a break',
            subtitle: 'Look away, drink water, and stretch',
          ),
        );
        cursor = until;
        studySinceBreak = 0;
        continue;
      }
      final task = pending.first;
      final length = [
        remaining[task.id]!,
        45 - studySinceBreak,
        available,
      ].reduce((a, b) => a < b ? a : b);
      final until = cursor.add(Duration(minutes: length));
      parts[task.id] = (parts[task.id] ?? 0) + 1;
      blocks.add(
        PlanBlock(
          cursor,
          until,
          task.title,
          taskId: task.id,
          part: parts[task.id]!,
          subtitle: '${task.subject} · ${kindName(task.kind)}',
        ),
      );
      remaining[task.id] = remaining[task.id]! - length;
      studySinceBreak += length;
      cursor = until;
    }
    return EveningPlan(
      blocks,
      Map.fromEntries(remaining.entries.where((e) => e.value > 0)),
    );
  }
}
