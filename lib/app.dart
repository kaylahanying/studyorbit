import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import 'domain/task.dart';
import 'domain/planner.dart';
import 'domain/parser.dart';
import 'services/store.dart';
import 'services/media_cleanup.dart';
import 'services/task_understanding.dart';

const ink = Color(0xFF222541),
    muted = Color(0xFF7B7D92),
    violet = Color(0xFF7363D9),
    mint = Color(0xFFCEE9DE),
    canvas = Color(0xFFF7F8FC);
const subjects = [
  'Math',
  'English',
  'Physics',
  'Chemistry',
  'Biology',
  'History',
  'Chinese',
  'Other',
];

const appDisplayName = 'Study Executive Assistant';

class StudyOrbitApp extends StatelessWidget {
  const StudyOrbitApp({super.key, required this.store});
  final StudyStore store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: appDisplayName,
    locale: const Locale('en', 'US'),
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(
        seedColor: violet,
        surface: Colors.white,
      ),
      fontFamily: 'Arial',
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink, fontSize: 14, height: 1.5),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: canvas,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: violet,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    ),
    home: Home(store: store),
  );
}

class Home extends StatefulWidget {
  const Home({super.key, required this.store});
  final StudyStore store;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String filter = 'All';
  DateTime selectedDay = dayOnly(DateTime.now());
  DateTime? planFrom;
  final planner = Planner();
  StudyStore get store => widget.store;
  static const titles = [
    'Today\'s plan',
    'Tasks',
    'Study calendar',
    'My space',
  ];
  @override
  void initState() {
    super.initState();
    store.addListener(_refresh);
  }

