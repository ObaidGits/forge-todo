import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/backup/application/recovery_center.dart';
import 'package:forge/features/backup/presentation/backup_providers.dart';
import 'package:forge/features/backup/presentation/recovery_center_screen.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

/// The routed, composed Recovery Center.
///
/// This is the thin stateful shell that binds the pure [RecoveryCenterScreen]
/// to the application [RecoveryCenter] port (R-BACKUP-003, R-BACKUP-004). It
/// loads the available recovery points, prompts for the backup passphrase, and
/// drives the existing staged generation restore through the port — it never
/// forks that machinery and never resets keys or data. When the port is not
/// wired in this build, it shows the screen's honest empty state instead of
/// blanking.
final class RecoveryCenterPage extends ConsumerStatefulWidget {
  const RecoveryCenterPage({super.key});

  @override
  ConsumerState<RecoveryCenterPage> createState() => _RecoveryCenterPageState();
}

class _RecoveryCenterPageState extends ConsumerState<RecoveryCenterPage> {
  List<RecoveryPoint> _points = const <RecoveryPoint>[];
  RecoveryCenterStatus _status = RecoveryCenterStatus.idle;
  String? _busyPointId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Defer to after first frame so the provider scope is ready and any error
    // surfaces against a live context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final RecoveryCenter? center = ref.read(recoveryCenterProvider);
    if (center == null) {
      if (mounted) {
        setState(() {
          _points = const <RecoveryPoint>[];
          _loading = false;
        });
      }
      return;
    }
    try {
      final List<RecoveryPoint> points = await center.listRecoveryPoints();
      if (mounted) {
        setState(() {
          _points = points;
          _loading = false;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _points = const <RecoveryPoint>[];
          _loading = false;
        });
      }
    }
  }

  Future<void> _onRestore(RecoveryPoint point) async {
    final RecoveryCenter? center = ref.read(recoveryCenterProvider);
    if (center == null || _status == RecoveryCenterStatus.restoring) {
      return;
    }
    final String? passphrase = await _promptPassphrase();
    if (passphrase == null || !mounted) {
      // The user cancelled; nothing is touched.
      return;
    }
    setState(() {
      _status = RecoveryCenterStatus.restoring;
      _busyPointId = point.id;
    });
    try {
      await center.restore(point: point, passphrase: utf8.encode(passphrase));
      if (mounted) {
        setState(() {
          _status = RecoveryCenterStatus.restored;
          _busyPointId = null;
        });
      }
      await _load();
    } on Object {
      // Every restore failure is non-destructive: the live generation stays
      // (or is rolled back to) active. Surface the calm failure banner.
      if (mounted) {
        setState(() {
          _status = RecoveryCenterStatus.failed;
          _busyPointId = null;
        });
      }
    }
  }

  Future<String?> _promptPassphrase() {
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _PassphraseDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(context.l10n.recoveryCenterTitle)),
        body: const Center(child: CircularProgressIndicator.adaptive()),
      );
    }
    return RecoveryCenterScreen(
      points: _points,
      onRestore: _onRestore,
      status: _status,
      busyPointId: _busyPointId,
    );
  }
}

/// The passphrase prompt. It owns its own [TextEditingController] and disposes
/// it in [dispose] (after the route's exit animation completes), avoiding a
/// use-after-dispose during the dialog's close transition.
final class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.recoveryCenterPassphraseTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(l10n.recoveryCenterPassphraseMessage),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l10n.recoveryCenterPassphraseLabel,
            ),
            onSubmitted: (String value) => Navigator.of(context).pop(value),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dialogCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l10n.recoveryCenterRestoreShort),
        ),
      ],
    );
  }
}
