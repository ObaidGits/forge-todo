import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/desktop/presentation/desktop_preferences_section.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/sync/presentation/sync_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';
import 'package:go_router/go_router.dart';

/// The Settings hub (R-GEN-002 host surface).
///
/// A calm, keyboard-operable index into the app's management surfaces. Life
/// Area management (R-GEN-002) is reached from here; a data note reinforces the
/// local-first promise (R-GEN-001). Every row carries an accessible name and
/// meets the minimum touch-target size (NFR-A11Y-001).
final class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// The user-facing app version shown in the About row.
  static const String appVersion = '0.1.0';

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    return FocusTraversalGroup(
      child: ListView(
        restorationId: 'content-settings',
        padding: const EdgeInsets.symmetric(vertical: ForgeSpacing.sm),
        children: <Widget>[
          _sectionHeader(context, l10n.settingsSectionGeneral),
          _SettingsTile(
            icon: Icons.category_outlined,
            title: l10n.settingsLifeAreas,
            subtitle: l10n.settingsLifeAreasSubtitle,
            onTap: () => context.go('/settings/areas'),
          ),
          _SettingsTile(
            icon: Icons.search,
            title: l10n.settingsSearch,
            subtitle: l10n.settingsSearchSubtitle,
            onTap: () => context.go('/search'),
          ),
          // Fitness has no navigation-rail tab, so the Settings hub is its
          // entry point (R-FIT-001; ux-design nav map).
          _SettingsTile(
            icon: Icons.fitness_center_outlined,
            title: l10n.settingsFitness,
            subtitle: l10n.settingsFitnessSubtitle,
            onTap: () => context.push('/fitness'),
          ),
          // Insights has no navigation-rail tab, so the Settings hub is its
          // entry point (R-INSIGHT-001; ux-design nav map).
          _SettingsTile(
            icon: Icons.insights_outlined,
            title: l10n.settingsInsights,
            subtitle: l10n.settingsInsightsSubtitle,
            onTap: () => context.push('/insights'),
          ),
          const Divider(),
          _sectionHeader(context, l10n.settingsSectionData),
          // The Recovery Center has no navigation-rail tab, so the Settings hub
          // is its entry point (R-BACKUP-003, R-BACKUP-004; ux-design nav map).
          _SettingsTile(
            icon: Icons.settings_backup_restore,
            title: l10n.settingsBackup,
            subtitle: l10n.settingsBackupSubtitle,
            onTap: () => context.push('/recovery'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: ForgeSpacing.md,
              vertical: ForgeSpacing.xs,
            ),
            child: Text(
              l10n.settingsLocalOnly,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          // Optional cloud sync (R-SYNC-001/005/007). Shown only when a backend
          // is configured in this build; the default local-first build hides it
          // entirely so nothing changes.
          const _AccountSyncTile(),
          if (isDesktopPlatform) ...<Widget>[
            const Divider(),
            const DesktopPreferencesSection(),
          ],
          const Divider(),
          _sectionHeader(context, l10n.settingsAbout),
          _SettingsTile(
            icon: Icons.info_outline,
            title: l10n.appName,
            subtitle: l10n.settingsAboutVersion(appVersion),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(
      ForgeSpacing.md,
      ForgeSpacing.md,
      ForgeSpacing.md,
      ForgeSpacing.xxs,
    ),
    child: Semantics(
      header: true,
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    ),
  );
}

/// A Settings tile for the optional Account & sync surface. Renders only when
/// sync is enabled in this build (a backend is configured), so the default
/// local-first build is unchanged.
final class _AccountSyncTile extends ConsumerWidget {
  const _AccountSyncTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool enabled = ref.watch(syncEnabledProvider);
    if (!enabled) {
      return const SizedBox.shrink();
    }
    return _SettingsTile(
      icon: Icons.cloud_sync_outlined,
      title: 'Account & sync',
      subtitle:
          'Sign in to sync across devices (TLS, not end-to-end encrypted)',
      onTap: () => context.push('/account-sync'),
    );
  }
}

final class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ForgeSizes.minimumInteractiveDimension,
      ),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
