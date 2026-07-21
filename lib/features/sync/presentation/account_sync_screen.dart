/// The "Account & sync" surface (R-SYNC-001, R-SYNC-005, R-SYNC-007).
///
/// Sign in with email + password, see the current link/sync status (signed out
/// / linked / syncing / error), and trigger a manual "Sync now". It always
/// shows the TLS/non-E2EE trust disclosure before linking. When sync is not
/// configured in this build the surface says so honestly and offers nothing
/// else — the local-first app is unaffected.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/features/sync/domain/sync_identity.dart';
import 'package:forge/features/sync/domain/sync_state.dart';
import 'package:forge/features/sync/domain/sync_trust_disclosure.dart';
import 'package:forge/features/sync/infrastructure/supabase_sync_service.dart';
import 'package:forge/features/sync/presentation/sync_providers.dart';

final class AccountSyncScreen extends ConsumerWidget {
  const AccountSyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SupabaseSyncService? service = ref.watch(supabaseSyncServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Account & sync')),
      body: service == null
          ? const _SyncDisabledView()
          : _AccountSyncView(service: service),
    );
  }
}

final class _SyncDisabledView extends StatelessWidget {
  const _SyncDisabledView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 16),
            Text(
              'Sync is not configured in this build',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Forge works fully offline. To enable optional cloud sync, build '
              'with --dart-define=FORGE_SUPABASE_URL=... and '
              '--dart-define=FORGE_SUPABASE_ANON_KEY=... and sign in here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

final class _AccountSyncView extends StatefulWidget {
  const _AccountSyncView({required this.service});

  final SupabaseSyncService service;

  @override
  State<_AccountSyncView> createState() => _AccountSyncViewState();
}

class _AccountSyncViewState extends State<_AccountSyncView> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Result<Object?>> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final Result<Object?> result = await action();
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _message = result.isSuccess ? 'Done.' : (result.errorCode ?? 'Failed.');
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SyncStatus>(
      valueListenable: widget.service.status,
      builder: (BuildContext context, SyncStatus status, _) {
        final bool linked = status.linkState.canExchange;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _StatusCard(status: status, backendId: widget.service.backendId),
            const SizedBox(height: 16),
            const _TrustDisclosureCard(),
            const SizedBox(height: 16),
            if (!linked) ...<Widget>[
              TextField(
                controller: _email,
                key: const Key('account-sync-email'),
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.email],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                key: const Key('account-sync-password'),
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('account-sync-signin'),
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.service.signInWithPassword(
                          email: _email.text.trim(),
                          password: _password.text,
                        ),
                      ),
                icon: const Icon(Icons.login),
                label: const Text('Sign in'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => widget.service.signUpWithPassword(
                          email: _email.text.trim(),
                          password: _password.text,
                        ),
                      ),
                icon: const Icon(Icons.person_add_outlined),
                label: const Text('Create account'),
              ),
            ] else ...<Widget>[
              FilledButton.icon(
                key: const Key('account-sync-now'),
                onPressed: _busy ? null : () => _run(widget.service.syncNow),
                icon: const Icon(Icons.sync),
                label: const Text('Sync now'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('account-sync-signout'),
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await widget.service.signOut();
                        return const Success<void>(null);
                      }),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ],
            if (_busy) ...<Widget>[
              const SizedBox(height: 16),
              const Center(child: CircularProgressIndicator.adaptive()),
            ],
            if (_message != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(_message!, key: const Key('account-sync-message')),
            ],
          ],
        );
      },
    );
  }
}

final class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.backendId});

  final SyncStatus status;
  final String backendId;

  String get _label => switch (status.linkState) {
    SyncLinkState.signedOut => 'Signed out',
    SyncLinkState.authenticating => 'Signing in…',
    SyncLinkState.linkPreview => 'Reviewing link',
    SyncLinkState.linked =>
      status.error == SyncErrorKind.none ? 'Linked' : 'Linked (error)',
    SyncLinkState.expired => 'Session expired',
    SyncLinkState.revoked => 'Device revoked',
    SyncLinkState.accountChanged => 'Account changed',
    SyncLinkState.remoteDeleteReauth => 'Reauthentication required',
  };

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          status.linkState.canExchange
              ? Icons.cloud_done_outlined
              : Icons.cloud_outlined,
        ),
        title: Text(_label, key: const Key('account-sync-status')),
        subtitle: Text(
          'Backend: $backendId\n'
          'Pending: ${status.pendingOperationCount} · '
          'Conflicts: ${status.openConflictCount}'
          '${status.currentErrorCode != null ? '\nError: ${status.currentErrorCode}' : ''}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

final class _TrustDisclosureCard extends StatelessWidget {
  const _TrustDisclosureCard();

  @override
  Widget build(BuildContext context) {
    const SyncTrustDisclosure disclosure = SyncTrustDisclosure.current;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              disclosure.title,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(disclosure.summary),
            const SizedBox(height: 8),
            for (final SyncTrustFact fact in disclosure.facts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('• '),
                    Expanded(child: Text(disclosure.copyFor(fact))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
