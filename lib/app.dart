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
import 'domain/study_state.dart';
import 'services/study_controller.dart';
import 'services/media_cleanup.dart';
import 'services/hosted_ai.dart';
import 'services/study_ai.dart';
import 'data/backup_codec.dart';
import 'package:file_selector/file_selector.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

part 'ui/capture_page.dart';
part 'ui/task_editor.dart';
part 'ui/focus_page.dart';
part 'ui/hosted_controls.dart';
part 'ui/backup_controls.dart';

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
  final StudyController store;
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
      fontFamilyFallback: const ['NotoSansSC'],
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
  final StudyController store;
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  String filter = 'All';
  DateTime selectedDay = dayOnly(DateTime.now());
  DateTime? selectedPlanDay;
  DateTime get planDay {
    final now = DateTime.now();
    final selected = selectedPlanDay;
    if (selected != null && !selected.isBefore(dayOnly(now))) return selected;
    return now.hour >= 21
        ? DateTime(now.year, now.month, now.day + 1) : dayOnly(now);
  }
  bool planning = false;
  bool localPlan = false;
  StudyController get store => widget.store;
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
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CapturePage(
          mode: mode, deletePhotos: store.deletePhotos, store: store,
        ),
      ),
    );
  }

  Future<void> edit(StudyTask task) async {
    final edited = await showModalBottomSheet<StudyTask>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TaskEditor(task: task),
    );
    if (edited != null) {
      await action(() => store.saveTask(edited));
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
  Future<void> _planWithAi({bool replan = false}) async {
    if (planning) return;
    setState(() => planning = true);
    final client = StudyAiClient(gateway: store.gateway);
    final day = planDay;
    try {
      final snapshot = store.snapshot;
      if (!await approveAiRequest(context, store.gateway, snapshot,
          operation: replan ? 'replanning' : 'planning', day: day)) {
        return;
      }
      final now = DateTime.now();
      final advice = await client.advisePlan(context: snapshot, day: day, now: now, consent: true);
      await store.applyAdvice(day, advice);
      if (mounted) {
        setState(() {
          localPlan = false;
        });
      }
    } catch (e) {
      toast('AI planning failed. Your existing plan is unchanged. $e');
    } finally {
      client.close();
      if (mounted) setState(() => planning = false);
    }
  }

  Future<void> _choosePlanDay() async {
    if (planning) return;
    final now = DateTime.now();
    final date = await showDatePicker(context: context, initialDate: planDay,
        firstDate: dayOnly(now), lastDate: DateTime(now.year, now.month, now.day + 30));
    if (date != null && mounted) setState(() => selectedPlanDay = date);
  }

  Widget _draftInbox() => store.drafts.isEmpty ? const SizedBox.shrink() : Card(
    child: ListTile(
      leading: const Icon(Icons.drafts_outlined, color: violet),
      title: Text('${store.drafts.length} saved drafts to review'),
      subtitle: const Text('Unconfirmed tasks and AI review suggestions are not scheduled.'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => CapturePage(mode: 0, deletePhotos: store.deletePhotos,
            store: store, reviewDrafts: true),
      )),
    ),
  );

  Widget _coursesSettings() {
    final now = DateTime.now();
    final tomorrow = DateTime(now.year, now.month, now.day + 1);
    final date = store.coursesDate;
    final stale = store.tomorrowSubjects.isNotEmpty &&
        (date == null || dayOnly(date) != tomorrow);
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Dated courses', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text(date == null ? 'No course date confirmed' : 'Course date: ${date.year}/${date.month}/${date.day}'),
        if (stale) const Text('These courses are undated or not for tomorrow. They are not used to prioritize tomorrow’s plan.',
            style: TextStyle(color: Color(0xFF936128))),
        Text(store.tomorrowSubjects.isEmpty ? 'No courses selected' : store.tomorrowSubjects.join(', ')),
        TextButton.icon(onPressed: store.busy ? null : _editCourses,
            icon: const Icon(Icons.calendar_today_outlined), label: const Text('Set or reconfirm courses')),
      ],
    )));
  }

  Future<void> _editCourses() async {
    final now = DateTime.now();
    final date = await showDatePicker(context: context,
        initialDate: store.coursesDate ?? DateTime(now.year, now.month, now.day + 1),
        firstDate: DateTime(2000), lastDate: DateTime(2100, 12, 31));
    if (date == null || !mounted) return;
    final selected = {...store.tomorrowSubjects};
    final result = await showDialog<Set<String>>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: Text('Courses for ${date.year}/${date.month}/${date.day}'),
        content: SingleChildScrollView(child: Wrap(spacing: 8, children: [
          for (final subject in subjects.where((s) => s != 'Other'))
            FilterChip(label: Text(subject), selected: selected.contains(subject),
              onSelected: (value) => update(() { value ? selected.add(subject) : selected.remove(subject); })),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, selected), child: const Text('Confirm dated courses')),
        ],
      ),
    ));
    if (result != null) await action(() => store.updateCourses(result, date));
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
    final day = planDay;
    final from = day == dayOnly(now) ? now : null;
    final plan = localPlan
        ? Planner().generate(store.tasks, day, from: from,
            tomorrowSubjects: store.effectiveTomorrowSubjects(day))
        : store.planFor(day, from: from);
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
        _draftInbox(),
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
          Expanded(
            child: Text(
              planDay == dayOnly(DateTime.now()) ? "Tonight's timeline"
                  : '${planDay.month}/${planDay.day} study timeline',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ),
          TextButton.icon(
            onPressed: planning ? null : () => _planWithAi(replan: true),
            icon: const Icon(Icons.auto_awesome_outlined, size: 15),
            label: Text(planning ? 'Planning…' : 'AI replan',
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
      const Text(
        '16:00 — 21:00  ·  Make time for breaks',
        style: TextStyle(color: muted, fontSize: 11),
      ),
      const SizedBox(height: 8),
      Text('Planning day: ${planDay.year}/${planDay.month}/${planDay.day}',
          style: const TextStyle(fontWeight: FontWeight.w700)),
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final offset in [0, 1])
          ChoiceChip(
            label: Text(offset == 0 ? 'Today' : 'Tomorrow'),
            selected: planDay == DateTime(DateTime.now().year, DateTime.now().month,
                DateTime.now().day + offset),
            onSelected: planning ? null : (_) {
              final now = DateTime.now();
              setState(() => selectedPlanDay = DateTime(now.year, now.month, now.day + offset));
            },
          ),
        TextButton.icon(onPressed: planning ? null : _choosePlanDay,
            icon: const Icon(Icons.calendar_today_outlined), label: const Text('Choose planning date')),
      ]),
      const SizedBox(height: 18),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: planning ? null : () => _planWithAi(),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('AI plan'),
          ),
          TextButton(
            onPressed: planning ? null : () => setState(() {
              localPlan = true;
            }),
            child: const Text('Use local plan'),
          ),
        ],
      ),
      Text(localPlan ? 'Local plan · deterministic scheduling'
          : 'Local schedule · AI advice is used only after approval',
          style: const TextStyle(fontSize: 11, color: muted)),
      for (final id in plan.needsEstimates)
        ListTile(
          title: Text(store.tasks.firstWhere((t) => t.id == id).title),
          subtitle: const Text('Unfinished · update remaining-work estimate'),
          trailing: const Icon(Icons.edit_outlined),
          onTap: () => edit(store.tasks.firstWhere((t) => t.id == id)),
        ),
      if (plan.unscheduledMinutes.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF1DC),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            '${plan.unscheduledMinutes.values.fold<int>(0, (a, b) => a + b)} minutes do not fit the selected evening. Shorten tasks, defer them, or choose another planning date.',
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
                child: const Text('Load sample tasks'),
              ),
            ],
          ),
        ),
      for (final block in plan.blocks) _block(block),
      if (plan.blocks.isEmpty)
        const Text(
          'This study window has ended. Rest now, and choose Tomorrow or another planning date to prepare your next evening.',
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
                      selected: store.effectiveTomorrowSubjects(DateTime.now()).contains(s),
                      onSelected: (v) => action(() async {
                        final selected = {...store.effectiveTomorrowSubjects(DateTime.now())};
                        v ? selected.add(s) : selected.remove(s);
                        final now = DateTime.now();
                        await store.updateCourses(selected, DateTime(now.year, now.month, now.day + 1));
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
              for (final s in store.effectiveTomorrowSubjects(DateTime.now()))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '○  $s: Review notes, read ahead, and prepare materials',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (store.effectiveTomorrowSubjects(DateTime.now()).isEmpty)
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
          ..sort((a, b) => a.due == null ? (b.due == null ? 0 : 1)
              : b.due == null ? -1 : a.due!.compareTo(b.due!));
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
        _draftInbox(),
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
                        '${t.subject} · ${kindName(t.kind)} · ${deadlineLabel(t)} · ${t.remaining} min left',
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
                    onPressed: () => t.remainingSeconds == 0 ? edit(t) : focus(t),
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                    label: Text(t.remainingSeconds == 0 ? 'Update estimate' : 'Focus',
                        style: const TextStyle(fontSize: 12)),
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
      await action(() => store.deleteTask(t));
    }
  }

  Widget _calendar() {
    final first = DateTime(selectedDay.year, selectedDay.month);
    final days = DateTime(selectedDay.year, selectedDay.month + 1, 0).day;
    final offset = first.weekday - 1;
    final daily = store.tasks
        .where((t) => t.due != null && dayOnly(t.due!) == selectedDay)
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
                    final has = store.tasks.any((t) => t.due != null && dayOnly(t.due!) == d);
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
        if (store.tasks.any((t) => t.due == null)) ...[
          const SizedBox(height: 20),
          const Text('No deadline', style: TextStyle(fontWeight: FontWeight.w700)),
          for (final t in store.tasks.where((t) => t.due == null)) _taskCard(t),
        ],
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
        'Your library stays on your device. AI sharing is optional, per request.',
        style: TextStyle(color: muted),
      ),
      const SizedBox(height: 24),
      HostedServiceCard(gateway: store.gateway),
      BackupControls(store: store),
      _coursesSettings(),
      Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.shield_outlined, color: violet),
              title: Text('Local storage · No account needed'),
              subtitle: Text(
                'Encrypted local library. Only approved AI context is sent to the named hosted provider.',
              ),
            ),
            SwitchListTile(
              title: const Text('Delete temporary photos after scanning'),
              subtitle: const Text(
                'Only app copies are deleted. Your original photos stay safe.',
              ),
              value: store.deletePhotos,
              onChanged: (v) => action(() => store.setDeletePhotos(v)),
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
                'Remove activity history; keep actual focus totals on tasks',
              ),
              onTap: () async {
                if (await confirm(
                  context,
                  'Clear study history?',
                  'Activity history will be permanently deleted. Actual task focus totals are preserved.',
                )) {
                  await action(() => store.clearHistory());
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
      if (store.evidence.isNotEmpty) ...[
        const SizedBox(height: 20),
        const Text('Saved sources and marked feedback',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        for (final source in store.evidence.reversed)
          Card(child: ExpansionTile(
            title: Text(source.feedback ? 'Marked feedback' : 'Task source'),
            subtitle: Text('${source.createdAt.year}/${source.createdAt.month}/${source.createdAt.day}'),
            children: [Padding(padding: const EdgeInsets.all(16),
                child: SelectableText(source.text))],
          )),
      ],
      const SizedBox(height: 20),
      const Text(
        '$appDisplayName\nHosted AI requires approval for every request. Scheduling, OCR and speech stay on device. Password-encrypted backups move your library without sync.',
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
  String message, {
  String confirmLabel = 'Delete',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
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

