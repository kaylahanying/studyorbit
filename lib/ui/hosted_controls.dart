part of '../app.dart';

String deadlineLabel(StudyTask task) {
  final due = task.due;
  if (due == null) return 'No deadline';
  return 'Due ${due.year}/${due.month}/${due.day}'
      '${task.dueTimeKnown ? ' ${clockTime(due)}' : ' (date only)'}';
}

Future<bool> approveAiRequest(BuildContext context, HostedAiGateway gateway,
    StudySnapshot snapshot, {required String operation, String? text, DateTime? day}) async {
  final status = await gateway.status();
  if (!context.mounted) return false;
  if (status.error != null || !status.configured || !status.authenticated ||
      status.remaining <= 0 || status.provider.isEmpty || status.model.isEmpty) {
    throw StateError(status.error ??
        'Hosted AI is unavailable. Check the AI service and invitation in My space. Local tools remain available.');
  }
  return await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Share text for AI $operation?'),
      content: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Provider: ${status.provider}\nModel: ${status.model}'),
          if (day != null) Text('Planning date: ${day.year}/${day.month}/${day.day}'),
          const SizedBox(height: 12),
          Text('This request sends ${text == null ? 'your study context' : 'the text below and study context'} through the hosted study server to this provider: '
              '${snapshot.tasks.length} confirmed tasks (including sources, steps and progress), '
              '${snapshot.evidence.length} saved text/feedback records, '
              '${snapshot.focusRecords.length} actual focus records, and relevant dated courses. '
              'Unconfirmed drafts are not treated as assignments. Photos and audio are never uploaded. '
              'Your library stays local; the study server does not store it.'),
          if (text != null) ...[
            const SizedBox(height: 12),
            SelectableText(text),
          ],
          const SizedBox(height: 12),
          const Text('AI can be wrong. Review every task and suggestion. Approval applies only to this request.'),
        ],
      )),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Share text once')),
      ],
    ),
  ) ?? false;
}

class HostedServiceCard extends StatefulWidget {
  const HostedServiceCard({super.key, required this.gateway});
  final HostedAiGateway gateway;
  @override
  State<HostedServiceCard> createState() => _HostedServiceCardState();
}

class _HostedServiceCardState extends State<HostedServiceCard> {
  late Future<HostedAiStatus> status = widget.gateway.status();
  bool working = false;
  String? error;

  Future<void> changeSession(bool end) async {
    if (working) return;
    setState(() { working = true; error = null; });
    try {
      if (end) {
        if (!await confirm(context, 'End AI session?',
            'This removes the hosted AI session on this device. Your local study library is unchanged.',
            confirmLabel: 'End session')) {
          return;
        }
        await widget.gateway.signOut();
      } else {
        var entered = '';
        final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
            title: const Text('Enter pilot invitation'),
            content: TextField(onChanged: (value) => entered = value, obscureText: true,
                autocorrect: false, enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Invitation code')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, entered), child: const Text('Start session')),
            ],
        ));
        if (value == null) return;
        await widget.gateway.signIn(value);
      }
      if (mounted) setState(() => status = widget.gateway.status());
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Hosted study AI', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
      const SizedBox(height: 8),
      FutureBuilder<HostedAiStatus>(future: status, builder: (context, result) {
        final value = result.data;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value == null ? 'Checking service…' : value.error ??
              '${value.configured ? '${value.provider} · ${value.model}' : 'Service not configured'}\n'
              '${value.authenticated ? 'Session active · ${value.remaining}/${value.dailyLimit} requests left' : 'Invitation required'}'),
          Wrap(spacing: 8, children: [
            TextButton(onPressed: working ? null : () => setState(() => status = widget.gateway.status()), child: const Text('Refresh status')),
            TextButton(onPressed: working ? null : () => changeSession(value?.authenticated == true),
                child: Text(value?.authenticated == true ? 'End AI session' : 'Enter invitation')),
          ]),
        ]);
      }),
      if (working) const LinearProgressIndicator(),
      if (error != null) Text(error!, style: const TextStyle(color: Colors.redAccent)),
      const Text('No personal API key. Every analysis needs your approval. Signing in does not sync your library.',
          style: TextStyle(color: muted, fontSize: 12)),
    ]),
  ));
}
