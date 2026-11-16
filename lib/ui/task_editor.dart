part of '../app.dart';

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
  late final remaining = TextEditingController(text: '${widget.task.remaining}');
  late final steps = TextEditingController(text: widget.task.steps.join('\n'));
  late StudyTask task = widget.task;
  @override
  void dispose() {
    title.dispose(); minutes.dispose(); remaining.dispose(); steps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(24, 20, 24, MediaQuery.viewInsetsOf(context).bottom + 24),
    child: SingleChildScrollView(child: Form(key: form, child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Edit study task', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        const SizedBox(height: 20),
        TextFormField(controller: title, decoration: const InputDecoration(labelText: 'Task name'),
            maxLength: 200, validator: (s) => s == null || s.trim().isEmpty ? 'Enter a task name' : null),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: DropdownButtonFormField<String>(isExpanded: true, initialValue: task.subject,
              decoration: const InputDecoration(labelText: 'Subject'),
              items: [for (final s in {...subjects, task.subject}) DropdownMenuItem(value: s, child: Text(s))],
              onChanged: (v) { if (v != null) setState(() => task = task.copyWith(subject: v)); })),
          const SizedBox(width: 12),
          Expanded(child: DropdownButtonFormField<TaskKind>(isExpanded: true, initialValue: task.kind,
              decoration: const InputDecoration(labelText: 'Task type'),
              items: [for (final k in TaskKind.values) DropdownMenuItem(value: k, child: Text(kindName(k)))],
              onChanged: (v) { if (v != null) setState(() => task = task.copyWith(kind: v)); })),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: () async {
            final date = await showDatePicker(context: context, initialDate: task.due ?? DateTime.now(),
                firstDate: DateTime(2000), lastDate: DateTime(2100, 12, 31));
            if (date != null && mounted) setState(() => task = task.copyWith(due: date, dueTimeKnown: false));
          }, icon: const Icon(Icons.calendar_today, size: 15), label: Text(deadlineLabel(task))),
          if (task.due != null) TextButton(onPressed: () => setState(() => task = task.copyWith(due: null, dueTimeKnown: false)),
              child: const Text('Clear deadline')),
          if (task.due != null) TextButton(onPressed: () async {
            final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(task.due!));
            if (time != null && mounted) {
              final date = task.due!;
              setState(() => task = task.copyWith(due: DateTime(date.year, date.month, date.day, time.hour, time.minute), dueTimeKnown: true));
            }
          }, child: const Text('Set deadline time')),
          if (task.dueTimeKnown) TextButton(onPressed: () => setState(() => task = task.copyWith(due: dayOnly(task.due!), dueTimeKnown: false)),
              child: const Text('Date only')),
        ]),
        const SizedBox(height: 12),
        TextFormField(controller: minutes, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Original estimated minutes'), validator: (s) {
              final n = int.tryParse(s ?? '');
              return n == null || n < 5 || n > 600 ? 'Enter 5–600 minutes' : null;
            }),
        const SizedBox(height: 12),
        TextFormField(controller: remaining, keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Remaining-work minutes',
                helperText: 'Independent of actual focus time. Zero does not mark a task complete.'), validator: (s) {
              final n = int.tryParse(s ?? '');
              return n == null || n < 0 || n > 600 ? 'Enter 0–600 minutes' : null;
            }),
        const SizedBox(height: 16),
        Text('Difficulty: ${['Easy', 'Moderate', 'Challenging'][task.difficulty - 1]}'),
        Slider(value: task.difficulty.toDouble(), min: 1, max: 3, divisions: 2,
            onChanged: (v) => setState(() => task = task.copyWith(difficulty: v.round()))),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('I need extra practice in this subject'),
            value: task.weak, onChanged: (v) => setState(() => task = task.copyWith(weak: v))),
        TextFormField(controller: steps, minLines: 2, maxLines: 5,
            decoration: const InputDecoration(labelText: 'Steps (one per line, optional)',
                hintText: 'Gather materials\nComplete exercises\nCheck and correct')),
        if (task.sourceQuote.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12),
            child: SelectableText('Source requirement: ${task.sourceQuote}')),
        const SizedBox(height: 22),
        SizedBox(width: double.infinity, child: FilledButton(onPressed: () {
          if (!form.currentState!.validate()) return;
          final remainingSeconds = remaining.text == '${widget.task.remaining}'
              ? widget.task.remainingSeconds : int.parse(remaining.text) * 60;
          Navigator.pop(context, task.copyWith(title: title.text.trim(), minutes: int.parse(minutes.text),
              remainingSeconds: remainingSeconds,
              steps: steps.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()));
        }, child: const Text('Save changes'))),
      ],
    ))),
  );
}
