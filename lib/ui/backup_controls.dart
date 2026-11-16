part of '../app.dart';

class BackupControls extends StatefulWidget {
  const BackupControls({super.key, required this.store, this.selectBackup});
  final StudyController store;
  final Future<XFile?> Function()? selectBackup;
  @override
  State<BackupControls> createState() => _BackupControlsState();
}

class _BackupControlsState extends State<BackupControls> {
  bool working = false;
  String? message;

  Future<String?> password({required bool exporting}) {
    var first = '';
    final form = GlobalKey<FormState>();
    return showDialog<String>(context: context, builder: (ctx) => AlertDialog(
        title: Text(exporting ? 'Protect your backup' : 'Unlock backup'),
        content: SingleChildScrollView(child: Form(key: form, child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(exporting ? 'Use a unique password of at least 12 characters. It cannot be recovered. Store it separately from the backup.'
                : 'Decryption and preview happen on this device. Nothing changes until you confirm replacement.'),
            const SizedBox(height: 12),
            TextFormField(onChanged: (value) => first = value, obscureText: true, autocorrect: false,
              enableSuggestions: false, decoration: const InputDecoration(labelText: 'Backup password'),
              validator: (v) => v == null || v.isEmpty || (exporting && v.length < 12)
                  ? (exporting ? 'Use at least 12 characters' : 'Enter the backup password') : null),
            if (exporting) ...[
              const SizedBox(height: 12),
              TextFormField(obscureText: true, autocorrect: false,
                enableSuggestions: false, decoration: const InputDecoration(labelText: 'Repeat password'),
                validator: (v) => v != first ? 'Passwords do not match' : null),
            ],
          ],
        ))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () { if (form.currentState!.validate()) Navigator.pop(ctx, first); },
              child: Text(exporting ? 'Encrypt backup' : 'Decrypt and preview')),
        ],
    ));
  }

  Future<void> backup(bool exporting) async {
    if (working) return;
    setState(() { working = true; message = null; });
    try {
      XFile? selected;
      if (!exporting) {
        selected = await (widget.selectBackup?.call() ?? openFile(acceptedTypeGroups: const [
          XTypeGroup(label: 'Study backup', extensions: ['studyorbit'],
              mimeTypes: ['application/octet-stream'], uniformTypeIdentifiers: ['public.data']),
        ]));
        if (selected == null || !mounted) return;
        if (await selected.length() > BackupCodec.maxBackupBytes) {
          throw FormatException(
              'Backup exceeds ${BackupCodec.maxBackupBytes ~/ (1024 * 1024)} MiB.');
        }
      }
      if (!mounted) return;
      final secret = await password(exporting: exporting);
      if (secret == null) return;
      if (exporting) {
        final bytes = await widget.store.exportBackup(secret);
        final file = XFile.fromData(bytes, mimeType: 'application/octet-stream',
            name: 'study-backup.studyorbit');
        if (!mounted) return;
        if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux)) {
          final location = await getSaveLocation(suggestedName: 'study-backup.studyorbit');
          if (location == null) return;
          await file.saveTo(location.path);
          if (mounted) setState(() => message = 'Encrypted backup saved. Keep your password separately.');
        } else {
          final box = context.findRenderObject() as RenderBox?;
          await SharePlus.instance.share(ShareParams(files: [file],
              fileNameOverrides: const ['study-backup.studyorbit'],
              sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size));
          if (mounted) setState(() => message = 'Encrypted backup prepared. Save it using the share or download dialog.');
        }
      } else {
        final preview = await widget.store.previewBackup(await selected!.readAsBytes(), secret);
        if (!mounted) return;
        final replace = await confirm(context, 'Replace local library?',
            'Backup preview: ${preview.tasks.length} tasks, ${preview.drafts.length} drafts, '
            '${preview.evidence.length} text/feedback records, ${preview.focusRecords.length} focus records, '
            '${preview.history.length} history entries and ${preview.tomorrowSubjects.length} course subjects.\n\n'
            'Replace all current local study data and settings with this backup? This cannot be undone. Export your current library first if you want to keep it.',
            confirmLabel: 'Replace library');
        if (!replace) return;
        await widget.store.restoreBackup(preview);
        if (mounted) setState(() => message = 'Backup restored.');
      }
    } catch (e) {
      if (mounted) setState(() => message = 'Backup failed. Your existing library is unchanged. $e');
    } finally { if (mounted) setState(() => working = false); }
  }

  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Password-encrypted backup', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
      const SizedBox(height: 8),
      const Text('Move your local library without an account or cloud sync. Backups contain study text and records, never AI session credentials.'),
      Wrap(spacing: 8, children: [
        TextButton.icon(onPressed: working ? null : () => backup(true), icon: const Icon(Icons.ios_share), label: const Text('Export backup')),
        TextButton.icon(onPressed: working ? null : () => backup(false), icon: const Icon(Icons.file_open_outlined), label: const Text('Import backup')),
      ]),
      if (working) const LinearProgressIndicator(),
      if (message != null) Text(message!),
    ]),
  ));
}
