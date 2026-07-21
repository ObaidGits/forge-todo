import 'package:forge/core/domain/id.dart';
import 'package:forge/features/home/domain/home_layout.dart';
import 'package:forge/features/home/domain/home_section.dart';

/// Durable persistence port for the Today layout preference (R-HOME-002).
///
/// The stored value is durable user data reconstructible from Drift, never
/// owned solely by provider state (R-GEN-001). A missing preference yields the
/// minimal useful default.
abstract interface class HomeLayoutStore {
  Future<HomeLayout> load(ProfileId profileId);

  Future<void> save(ProfileId profileId, HomeLayout layout);
}

/// Compact, stable serialization of a [HomeLayout] for the settings store.
///
/// Format: `order=<wire,wire,...>;hidden=<wire,wire,...>`. Decoding is
/// forward-compatible — unknown sections are dropped and missing ones are
/// appended in default order by [HomeLayout.from].
abstract final class HomeLayoutCodec {
  static String encode(HomeLayout layout) {
    final String order = layout.order
        .map((HomeSectionKind k) => k.wire)
        .join(',');
    final String hidden = layout.hidden
        .map((HomeSectionKind k) => k.wire)
        .join(',');
    return 'order=$order;hidden=$hidden';
  }

  static HomeLayout decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return HomeLayout.defaultLayout;
    }
    List<HomeSectionKind> order = const <HomeSectionKind>[];
    Set<HomeSectionKind> hidden = <HomeSectionKind>{};
    for (final String part in raw.split(';')) {
      final int eq = part.indexOf('=');
      if (eq < 0) {
        continue;
      }
      final String key = part.substring(0, eq);
      final String value = part.substring(eq + 1);
      final List<HomeSectionKind> parsed = value
          .split(',')
          .where((String s) => s.isNotEmpty)
          .map(HomeSectionKind.fromWireOrNull)
          .whereType<HomeSectionKind>()
          .toList(growable: false);
      if (key == 'order') {
        order = parsed;
      } else if (key == 'hidden') {
        hidden = parsed.toSet();
      }
    }
    return HomeLayout.from(order: order, hidden: hidden);
  }
}

/// A volatile store used as a safe default and in unit tests. Not durable; the
/// production composition binds a settings-backed [HomeLayoutStore].
final class InMemoryHomeLayoutStore implements HomeLayoutStore {
  final Map<String, HomeLayout> _byProfile = <String, HomeLayout>{};

  @override
  Future<HomeLayout> load(ProfileId profileId) async =>
      _byProfile[profileId.value] ?? HomeLayout.defaultLayout;

  @override
  Future<void> save(ProfileId profileId, HomeLayout layout) async {
    _byProfile[profileId.value] = layout;
  }
}
