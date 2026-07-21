import 'package:forge/features/home/domain/home_section.dart';

/// The user-controlled ordering and visibility of Today's sections
/// (R-HOME-002).
///
/// A layout is an immutable value: it carries a full [order] of every
/// [HomeSectionKind] plus the set of sections the user has [hidden]. It always
/// stays *total* — every section appears exactly once in [order] — so decoding
/// a partial or stale preference is forward-compatible: missing sections are
/// appended in their default position and unknown ones are dropped.
///
/// Hiding a section is an explicit user choice. Collapsing an *empty* section
/// is a separate, content-driven concern handled by the view; this value only
/// models the preference, never the data.
final class HomeLayout {
  HomeLayout._(this._order, this._hidden);

  /// Builds a normalized layout from any [order]/[hidden] input.
  ///
  /// Duplicates are removed keeping first occurrence, unknown/absent sections
  /// are appended in default order, and hidden entries not present in the known
  /// set are ignored.
  factory HomeLayout.from({
    required List<HomeSectionKind> order,
    Set<HomeSectionKind> hidden = const <HomeSectionKind>{},
  }) {
    final List<HomeSectionKind> normalized = <HomeSectionKind>[];
    for (final HomeSectionKind kind in order) {
      if (!normalized.contains(kind)) {
        normalized.add(kind);
      }
    }
    for (final HomeSectionKind kind in _defaultOrder) {
      if (!normalized.contains(kind)) {
        normalized.add(kind);
      }
    }
    final Set<HomeSectionKind> effectiveHidden = hidden
        .where(normalized.contains)
        .toSet();
    return HomeLayout._(
      List<HomeSectionKind>.unmodifiable(normalized),
      Set<HomeSectionKind>.unmodifiable(effectiveHidden),
    );
  }

  /// The minimal useful default (R-HOME-002), ordered per ux-design §8:
  /// urgent/overdue, then Today tasks, habits, resume learning, focus, quick
  /// note, progress, and finally completed.
  static HomeLayout get defaultLayout => HomeLayout.from(order: _defaultOrder);

  static const List<HomeSectionKind> _defaultOrder = <HomeSectionKind>[
    HomeSectionKind.overdue,
    HomeSectionKind.todayTasks,
    HomeSectionKind.habits,
    HomeSectionKind.resumeLearning,
    HomeSectionKind.focus,
    HomeSectionKind.quickNote,
    HomeSectionKind.progress,
    HomeSectionKind.completed,
  ];

  final List<HomeSectionKind> _order;
  final Set<HomeSectionKind> _hidden;

  /// The full section order, including hidden sections.
  List<HomeSectionKind> get order => _order;

  /// The sections the user has explicitly hidden.
  Set<HomeSectionKind> get hidden => _hidden;

  /// The sections to render, in order, excluding user-hidden ones.
  List<HomeSectionKind> get visibleOrder => _order
      .where((HomeSectionKind k) => !_hidden.contains(k))
      .toList(growable: false);

  bool isHidden(HomeSectionKind kind) => _hidden.contains(kind);

  bool get isDefault {
    if (_hidden.isNotEmpty) {
      return false;
    }
    for (int i = 0; i < _defaultOrder.length; i += 1) {
      if (_order[i] != _defaultOrder[i]) {
        return false;
      }
    }
    return true;
  }

  /// Moves [kind] to just before [target], preserving every other relative
  /// position. A no-op when either section is missing or they are equal.
  HomeLayout moveBefore(HomeSectionKind kind, HomeSectionKind target) {
    if (kind == target) {
      return this;
    }
    final List<HomeSectionKind> next = List<HomeSectionKind>.of(_order)
      ..remove(kind);
    final int targetIndex = next.indexOf(target);
    if (targetIndex < 0) {
      return this;
    }
    next.insert(targetIndex, kind);
    return HomeLayout._(List<HomeSectionKind>.unmodifiable(next), _hidden);
  }

  /// Moves [kind] one position earlier in the order (keyboard-friendly reorder).
  HomeLayout moveUp(HomeSectionKind kind) {
    final int index = _order.indexOf(kind);
    if (index <= 0) {
      return this;
    }
    return moveBefore(kind, _order[index - 1]);
  }

  /// Moves [kind] one position later in the order.
  HomeLayout moveDown(HomeSectionKind kind) {
    final int index = _order.indexOf(kind);
    if (index < 0 || index >= _order.length - 1) {
      return this;
    }
    final List<HomeSectionKind> next = List<HomeSectionKind>.of(_order)
      ..remove(kind);
    final int afterIndex = next.indexOf(_order[index + 1]);
    next.insert(afterIndex + 1, kind);
    return HomeLayout._(List<HomeSectionKind>.unmodifiable(next), _hidden);
  }

  HomeLayout hide(HomeSectionKind kind) {
    if (_hidden.contains(kind)) {
      return this;
    }
    return HomeLayout._(
      _order,
      Set<HomeSectionKind>.unmodifiable(<HomeSectionKind>{..._hidden, kind}),
    );
  }

  HomeLayout show(HomeSectionKind kind) {
    if (!_hidden.contains(kind)) {
      return this;
    }
    return HomeLayout._(
      _order,
      Set<HomeSectionKind>.unmodifiable(
        _hidden.where((HomeSectionKind k) => k != kind).toSet(),
      ),
    );
  }

  /// Restores the minimal useful default (the "Reset layout" action, ux §8).
  HomeLayout reset() => defaultLayout;
}