  @override
  void dispose() {
    store.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void toast(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> action(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (_) {
      toast(
        'Unable to save. Please try again. ${store.error ?? 'Check your device storage.'}',
      );
    }
  }

  Future<void> capture([int mode = 0]) async {
    final result = await Navigator.of(context).push<List<StudyTask>>(
      MaterialPageRoute(
        builder: (_) =>
            CapturePage(mode: mode, deletePhotos: store.deletePhotos),
      ),
    );
    if (result != null && result.isNotEmpty) {
      await action(() => store.add(result));
    }
  }

  Future<void> edit(StudyTask task) async {
    final edited = await showModalBottomSheet<StudyTask>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TaskEditor(task: StudyTask.fromJson(task.toJson())),
    );
    if (edited != null) {
      await action(() async {
        final i = store.tasks.indexWhere((t) => t.id == task.id);
        store.tasks[i] = edited;
        await store.save('Edited task: ${edited.title}');
      });
    }
  }

  Future<void> focus(StudyTask task, [int? minutes]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FocusPage(task: task, store: store, minutes: minutes),
      ),
    );
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (wide) _sidebar(),
            Expanded(
              child: Column(
                children: [
                  _header(wide),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        wide ? 36 : 20,
                        8,
                        wide ? 36 : 20,
                        100,
                      ),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1120),
                          child: switch (tab) {
                            0 => _today(),
                            1 => _tasks(),
                            2 => _calendar(),
                            _ => _settings(),
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (v) => setState(() => tab = v),
              backgroundColor: Colors.white,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.space_dashboard_outlined),
                  selectedIcon: Icon(Icons.space_dashboard_rounded),
                  label: 'Today',
                ),
                NavigationDestination(
                  icon: Icon(Icons.checklist_rounded),
                  label: 'Tasks',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  label: 'Calendar',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  label: 'My space',
                ),
              ],
            ),
      floatingActionButton: tab == 3
          ? null
          : FloatingActionButton.extended(
              onPressed: () => capture(),
              backgroundColor: ink,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Add study tasks'),
            ),
    );
  }

  Widget _sidebar() => Material(
    color: Colors.white,
    child: SizedBox(
      width: 220,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _brand(),
            const SizedBox(height: 8),
            const Text(
              'Make room for a better day.',
              style: TextStyle(color: muted, fontSize: 11),
            ),
            const SizedBox(height: 48),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  selected: tab == i,
                  selectedTileColor: const Color(0xFFEFEDFB),
                  selectedColor: violet,
                  leading: Icon(
                    [
                      Icons.space_dashboard_outlined,
                      Icons.checklist_rounded,
                      Icons.calendar_month_outlined,
                      Icons.person_outline_rounded,
                    ][i],
                  ),
                  title: Text(
                    titles[i],
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => setState(() => tab = i),
                ),
              ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F6F3),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.spa_outlined, color: Color(0xFF54846F)),
                  SizedBox(height: 12),
                  Text(
                    'Progress at your own pace',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'One small task is one step forward.',
                    style: TextStyle(color: muted, fontSize: 12, height: 1.7),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: mint,
                  child: Icon(Icons.person_outline, color: ink, size: 20),
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text('My study space', style: TextStyle(fontSize: 12)),
                ),
                Icon(Icons.lock_outline, size: 15, color: muted),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  Widget _brand() => const SizedBox(
    width: 170,
    child: Row(
      children: [
        Icon(Icons.blur_circular_rounded, color: violet, size: 30),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            appDisplayName,
            style: TextStyle(
              color: ink,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
        ),
      ],
    ),
  );
  Widget _header(bool wide) => Padding(
    padding: EdgeInsets.symmetric(horizontal: wide ? 36 : 20, vertical: 22),
    child: Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: !wide
                ? _brand()
                : Text(
                    titles[tab],
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const Icon(Icons.calendar_today_outlined, size: 14, color: muted),
              const SizedBox(width: 7),
              Text(
                '${DateTime.now().month}/${DateTime.now().day}',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _today() {
    final now = DateTime.now();
    final plan = planner.generate(
      store.tasks,
      now,
      from: planFrom,
      tomorrowSubjects: store.tomorrowSubjects,
    );
    final pending = store.tasks.where((t) => !t.done).length;
    final finished = store.tasks.where((t) => t.done).length;
    final studyMinutes =
        store.tasks.fold<int>(0, (v, t) => v + t.spentSeconds) ~/ 60;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (store.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              store.error!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        const Text(
          'A little focus. A step forward.',
          style: TextStyle(color: muted, fontSize: 12, letterSpacing: 1),
        ),
        const SizedBox(height: 8),
        const Text(
          'Ready to get into your study rhythm?',
          style: TextStyle(
            color: ink,
            fontSize: 27,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 22),
        _hero(pending),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _stat(
                'To do',
                '$pending',
                'tasks',
                Icons.checklist_rounded,
                const Color(0xFFEFEDFB),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stat(
                'Completed',
                '$finished',
                'tasks',
                Icons.task_alt_rounded,
                const Color(0xFFE6F2EC),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stat(
                'Focus time',
                '$studyMinutes',
                'min',
                Icons.timelapse_rounded,
                const Color(0xFFFFF2DF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          'Plan your tasks. Find your focus.',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _captureCard(
                Icons.camera_alt_outlined,
                'Photo',
                'Scan homework and corrections',
                1,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _captureCard(
                Icons.mic_none_rounded,
                'Voice',
                'Speak your study tasks',
                2,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _captureCard(
                Icons.edit_note_rounded,
                'Text',
                'Write down what you need to do',
                0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        LayoutBuilder(
          builder: (context, c) {
            final timeline = _timeline(plan);
            final prep = _prep();
            return c.maxWidth >= 720
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: timeline),
                      const SizedBox(width: 22),
                      Expanded(flex: 4, child: prep),
                    ],
                  )
                : Column(
                    children: [timeline, const SizedBox(height: 22), prep],
                  );
          },
        ),
      ],
    );
  }

  Widget _hero(int pending) => Container(
    width: double.infinity,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      color: const Color(0xFFECEAF9),
      borderRadius: BorderRadius.circular(26),
    ),
    child: Stack(
      children: [
        Positioned(
          right: -25,
          top: -35,
          bottom: -35,
          width: 240,
          child: CustomPaint(painter: OrbitPainter()),
        ),
        Padding(
          padding: const EdgeInsets.all(26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'YOUR EVENING, IN ORBIT',
                style: TextStyle(
                  color: violet,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Find your rhythm.\nMake room for life.',
                style: TextStyle(
                  fontSize: 28,
                  height: 1.3,
                  color: ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                pending == 0
                    ? 'Start with one small task and plan your evening.'
                    : '$pending tasks ready. Make time for yourself, too.',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () =>
                    pending == 0 ? capture() : setState(() => tab = 1),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: Text(pending == 0 ? 'Plan my evening' : 'View my tasks'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _stat(
    String title,
    String value,
    String unit,
    IconData icon,
    Color color,
  ) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: ink),
        ),
        const SizedBox(height: 12),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            Text(
              value,
              style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
            ),
            Text(unit, style: const TextStyle(fontSize: 10, color: muted)),
          ],
        ),
        Text(title, style: const TextStyle(fontSize: 11, color: muted)),
      ],
    ),
  );
  Widget _captureCard(IconData icon, String title, String sub, int mode) =>
      Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () => capture(mode),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: violet, size: 25),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(sub, style: const TextStyle(fontSize: 10, color: muted)),
              ],
            ),
          ),
        ),
      );
  Widget _timeline(EveningPlan plan) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(
            child: Text(
              'Tonight\'s timeline',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ),
          TextButton.icon(
            onPressed: () {
              setState(() => planFrom = DateTime.now());
              action(() => store.save('Replanned from the current time'));
              toast('Remaining tasks replanned from now');
            },
            icon: const Icon(Icons.auto_awesome_outlined, size: 15),
            label: const Text('Replan', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      const Text(
        '16:00 — 21:00  ·  Make time for breaks',
        style: TextStyle(color: muted, fontSize: 11),
      ),
      const SizedBox(height: 18),
      if (plan.unscheduledMinutes.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF1DC),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            '${plan.unscheduledMinutes.values.fold<int>(0, (a, b) => a + b)} minutes do not fit tonight. Shorten tasks, defer them, or continue tomorrow.',
            style: const TextStyle(fontSize: 12, color: Color(0xFF936128)),
          ),
        ),
      if (store.tasks.isEmpty)
        Container(
          padding: const EdgeInsets.all(20),
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Your evening starts here',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Add tasks to create your schedule, or try three sample tasks first.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              TextButton(
                onPressed: () => action(() => store.sample()),
                child: const Text('Load sample tasks →'),
              ),
            ],
          ),
        ),
      for (final block in plan.blocks) _block(block),
      if (plan.blocks.isEmpty)
        const Text(
          'Today\'s study window has ended. Rest and continue tomorrow.',
          style: TextStyle(color: muted),
        ),
    ],
  );
  Widget _block(PlanBlock b) {
    final task = b.taskId == null
        ? null
        : store.tasks.where((t) => t.id == b.taskId).firstOrNull;
    final color = b.taskId != null
        ? const Color(0xFFEFEDFB)
        : b.title.contains('Dinner')
        ? const Color(0xFFFFF2DF)
        : const Color(0xFFEAF4EF);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 49,
            child: Padding(
              padding: const EdgeInsets.only(top: 17),
              child: Text(
                clockTime(b.start),
                style: const TextStyle(
                  color: muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border(left: BorderSide(color: color, width: 4)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      b.taskId != null
                          ? Icons.menu_book_rounded
                          : b.title.contains('Dinner')
                          ? Icons.restaurant_outlined
                          : Icons.spa_outlined,
                      size: 20,
                      color: b.taskId != null
                          ? violet
                          : const Color(0xFF6B957E),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${b.subtitle} · ${b.minutes} min',
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (task != null)
                    IconButton(
                      tooltip: 'Focus',
                      onPressed: () => focus(task, b.minutes),
                      icon: const Icon(
                        Icons.play_circle_outline,
                        color: violet,
                        size: 26,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _prep() {
    final matching = store.tasks.where(
      (t) =>
          !t.done && (t.kind == TaskKind.preview || t.kind == TaskKind.review),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        const Text(
          'A little preparation for tomorrow',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFFE9F1EC),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.wb_sunny_outlined, color: Color(0xFF54846F)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tomorrow\'s classes',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                'Choose tomorrow\'s subjects to prioritize related tasks.',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final s in subjects.where((s) => s != 'Other'))
                    FilterChip(
                      label: Text(s, style: const TextStyle(fontSize: 11)),
                      selected: store.tomorrowSubjects.contains(s),
                      onSelected: (v) => action(() async {
                        v
                            ? store.tomorrowSubjects.add(s)
                            : store.tomorrowSubjects.remove(s);
                        await store.save();
                      }),
                    ),
                ],
              ),
              const Divider(height: 30),
              const Text(
                'Class checklist',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final s in store.tomorrowSubjects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '○  $s: Review notes, read ahead, and prepare materials',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (store.tomorrowSubjects.isEmpty)
                const Text(
                  'Choose subjects to create your checklist',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              for (final t in matching)
                Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.title, style: const TextStyle(fontSize: 12)),
                    leading: const Icon(
                      Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    onTap: () => edit(t),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.nights_stay_outlined, color: muted, size: 18),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'After 21:00, switch off.\nRest is part of your study plan.',
                  style: TextStyle(color: muted, fontSize: 11, height: 1.8),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tasks() {
    final list =
        store.tasks
            .where(
              (t) =>
                  filter == 'All' ||
                  filter == 'Completed' && t.done ||
                  filter == 'To do' && !t.done ||
                  filter == 'Needs practice' && t.weak,
            )
            .toList()
          ..sort((a, b) => a.due.compareTo(b.due));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Every small task is a step forward.',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const Text(
          'Manage homework, exams, review, and preparation at your own pace.',
          style: TextStyle(color: muted),
        ),
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['All', 'To do', 'Needs practice', 'Completed'])
              ChoiceChip(
                label: Text(f),
                selected: filter == f,
                onSelected: (_) => setState(() => filter = f),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (list.isEmpty)
          _empty('No tasks here', 'Add a task or try another filter.'),
        for (final t in list) _taskCard(t),
      ],
    );
  }

  Widget _taskCard(StudyTask t) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: t.done,
                onChanged: (_) => action(() => store.toggle(t)),
              ),
              Expanded(
                child: InkWell(
                  onTap: () => edit(t),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          decoration: t.done
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${t.subject} · ${kindName(t.kind)} · Due ${t.due.month}/${t.due.day} · ${t.remaining} min left',
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  switch (v) {
                    case 'edit':
                      edit(t);
                    case 'defer':
                      action(() => store.defer(t));
                    case 'delete':
                      _deleteTask(t);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit task')),
                  PopupMenuItem(
                    value: 'defer',
                    child: Text('Defer until tomorrow'),
                  ),
                  PopupMenuItem(value: 'delete', child: Text('Delete task')),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 48),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (t.weak) _pill('Needs practice', const Color(0xFFFFEADB)),
                if (t.deferredUntil != null)
                  _pill(
                    'Deferred until ${t.deferredUntil!.month}/${t.deferredUntil!.day}',
                    const Color(0xFFE9F1EC),
                  ),
                if (!t.done)
                  TextButton.icon(
                    onPressed: () => focus(t),
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                    label: const Text('Focus', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
          if (t.steps.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(48, 4, 8, 10),
              child: Text(
                t.steps
                    .asMap()
                    .entries
                    .map((e) => '${e.key + 1}. ${e.value}')
                    .join('\n'),
                style: const TextStyle(fontSize: 12, height: 1.8, color: muted),
              ),
            ),
        ],
      ),
    ),
  );
  Future<void> _deleteTask(StudyTask t) async {
    final yes = await confirm(
      context,
      'Delete this task?',
      'This will delete ${t.title}. This cannot be undone.',
    );
    if (yes) {
      await action(() async {
        store.tasks.remove(t);
        await store.save('Deleted task: ${t.title}');
      });
    }
  }

  Widget _calendar() {
    final first = DateTime(selectedDay.year, selectedDay.month);
    final days = DateTime(selectedDay.year, selectedDay.month + 1, 0).day;
    final offset = first.weekday - 1;
    final daily = store.tasks
        .where((t) => dayOnly(t.due) == selectedDay)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'See your days ahead.',
          style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 20),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous month',
                      onPressed: () => setState(
                        () => selectedDay = DateTime(
                          selectedDay.year,
                          selectedDay.month - 1,
                        ),
                      ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Center(
                        child: Text(
                          '${selectedDay.month}/${selectedDay.year}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 18,
                          ),
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => selectedDay = dayOnly(DateTime.now())),
                      child: const Text('Today'),
                    ),
                    IconButton(
                      tooltip: 'Next month',
                      onPressed: () => setState(
                        () => selectedDay = DateTime(
                          selectedDay.year,
                          selectedDay.month + 1,
                        ),
                      ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final day in [
                      'Mon',
                      'Tue',
                      'Wed',
                      'Thu',
                      'Fri',
                      'Sat',
                      'Sun',
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            day,
                            maxLines: 1,
                            style: const TextStyle(color: muted, fontSize: 11),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: offset + days,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    mainAxisExtent: 54,
                  ),
                  itemBuilder: (_, i) {
                    if (i < offset) return const SizedBox();
                    final d = DateTime(
                      selectedDay.year,
                      selectedDay.month,
                      i - offset + 1,
                    );
                    final has = store.tasks.any((t) => dayOnly(t.due) == d);
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => setState(() => selectedDay = d),
                      child: Container(
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: selectedDay == d ? violet : null,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${d.day}',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 13,
                                color: selectedDay == d ? Colors.white : ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: has
                                    ? (selectedDay == d ? Colors.white : violet)
                                    : Colors.transparent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        Text(
          '${selectedDay.month}/${selectedDay.day} · Tasks due',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 14),
        if (daily.isEmpty)
          _empty('No tasks due today', 'Leave a little room for yourself.'),
        for (final t in daily) _taskCard(t),
      ],
    );
  }

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Your study space',
        style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text(
        'Your data stays on your device. Your pace stays yours.',
        style: TextStyle(color: muted),
      ),
      const SizedBox(height: 24),
      Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.shield_outlined, color: violet),
              title: Text('Local storage · No account needed'),
              subtitle: Text(
                'Tasks and records stay on this device and are not uploaded.',
              ),
            ),
            SwitchListTile(
              title: const Text('Delete temporary photos after scanning'),
              subtitle: const Text(
                'Only app copies are deleted. Your original photos stay safe.',
              ),
              value: store.deletePhotos,
              onChanged: (v) => action(() async {
                store.deletePhotos = v;
                await store.save();
              }),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Delete retained photo copies'),
              subtitle: const Text(
                'Remove app photo copies without deleting originals from your library.',
              ),
              onTap: () async {
                if (await confirm(
                  context,
                  'Delete temporary photos?',
                  'Photo copies retained by the app will be permanently deleted.',
                )) {
                  await action(() async {
                    await clearRetainedPhotos();
                    toast('Temporary photos deleted');
                  });
                }
              },
            ),
            const ListTile(
              leading: Icon(Icons.mic_none_rounded),
              title: Text('On-device speech recognition only'),
              subtitle: Text(
                'If offline recognition is unavailable, recognition stops without using the cloud.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.notifications_none_rounded),
              title: Text('Focus and break reminders'),
              subtitle: Text(
                'Reminders appear while the focus screen is open. Background notifications are not available.',
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.delete_sweep_outlined),
              title: const Text('Clear study history'),
              subtitle: const Text(
                'Keep tasks and remove activity history and total focus time',
              ),
              onTap: () async {
                if (await confirm(
                  context,
                  'Clear study history?',
                  'Activity history and total focus time will be permanently deleted.',
                )) {
                  await action(() async {
                    store.history.clear();
                    for (final t in store.tasks) {
                      t.spentSeconds = 0;
                    }
                    await store.save();
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Colors.redAccent,
              ),
              title: const Text('Delete all local data'),
              onTap: () async {
                if (await confirm(
                  context,
                  'Delete all data?',
                  'All tasks, study records, and settings will be permanently deleted. This cannot be undone.',
                )) {
                  await action(() => store.clear());
                }
              },
            ),
          ],
        ),
      ),
      const SizedBox(height: 26),
      const Text(
        'Study history',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 12),
      if (store.history.isEmpty)
        _empty(
          'No study history yet',
          'Add a task or start a focus session to see your activity here.',
        ),
      for (final h in store.history.take(100))
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 6),
          leading: const Icon(Icons.history_rounded, color: muted, size: 20),
          title: Text(h.message, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${h.time.month}/${h.time.day} ${clockTime(h.time)}',
            style: const TextStyle(fontSize: 11, color: muted),
          ),
        ),
      const SizedBox(height: 20),
      const Text(
        '$appDisplayName · MVP 1.0\nApple Intelligence drafts tasks on supported iPhones. Scheduling stays local. Subscriptions and encrypted backups are not available yet.',
        style: TextStyle(fontSize: 11, color: muted, height: 1.8),
      ),
    ],
  );
  Widget _empty(String title, String subtitle) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(28),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        const Icon(Icons.blur_circular_rounded, color: violet, size: 35),
        const SizedBox(height: 12),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(color: muted, fontSize: 12)),
      ],
    ),
  );
  Widget _pill(String title, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(title, style: const TextStyle(fontSize: 10, color: ink)),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

class OrbitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * .6, size.height * .5);
    final p = Paint()
      ..color = violet.withValues(alpha: .12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final radius in [65.0, 100.0, 138.0]) {
      canvas.drawCircle(center, radius, p);
    }
    canvas.drawCircle(
      center,
      40,
      Paint()..color = violet.withValues(alpha: .14),
    );
    canvas.drawCircle(
      center,
      27,
      Paint()..color = violet.withValues(alpha: .8),
    );
    for (var i = 0; i < 4; i++) {
      final a = i * 1.8 - .6;
      final r = i.isEven ? 100.0 : 138.0;
      final position = center + Offset(math.cos(a) * r, math.sin(a) * r);
      canvas.drawCircle(
        position,
        i == 1 ? 13 : 7,
        Paint()
          ..color = i.isEven
              ? const Color(0xFFACCDBF)
              : const Color(0xFFC5BCEB),
      );
    }
    final star = Paint()
      ..color = violet.withValues(alpha: .4)
      ..strokeWidth = 2;
    final point = center + const Offset(-92, -67);
    canvas.drawLine(
      point + const Offset(-6, 0),
      point + const Offset(6, 0),
      star,
    );
    canvas.drawLine(
      point + const Offset(0, -6),
      point + const Offset(0, 6),
      star,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class CapturePage extends StatefulWidget {
  const CapturePage({
    super.key,
    required this.mode,
    required this.deletePhotos,
  });
  final int mode;
  final bool deletePhotos;
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  late int mode = widget.mode;
  final input = TextEditingController();
  final captureScroll = ScrollController();
  final taskUnderstanding = TaskUnderstanding();
  TaskModelAvailability? taskModel;
  bool generatingDrafts = false, draftsUseAI = false;
  final speech = const MethodChannel('si.studyorbit/offline_speech');
  bool busy = false, listening = false;
  bool stoppingSpeech = false;
  String speechStatus = '', speechBaseText = '';
  String? speechErrorCode;
  String? error, photoPath;
  Uint8List? photo;
  List<StudyTask>? drafts;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshTaskModel());
    speech.setMethodCallHandler((call) async {
      if (!mounted || !listening) return;
      if (call.method == 'listening') {
        setState(
          () => speechStatus = 'Listening. Speak now, then tap Stop recording.',
        );
      } else if (call.method == 'partialResult' && call.arguments is String) {
        setState(() {
          input.text = _withTranscript(call.arguments as String);
          speechStatus = 'Listening. Your words appear below.';
        });
      }
    });
  }

  Future<void> _refreshTaskModel() async {
    final status = await taskUnderstanding.availability();
    if (mounted) setState(() => taskModel = status);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !busy) {
      unawaited(_refreshTaskModel());
    }
  }

  void _showDraftStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && captureScroll.hasClients) {
        captureScroll.animateTo(
          0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _createDrafts({bool basic = false}) async {
    if (busy) return;
    final text = input.text.trim();
    if (text.isEmpty) {
      fail('Enter your study tasks first.');
      return;
    }
    final useAI = !basic && taskModel?.available == true;
    if (useAI && text.length > TaskUnderstanding.maxInputLength) {
      fail(
        'Describe up to 3,000 characters at a time. Split longer notes into smaller batches.',
      );
      return;
    }
    setState(() {
      busy = true;
      generatingDrafts = true;
      error = null;
      speechErrorCode = null;
    });
    _showDraftStart();
    try {
      final now = DateTime.now();
      final result = useAI
          ? await taskUnderstanding.understand(text, now)
          : parseDrafts(text, now);
      if (mounted) {
        setState(() {
          drafts = result;
          draftsUseAI = useAI;
        });
        _showDraftStart();
      }
    } on PlatformException catch (e) {
      fail(
        e.message ?? 'Apple Intelligence could not draft your tasks. Try again or use basic splitting.',
      );
      await _refreshTaskModel();
    } on TimeoutException {
      fail(
        'Task drafting took too long. Try a shorter description or use basic splitting.',
      );
    } on FormatException catch (e) {
      fail(e.message);
    } catch (_) {
      fail(
        'Unable to draft tasks. Your original text is still here. Try again or use basic splitting.',
      );
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          generatingDrafts = false;
        });
      }
    }
  }

  String _withTranscript(String transcript) =>
      [speechBaseText, transcript.trim()].where((s) => s.isNotEmpty).join('\n');

  Future<void> _cancelSpeech() async {
    try {
      await speech.invokeMethod<void>('cancel');
    } catch (_) {
      // The platform may have already released the speech session.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (generatingDrafts) unawaited(taskUnderstanding.cancel());
    captureScroll.dispose();
    speech.setMethodCallHandler(null);
    if (listening) unawaited(_cancelSpeech());
    input.dispose();
    super.dispose();
  }

  void fail(String message) {
    if (mounted) setState(() => error = message);
  }

  bool get mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  Future<void> scan(ImageSource source) async {
    if (!mobile) {
      fail(
        'Photo scanning requires an Android or iOS phone. Use text input on this platform.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    TextRecognizer? recognizer;
    String? currentPath;
    var understoodPhoto = false;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2400,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      if (picked == null) return;
      currentPath = picked.path;
      await retainLocalPhoto(picked.path);
      final bytes = await picked.readAsBytes();
      recognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(picked.path),
      );
      if (!mounted) return;
      setState(() {
        photo = bytes;
        photoPath = picked.path;
        input.text = recognized.text;
      });
      understoodPhoto = recognized.text.trim().isNotEmpty;
      if (recognized.text.trim().isEmpty) {
        fail('No text found. Try another photo or type your tasks.');
      }
    } catch (_) {
      fail(
        'Unable to scan this photo. Check camera permissions and on-device models, or use text input.',
      );
    } finally {
      await recognizer?.close();
      if (widget.deletePhotos && currentPath != null) {
        try {
          await deleteLocalPhoto(currentPath);
        } catch (_) {
          fail(
            'Unable to delete the temporary photo. Clear app data in your device settings.',
          );
        }
      }
      if (mounted) setState(() => busy = false);
    }
    if (mounted &&
        understoodPhoto &&
        error == null &&
        taskModel?.available == true) {
      await _createDrafts();
    }
  }

  Future<void> dictate() async {
    if (listening) {
      if (stoppingSpeech) return;
      setState(() {
        stoppingSpeech = true;
        speechStatus = 'Finishing transcription…';
      });
      try {
        await speech.invokeMethod<void>('stop');
      } on PlatformException catch (e) {
        fail(e.message ?? 'Unable to stop recording. Please try again.');
        await _cancelSpeech();
      } catch (_) {
        fail('Unable to stop recording. Please try again.');
        await _cancelSpeech();
      }
      return;
    }
    if (!mobile) {
      fail(
        'Voice input requires an Android or iOS phone with on-device speech support. Use text input instead.',
      );
      return;
    }
    setState(() {
      busy = true;
      listening = true;
      stoppingSpeech = false;
      speechBaseText = input.text.trim();
      speechStatus =
          'Preparing voice input. Allow microphone and speech access if asked.';
      speechErrorCode = null;
      error = null;
    });
    var transcribed = false;
    try {
      final result = await speech
          .invokeMethod<String>('recognize', {'locale': 'en-US'})
          .timeout(const Duration(seconds: 75));
      if (mounted && result != null && result.trim().isNotEmpty) {
        setState(() => input.text = _withTranscript(result));
        transcribed = true;
      } else if (mounted &&
          error == null &&
          input.text.trim() == speechBaseText) {
        fail(
          'No speech was recognized. Tap Start voice input and speak clearly.',
        );
      }
    } on PlatformException catch (e) {
      if (mounted) setState(() => speechErrorCode = e.code);
      fail(
        e.message ?? 'On-device speech recognition is unavailable. Use text input instead.',
      );
    } on MissingPluginException {
      fail(
        'Voice input is not connected in this app version. Install the latest TestFlight build.',
      );
    } on TimeoutException {
      await _cancelSpeech();
      fail(
        'Voice input timed out. Check microphone permissions and try again.',
      );
    } catch (_) {
      fail(
        'On-device speech recognition is unavailable. Use text input instead.',
      );
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          listening = false;
          stoppingSpeech = false;
          speechStatus = '';
        });
      }
    }
    if (mounted && transcribed && taskModel?.available == true) {
      await _createDrafts();
    }
  }

  Future<void> editDraft(int index) async {
    final edited = await showModalBottomSheet<StudyTask>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          TaskEditor(task: StudyTask.fromJson(drafts![index].toJson())),
    );
    if (edited != null) setState(() => drafts![index] = edited);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        drafts == null ? 'Add your study tasks' : 'Review your task drafts',
      ),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        controller: captureScroll,
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CAPTURE → CONFIRM → PLAN',
                  style: TextStyle(
                    fontSize: 10,
                    color: violet,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  drafts == null
                      ? 'Write down what you need to do.'
                      : 'Check the details before you start.',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  drafts == null
                      ? 'Add homework, quiz corrections, exams, and preparation together.'
                      : draftsUseAI
                      ? 'Apple Intelligence split your input into task drafts. Review the assignments, due dates, estimated time, and steps before adding them.'
                      : 'Basic drafts use one task per line. Check each subject, date, and duration. Unrecognized dates default to tomorrow and durations to 30 minutes.',
                  style: const TextStyle(color: muted, fontSize: 13),
                ),
                const SizedBox(height: 22),
                if (drafts == null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            generatingDrafts
                                ? 'Understanding and splitting your tasks…'
                                : taskModel?.available == true
                                ? 'Apple Intelligence · On device'
                                : 'Task drafting',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            taskModel?.message ??
                                'Checking Apple Intelligence availability…',
                            style: const TextStyle(fontSize: 12, color: muted),
                          ),
                          if (taskModel?.available == false)
                            TextButton(
                              onPressed: busy ? null : _refreshTaskModel,
                              child: const Text('Check again'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.edit_note),
                        label: Text('Text'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.camera_alt_outlined),
                        label: Text('Photo'),
                      ),
                      ButtonSegment(
                        value: 2,
                        icon: Icon(Icons.mic_none),
                        label: Text('Voice'),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: busy
                        ? null
                        : (v) => setState(() => mode = v.first),
                  ),
                  const SizedBox(height: 20),
                  if (mode == 1) ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => scan(ImageSource.camera),
                            icon: const Icon(Icons.camera_alt_outlined),
                            label: const Text('Take a photo'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => scan(ImageSource.gallery),
                            icon: const Icon(Icons.photo_outlined),
                            label: const Text('Choose from library'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Text recognition runs on your device. Photos are used for this draft and are not uploaded.',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                  if (mode == 2) ...[
                    FilledButton.icon(
                      onPressed: stoppingSpeech || busy && !listening
                          ? null
                          : dictate,
                      icon: Icon(listening ? Icons.stop : Icons.mic_none),
                      label: Text(
                        stoppingSpeech
                            ? 'Finishing…'
                            : listening
                            ? 'Stop recording'
                            : 'Start voice input',
                      ),
                    ),
                    if (listening) ...[
                      const SizedBox(height: 12),
                      Text(speechStatus, semanticsLabel: speechStatus),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                      if (speechErrorCode == 'permission_denied')
                        TextButton(
                          onPressed: () async {
                            try {
                              await speech.invokeMethod<void>('openSettings');
                            } catch (_) {
                              fail(
                                'Open your device Settings and allow Microphone and Speech Recognition for this app.',
                              );
                            }
                          },
                          child: const Text('Open Settings'),
                        ),
                    ],
                    const SizedBox(height: 12),
                    const Text(
                      'An English offline speech model must be installed. If unavailable, the app will let you know and will not use cloud recognition.',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                  if (photo != null) ...[
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.memory(
                        photo!,
                        height: 160,
                        width: double.infinity,
                        fit: BoxFit.contain,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          photo = null;
                          photoPath = null;
                        });
                      },
                      child: const Text('Remove photo preview'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TextField(
                    controller: input,
                    enabled: !busy,
                    minLines: 7,
                    maxLines: 14,
                    decoration: InputDecoration(
                      labelText: 'Study tasks / Recognized text',
                      alignLabelWithHint: true,
                      hintText: taskModel?.available == true
                          ? 'For example: I have math exercises due tomorrow, a physics test on Friday, and an English essay to research and write this week.'
                          : 'One task per line, for example:\nMath exercises due tomorrow, 30 minutes\nPhysics review today, 45 minutes',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    taskModel?.available == true
                        ? 'Describe everything in one go. Apple Intelligence separates assignments and breaks down larger tasks. Voice and photo input are drafted automatically when capture finishes.'
                        : 'Basic splitting: use one task per line, today / tomorrow / the day after tomorrow, month/day, and minutes. Apple Intelligence is needed to understand a paragraph automatically.',
                    style: const TextStyle(
                      color: muted,
                      fontSize: 11,
                      height: 1.7,
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: LinearProgressIndicator(),
                    ),
                ] else ...[
                  if (photo != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.memory(photo!, height: 140),
                    ),
                  for (var i = 0; i < drafts!.length; i++)
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(14),
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFFEFEDFB),
                          child: Text(
                            '${i + 1}',
                            style: const TextStyle(color: violet),
                          ),
                        ),
                        title: Text(drafts![i].title),
                        subtitle: Text(
                          '${drafts![i].subject} · ${kindName(drafts![i].kind)}\nDue ${drafts![i].due.month}/${drafts![i].due.day} · ${drafts![i].minutes} min',
                          style: const TextStyle(fontSize: 12, height: 1.8),
                        ),
                        onTap: () => editDraft(i),
                        trailing: IconButton(
                          tooltip: 'Remove draft',
                          onPressed: () => setState(() => drafts!.removeAt(i)),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => setState(() => drafts = null),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('Edit original text'),
                  ),
                ],
                if (error != null && (mode != 2 || drafts != null))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                if (drafts == null && error != null)
                  TextButton(
                    onPressed: busy ? null : () => _createDrafts(basic: true),
                    child: const Text('Use basic splitting instead'),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy || taskModel == null
                        ? null
                        : () {
                            if (drafts == null) {
                              unawaited(_createDrafts());
                            } else if (drafts!.isEmpty) {
                              fail('Keep at least one task.');
                            } else {
                              Navigator.pop(context, drafts);
                            }
                          },
                    icon: Icon(
                      drafts == null
                          ? Icons.auto_awesome_outlined
                          : Icons.check_rounded,
                    ),
                    label: Text(
                      drafts == null
                          ? 'Create task drafts'
                          : 'Confirm and add ${drafts!.length} ${drafts!.length == 1 ? 'task' : 'tasks'}',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class TaskEditor extends StatefulWidget {
  const TaskEditor({super.key, required this.task});
  final StudyTask task;
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(text: widget.task.title);
  late final minutes = TextEditingController(text: '${widget.task.minutes}');
  late final steps = TextEditingController(text: widget.task.steps.join('\n'));
  late final task = widget.task;
  @override
  void dispose() {
    title.dispose();
    minutes.dispose();
    steps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      24,
      20,
      24,
      MediaQuery.viewInsetsOf(context).bottom + 24,
    ),
    child: SingleChildScrollView(
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Edit study task',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: title,
              decoration: const InputDecoration(labelText: 'Task name'),
              maxLength: 200,
              validator: (s) =>
                  s == null || s.trim().isEmpty ? 'Enter a task name' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: task.subject,
                    decoration: const InputDecoration(labelText: 'Subject'),
                    items: [
                      for (final s in subjects)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (v) => setState(() => task.subject = v!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<TaskKind>(
                    isExpanded: true,
                    initialValue: task.kind,
                    decoration: const InputDecoration(labelText: 'Task type'),
                    items: [
                      for (final k in TaskKind.values)
                        DropdownMenuItem(value: k, child: Text(kindName(k))),
                    ],
                    onChanged: (v) => setState(() => task.kind = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: task.due,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (d != null) setState(() => task.due = d);
                    },
                    icon: const Icon(Icons.calendar_today, size: 15),
                    label: Text(
                      '${task.due.year}/${task.due.month}/${task.due.day}',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Estimated minutes',
                    ),
                    validator: (s) {
                      final n = int.tryParse(s ?? '');
                      return n == null || n < 5 || n > 600
                          ? 'Enter 5–600 minutes'
                          : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Difficulty: ${['Easy', 'Moderate', 'Challenging'][task.difficulty - 1]}',
            ),
            Slider(
              value: task.difficulty.toDouble(),
              min: 1,
              max: 3,
              divisions: 2,
              onChanged: (v) => setState(() => task.difficulty = v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('I need extra practice in this subject'),
              value: task.weak,
              onChanged: (v) => setState(() => task.weak = v),
            ),
            TextFormField(
              controller: steps,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Steps (one per line, optional)',
                hintText:
                    'Gather materials\nComplete exercises\nCheck and correct',
              ),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (form.currentState!.validate()) {
                    task.title = title.text.trim();
                    task.minutes = int.parse(minutes.text);
                    task.steps = steps.text
                        .split('\n')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList();
                    Navigator.pop(context, task);
                  }
                },
                child: const Text('Save changes'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class FocusPage extends StatefulWidget {
  const FocusPage({
    super.key,
    required this.task,
    required this.store,
    this.minutes,
  });
  final StudyTask task;
  final StudyStore store;
  final int? minutes;
  @override
  State<FocusPage> createState() => _FocusPageState();
}

class _FocusPageState extends State<FocusPage> with WidgetsBindingObserver {
  Timer? timer;
  DateTime? started;
  int accumulated = 0, recorded = 0;
  bool running = false, breakMode = false, saving = false;
  late final int targetSeconds =
      math.min(widget.minutes ?? 25, math.max(1, widget.task.remaining)) * 60;
  final checked = <int>{};
  int get elapsed =>
      accumulated +
      (running && started != null
          ? DateTime.now().difference(started!).inSeconds
          : 0);
  int get target => breakMode ? 5 * 60 : targetSeconds;
  int get left => (target - elapsed).clamp(0, target);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (running && left == 0) {
        pause();
        SystemSound.play(SystemSoundType.alert);
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(
              breakMode ? 'Break finished' : 'Focus session finished',
            ),
            content: Text(
              breakMode ? 'Return to your study plan when you are ready.' : 'Look away, drink some water, and take a five-minute break.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ],
          ),
        );
      }
      setState(() {});
    });
  }

  void pause() {
    if (running) {
      accumulated = elapsed;
      running = false;
      started = null;
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      pause();
      persist();
    }
  }

  Future<void> persist() async {
    if (breakMode) return;
    final delta = elapsed - recorded;
    if (delta <= 0) return;
    recorded += delta;
    widget.task.spentSeconds += delta;
    try {
      await widget.store.save(
        'Focused for ${delta ~/ 60} min ${delta % 60} sec: ${widget.task.title}',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Unable to save your study record. Check device storage.',
            ),
          ),
        );
      }
    }
  }

  Future<void> leave() async {
    if (saving) return;
    setState(() => saving = true);
    pause();
    await persist();
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && !saving) leave();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Save and go back',
          onPressed: saving ? null : leave,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Focus mode'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  Text(
                    breakMode ? 'Give your mind a break' : 'One task at a time',
                    style: const TextStyle(color: muted, letterSpacing: 1),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    widget.task.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${widget.task.subject} · ${kindName(widget.task.kind)}',
                    style: const TextStyle(color: muted),
                  ),
                  const SizedBox(height: 36),
                  SizedBox(
                    width: 250,
                    height: 250,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: left / target,
                            strokeWidth: 8,
                            backgroundColor: const Color(0xFFE7E4F6),
                            color: breakMode ? const Color(0xFF79A68D) : violet,
                            strokeCap: StrokeCap.round,
                          ),
                        ),
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${(left ~/ 60).toString().padLeft(2, '0')}:${(left % 60).toString().padLeft(2, '0')}',
                              style: const TextStyle(
                                fontSize: 57,
                                fontWeight: FontWeight.w300,
                                color: ink,
                              ),
                            ),
                            Text(
                              breakMode
                                  ? 'Break time'
                                  : running
                                  ? 'Getting closer to your goal'
                                  : 'Start when you are ready',
                              style: const TextStyle(
                                color: muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 35),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        onPressed: saving || left == 0
                            ? null
                            : () {
                                if (running) {
                                  pause();
                                  persist();
                                } else {
                                  setState(() {
                                    running = true;
                                    started = DateTime.now();
                                  });
                                }
                              },
                        icon: Icon(
                          running
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(running ? 'Pause' : 'Start'),
                      ),
                      OutlinedButton(
                        onPressed: saving
                            ? null
                            : () async {
                                pause();
                                await persist();
                                setState(() {
                                  breakMode = !breakMode;
                                  accumulated = 0;
                                  recorded = 0;
                                });
                              },
                        child: Text(
                          breakMode
                              ? 'Back to studying'
                              : 'Take a 5-minute break',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  for (var i = 0; i < widget.task.steps.length; i++)
                    CheckboxListTile(
                      value: checked.contains(i),
                      onChanged: (v) => setState(() {
                        v == true ? checked.add(i) : checked.remove(i);
                      }),
                      title: Text(
                        widget.task.steps[i],
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: const Text(
                        'Session checklist',
                        style: TextStyle(fontSize: 10, color: muted),
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  const SizedBox(height: 20),
                  TextButton.icon(
                    onPressed: saving || widget.task.done
                        ? null
                        : () async {
                            setState(() => saving = true);
                            pause();
                            await persist();
                            try {
                              await widget.store.toggle(widget.task);
                              if (mounted) Navigator.pop(this.context);
                            } catch (_) {
                              if (mounted) {
                                setState(() => saving = false);
                                ScaffoldMessenger.of(this.context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Unable to save. Please try again. ',
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Mark task complete'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Sessions pause when you leave the app. Reminders work while this screen is open.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
