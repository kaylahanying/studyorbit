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

const ink = Color(0xFF222541),
    muted = Color(0xFF7B7D92),
    violet = Color(0xFF7363D9),
    mint = Color(0xFFCEE9DE),
    canvas = Color(0xFFF7F8FC);
const subjects = ['数学', '英语', '物理', '化学', '生物', '历史', '语文', '其他'];

class StudyOrbitApp extends StatelessWidget {
  const StudyOrbitApp({super.key, required this.store});
  final StudyStore store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'StudyOrbit',
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
  String filter = '全部';
  DateTime selectedDay = dayOnly(DateTime.now());
  DateTime? planFrom;
  final planner = Planner();
  StudyStore get store => widget.store;
  static const titles = ['今日轨道', '任务舱', '学习日历', '我的空间'];
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
      toast('保存失败，请重试。${store.error ?? '请检查设备存储空间。'}');
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
        await store.save('修改任务：${edited.title}');
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
                  label: '今日',
                ),
                NavigationDestination(
                  icon: Icon(Icons.checklist_rounded),
                  label: '任务',
                ),
                NavigationDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  label: '日历',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline_rounded),
                  label: '我的',
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
              label: const Text('录入学习任务'),
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
              '让每一天，井然有序。',
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
                    '进步，不必着急',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '专注一件小事，也是在靠近更好的自己。',
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
                Text('我的学习空间', style: TextStyle(fontSize: 12)),
                Spacer(),
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
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.blur_circular_rounded, color: violet, size: 30),
          SizedBox(width: 8),
          Text(
            'StudyOrbit',
            style: TextStyle(
              color: ink,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
            ),
          ),
        ],
      ),
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
                '${DateTime.now().month} 月 ${DateTime.now().day} 日',
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
          '一点点专注，一步步向前。',
          style: TextStyle(color: muted, fontSize: 12, letterSpacing: 1),
        ),
        const SizedBox(height: 8),
        const Text(
          '准备好进入学习轨道了吗？',
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
                '待完成任务',
                '$pending',
                '件',
                Icons.checklist_rounded,
                const Color(0xFFEFEDFB),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stat(
                '已完成任务',
                '$finished',
                '件',
                Icons.task_alt_rounded,
                const Color(0xFFE6F2EC),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stat(
                '累计专注',
                '$studyMinutes',
                '分钟',
                Icons.timelapse_rounded,
                const Color(0xFFFFF2DF),
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        const Text(
          '把任务交给轨道，把专注留给自己',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _captureCard(
                Icons.camera_alt_outlined,
                '拍照录入',
                '拍下作业与错题',
                1,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _captureCard(Icons.mic_none_rounded, '语音录入', '说出今天的任务', 2),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _captureCard(
                Icons.edit_note_rounded,
                '文字录入',
                '随时记下学习内容',
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
                '学习有节奏，\n生活有留白。',
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
                    ? '从一个小任务开始，规划你的今晚。'
                    : '$pending 个任务已就位，今晚也要照顾好自己。',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () =>
                    pending == 0 ? capture() : setState(() => tab = 1),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: Text(pending == 0 ? '开启今晚的计划' : '查看我的任务'),
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
          const Text(
            '今晚的时间线',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () {
              setState(() => planFrom = DateTime.now());
              action(() => store.save('从当前时间重新排程'));
              toast('已从当前时间重新安排剩余任务');
            },
            icon: const Icon(Icons.auto_awesome_outlined, size: 15),
            label: const Text('重新排程', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      const Text(
        '16:00 — 21:00  ·  留出休息，才能走得更远',
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
            '今晚还有 ${plan.unscheduledMinutes.values.fold<int>(0, (a, b) => a + b)} 分钟任务未能排入。请减少用时、延后任务，或明天继续。',
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
                '今晚的计划，从这里开始',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                '录入任务后，会自动安排学习时间。也可以先体验三项示例任务。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              TextButton(
                onPressed: () => action(() => store.sample()),
                child: const Text('载入示例任务 →'),
              ),
            ],
          ),
        ),
      for (final block in plan.blocks) _block(block),
      if (plan.blocks.isEmpty)
        const Text('今天的学习窗口已经结束。休息一下，明天继续。', style: TextStyle(color: muted)),
    ],
  );
  Widget _block(PlanBlock b) {
    final task = b.taskId == null
        ? null
        : store.tasks.where((t) => t.id == b.taskId).firstOrNull;
    final color = b.taskId != null
        ? const Color(0xFFEFEDFB)
        : b.title.contains('晚餐')
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
                          : b.title.contains('晚餐')
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
                          '${b.subtitle} · ${b.minutes} 分钟',
                          style: const TextStyle(fontSize: 10, color: muted),
                        ),
                      ],
                    ),
                  ),
                  if (task != null)
                    IconButton(
                      tooltip: '开始专注',
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
          '为明天，准备一点点',
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
                  Text('明日课程', style: TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 10),
              const Text(
                '选中明天的科目，相关任务将获得更高优先级。',
                style: TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  for (final s in subjects.where((s) => s != '其他'))
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
                '课前小清单',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final s in store.tomorrowSubjects)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '○  $s：回顾笔记、预读下一课、准备材料',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (store.tomorrowSubjects.isEmpty)
                const Text(
                  '选中科目后生成准备清单',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
              for (final t in matching)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.title, style: const TextStyle(fontSize: 12)),
                  leading: const Icon(Icons.check_box_outline_blank, size: 18),
                  onTap: () => edit(t),
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
                  '21:00 之后，安心下线。\n休息也是学习计划的一部分。',
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
                  filter == '全部' ||
                  filter == '已完成' && t.done ||
                  filter == '待完成' && !t.done ||
                  filter == '薄弱科目' && t.weak,
            )
            .toList()
          ..sort((a, b) => a.due.compareTo(b.due));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '每一个小任务，都是一次进步。',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 10),
        const Text('管理作业、考试、复习和预习，按自己的节奏向前。', style: TextStyle(color: muted)),
        const SizedBox(height: 22),
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['全部', '待完成', '薄弱科目', '已完成'])
              ChoiceChip(
                label: Text(f),
                selected: filter == f,
                onSelected: (_) => setState(() => filter = f),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (list.isEmpty) _empty('任务舱很轻盈', '添加一个任务，或者换个筛选条件。'),
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
                        '${t.subject} · ${kindName(t.kind)} · ${t.due.month}/${t.due.day} 截止 · 剩余 ${t.remaining} 分钟',
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
                  PopupMenuItem(value: 'edit', child: Text('编辑任务')),
                  PopupMenuItem(value: 'defer', child: Text('延后到明天')),
                  PopupMenuItem(value: 'delete', child: Text('删除任务')),
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
                if (t.weak) _pill('薄弱科目', const Color(0xFFFFEADB)),
                if (t.deferredUntil != null)
                  _pill(
                    '已延后至 ${t.deferredUntil!.month}/${t.deferredUntil!.day}',
                    const Color(0xFFE9F1EC),
                  ),
                if (!t.done)
                  TextButton.icon(
                    onPressed: () => focus(t),
                    icon: const Icon(Icons.play_arrow_rounded, size: 17),
                    label: const Text('开始专注', style: TextStyle(fontSize: 12)),
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
    final yes = await confirm(context, '删除这个任务？', '将删除「${t.title}」。此操作无法撤销。');
    if (yes) {
      await action(() async {
        store.tasks.remove(t);
        await store.save('删除任务：${t.title}');
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
          '让未来，清晰一点。',
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
                      tooltip: '上个月',
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
                          '${selectedDay.year} 年 ${selectedDay.month} 月',
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
                      child: const Text('今天'),
                    ),
                    IconButton(
                      tooltip: '下个月',
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
                    for (final day in ['一', '二', '三', '四', '五', '六', '日'])
                      Expanded(
                        child: Center(
                          child: Text(
                            day,
                            style: const TextStyle(color: muted),
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
                              style: TextStyle(
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
          '${selectedDay.month} 月 ${selectedDay.day} 日 · 截止任务',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 14),
        if (daily.isEmpty) _empty('这一天没有截止任务', '留一点空间给自己。'),
        for (final t in daily) _taskCard(t),
      ],
    );
  }

  Widget _settings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '属于你的学习空间',
        style: TextStyle(fontSize: 27, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text('数据留在设备上，节奏掌握在自己手里。', style: TextStyle(color: muted)),
      const SizedBox(height: 24),
      Card(
        child: Column(
          children: [
            const ListTile(
              leading: Icon(Icons.shield_outlined, color: violet),
              title: Text('本地优先 · 无需账号'),
              subtitle: Text('任务和记录保存在当前设备，不上传云端。'),
            ),
            SwitchListTile(
              title: const Text('识别后删除临时照片'),
              subtitle: const Text('只删除 App 临时副本，不影响原始相册图片'),
              value: store.deletePhotos,
              onChanged: (v) => action(() async {
                store.deletePhotos = v;
                await store.save();
              }),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('删除保留的临时照片'),
              subtitle: const Text('清理 App 拍摄和导入的副本，不删除原始相册图片'),
              onTap: () async {
                if (await confirm(context, '删除临时照片？', '将永久删除 App 保留的图片副本。')) {
                  await action(() async {
                    await clearRetainedPhotos();
                    toast('临时照片已清理');
                  });
                }
              },
            ),
            const ListTile(
              leading: Icon(Icons.mic_none_rounded),
              title: Text('仅使用设备端语音识别'),
              subtitle: Text('不支持离线识别时会停止，不回退至云端。'),
            ),
            const ListTile(
              leading: Icon(Icons.notifications_none_rounded),
              title: Text('专注与休息提醒'),
              subtitle: Text('当前版本仅在专注页面打开时提醒；未接入后台通知。'),
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
              title: const Text('清空学习历史'),
              subtitle: const Text('保留任务，删除操作记录和累计专注时间'),
              onTap: () async {
                if (await confirm(context, '清空学习历史？', '操作记录和累计专注时间将永久删除。')) {
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
              title: const Text('删除全部本地数据'),
              onTap: () async {
                if (await confirm(
                  context,
                  '删除全部数据？',
                  '所有任务、学习记录和设置将永久删除，无法恢复。',
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
        '学习足迹',
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 12),
      if (store.history.isEmpty) _empty('还没有学习记录', '添加任务或开启一次专注，记录会出现在这里。'),
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
        'StudyOrbit · MVP 1.0\n本地规则排程与草稿提取；尚未接入大语言模型、订阅和加密备份。',
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
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
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

class _CapturePageState extends State<CapturePage> {
  late int mode = widget.mode;
  final input = TextEditingController();
  final speech = const MethodChannel('si.studyorbit/offline_speech');
  bool busy = false, listening = false;
  String? error, photoPath;
  Uint8List? photo;
  List<StudyTask>? drafts;
  @override
  void dispose() {
    input.dispose();
    if (listening) speech.invokeMethod<void>('cancel');
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
      fail('拍照识别需要 Android 或 iOS 手机。当前平台可使用文字录入。');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    TextRecognizer? recognizer;
    String? currentPath;
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
      recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(picked.path),
      );
      if (!mounted) return;
      setState(() {
        photo = bytes;
        photoPath = picked.path;
        input.text = recognized.text;
      });
      if (recognized.text.trim().isEmpty) fail('没有识别到文字，请重新拍摄，或手动补充。');
    } catch (_) {
      fail('无法识别照片。请检查相机权限、设备识别模型，或改用文字录入。');
    } finally {
      await recognizer?.close();
      if (widget.deletePhotos && currentPath != null) {
        try {
          await deleteLocalPhoto(currentPath);
        } catch (_) {
          fail('临时照片删除失败，请在设备设置中清理 App 数据。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> dictate() async {
    if (listening) {
      await speech.invokeMethod<void>('stop');
      return;
    }
    if (!mobile) {
      fail('仅在支持设备端语音识别的 Android / iOS 手机上可用。请使用文字录入。');
      return;
    }
    setState(() {
      busy = true;
      listening = true;
      error = null;
    });
    try {
      final result = await speech.invokeMethod<String>('recognize', {
        'locale': 'zh-CN',
      });
      if (mounted && result != null && result.trim().isNotEmpty) {
        setState(
          () => input.text = [
            input.text,
            result,
          ].where((s) => s.isNotEmpty).join('\n'),
        );
      }
    } on PlatformException catch (e) {
      fail(e.message ?? '设备端语音识别不可用，请改用文字录入。');
    } catch (_) {
      fail('设备端语音识别不可用，请改用文字录入。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          listening = false;
        });
      }
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
    appBar: AppBar(title: Text(drafts == null ? '把今天的任务放进轨道' : '确认你的任务草稿')),
    body: SafeArea(
      child: SingleChildScrollView(
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
                  drafts == null ? '想到什么，就记下来。' : '核对一下，再开始。',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  drafts == null ? '作业、quiz 订正、考试和预习，都可以一起录入。' : '以下字段由本地规则提取，可能不准确。请逐项检查科目、日期和用时；未识别的日期默认明天，用时默认 30 分钟。',
                  style: const TextStyle(color: muted, fontSize: 13),
                ),
                const SizedBox(height: 22),
                if (drafts == null) ...[
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.edit_note),
                        label: Text('文字'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.camera_alt_outlined),
                        label: Text('拍照'),
                      ),
                      ButtonSegment(
                        value: 2,
                        icon: Icon(Icons.mic_none),
                        label: Text('语音'),
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
                            label: const Text('拍摄作业'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () => scan(ImageSource.gallery),
                            icon: const Icon(Icons.photo_outlined),
                            label: const Text('从相册选择'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '识别在设备上完成。图片仅用于当前草稿，不上传。',
                      style: TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                  if (mode == 2) ...[
                    FilledButton.icon(
                      onPressed: busy && !listening ? null : dictate,
                      icon: Icon(listening ? Icons.stop : Icons.mic_none),
                      label: Text(listening ? '结束录音' : '开始设备端语音识别'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '需要设备已安装中文离线识别模型。不支持时会提示，不会启用云端识别。',
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
                      child: const Text('移除图片预览'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  TextField(
                    controller: input,
                    enabled: !busy,
                    minLines: 7,
                    maxLines: 14,
                    decoration: const InputDecoration(
                      labelText: '学习内容 / 识别文本',
                      alignLabelWithHint: true,
                      hintText: '每行一个任务，例如：\n数学，明天交二次函数练习，45分钟\n物理，后天考试，复习力与运动，60分钟\n英语，预习下一课，20分钟',
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '提示：按行拆分任务；支持“今天 / 明天 / 后天”、月/日和“分钟”。复杂日期请在草稿中手动修改。',
                    style: TextStyle(color: muted, fontSize: 11, height: 1.7),
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
                          '${drafts![i].subject} · ${kindName(drafts![i].kind)}\n${drafts![i].due.month}/${drafts![i].due.day} 截止 · ${drafts![i].minutes} 分钟',
                          style: const TextStyle(fontSize: 12, height: 1.8),
                        ),
                        onTap: () => editDraft(i),
                        trailing: IconButton(
                          tooltip: '移除草稿',
                          onPressed: () => setState(() => drafts!.removeAt(i)),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: () => setState(() => drafts = null),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text('返回修改原文'),
                  ),
                ],
                if (error != null)
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
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () {
                            if (drafts == null) {
                              if (input.text.trim().isEmpty) {
                                fail('请先输入学习内容。');
                                return;
                              }
                              setState(() {
                                drafts = parseDrafts(
                                  input.text,
                                  DateTime.now(),
                                );
                                error = null;
                              });
                            } else if (drafts!.isEmpty) {
                              fail('请至少保留一个任务。');
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
                      drafts == null ? '生成任务草稿' : '确认并添加 ${drafts!.length} 个任务',
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
              '调整学习任务',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: title,
              decoration: const InputDecoration(labelText: '任务名称'),
              maxLength: 200,
              validator: (s) =>
                  s == null || s.trim().isEmpty ? '请输入任务名称' : null,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: task.subject,
                    decoration: const InputDecoration(labelText: '科目'),
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
                    initialValue: task.kind,
                    decoration: const InputDecoration(labelText: '任务类型'),
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
                    decoration: const InputDecoration(labelText: '预计分钟'),
                    validator: (s) {
                      final n = int.tryParse(s ?? '');
                      return n == null || n < 5 || n > 600
                          ? '输入 5–600 分钟'
                          : null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text('任务难度：${['轻松', '适中', '有挑战'][task.difficulty - 1]}'),
            Slider(
              value: task.difficulty.toDouble(),
              min: 1,
              max: 3,
              divisions: 2,
              onChanged: (v) => setState(() => task.difficulty = v.round()),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('这是我的薄弱科目'),
              value: task.weak,
              onChanged: (v) => setState(() => task.weak = v),
            ),
            TextFormField(
              controller: steps,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '任务步骤（每行一步，可选）',
                hintText: '整理材料\n完成练习\n检查与订正',
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
                child: const Text('保存修改'),
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
            title: Text(breakMode ? '休息结束' : '专注时间到'),
            content: Text(breakMode ? '准备好后，回到你的学习轨道。' : '看向远处、喝口水，给自己五分钟休息。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
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
        '专注 ${delta ~/ 60} 分 ${delta % 60} 秒：${widget.task.title}',
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('学习记录保存失败，请检查设备存储。')));
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
          tooltip: '保存并返回',
          onPressed: saving ? null : leave,
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('专注模式'),
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
                    breakMode ? '给大脑一点留白' : '一次，只专注一件事',
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
                                  ? '休息时间'
                                  : running
                                  ? '正在靠近目标'
                                  : '准备好就开始',
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
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
                        label: Text(running ? '暂停' : '开始'),
                      ),
                      const SizedBox(width: 12),
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
                        child: Text(breakMode ? '回到学习' : '休息 5 分钟'),
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
                        '本次专注清单',
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
                                  const SnackBar(content: Text('保存失败，请重试。')),
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('任务已完成，记录进步'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '离开 App 时自动暂停。提醒仅在此页面打开时生效。',
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
