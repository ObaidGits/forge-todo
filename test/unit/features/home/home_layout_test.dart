import 'package:flutter_test/flutter_test.dart';
import 'package:forge/features/home/application/home_layout_store.dart';
import 'package:forge/features/home/domain/home_layout.dart';
import 'package:forge/features/home/domain/home_section.dart';

/// Pure layout-model tests for the user-ordered, collapsible Today sections.
///
/// **Validates: Requirements R-HOME-002**
void main() {
  group('default layout (R-HOME-002)', () {
    test('is total, unhidden, and orders overdue then today first', () {
      final HomeLayout layout = HomeLayout.defaultLayout;
      expect(layout.order.toSet(), HomeSectionKind.values.toSet());
      expect(layout.hidden, isEmpty);
      expect(layout.isDefault, isTrue);
      expect(layout.visibleOrder.first, HomeSectionKind.overdue);
      expect(layout.visibleOrder[1], HomeSectionKind.todayTasks);
    });
  });

  group('normalization keeps the layout total and forward-compatible', () {
    test('appends missing sections in default order', () {
      final HomeLayout layout = HomeLayout.from(
        order: <HomeSectionKind>[HomeSectionKind.progress],
      );
      expect(layout.order.first, HomeSectionKind.progress);
      expect(layout.order.toSet(), HomeSectionKind.values.toSet());
    });

    test('drops duplicates keeping first occurrence', () {
      final HomeLayout layout = HomeLayout.from(
        order: <HomeSectionKind>[
          HomeSectionKind.todayTasks,
          HomeSectionKind.todayTasks,
          HomeSectionKind.overdue,
        ],
      );
      expect(
        layout.order.where(
          (HomeSectionKind k) => k == HomeSectionKind.todayTasks,
        ),
        hasLength(1),
      );
      expect(layout.order.first, HomeSectionKind.todayTasks);
    });
  });

  group('reordering by user preference (R-HOME-002)', () {
    test('moveUp / moveDown change position and clear isDefault', () {
      final HomeLayout moved = HomeLayout.defaultLayout.moveUp(
        HomeSectionKind.todayTasks,
      );
      expect(moved.visibleOrder.first, HomeSectionKind.todayTasks);
      expect(moved.isDefault, isFalse);

      final HomeLayout back = moved.moveDown(HomeSectionKind.todayTasks);
      expect(back.visibleOrder.first, HomeSectionKind.overdue);
    });

    test('moveUp at the top is a no-op', () {
      final HomeLayout layout = HomeLayout.defaultLayout;
      final HomeLayout same = layout.moveUp(HomeSectionKind.overdue);
      expect(same.order, layout.order);
    });
  });

  group('hiding sections is explicit and reversible', () {
    test('hidden sections drop out of visibleOrder but stay in order', () {
      final HomeLayout hidden = HomeLayout.defaultLayout.hide(
        HomeSectionKind.progress,
      );
      expect(hidden.isHidden(HomeSectionKind.progress), isTrue);
      expect(hidden.visibleOrder, isNot(contains(HomeSectionKind.progress)));
      expect(hidden.order, contains(HomeSectionKind.progress));

      final HomeLayout shown = hidden.show(HomeSectionKind.progress);
      expect(shown.visibleOrder, contains(HomeSectionKind.progress));
    });
  });

  group('reset restores the minimal useful default (ux §8)', () {
    test('reset undoes reorder and hide', () {
      final HomeLayout custom = HomeLayout.defaultLayout
          .moveDown(HomeSectionKind.overdue)
          .hide(HomeSectionKind.habits);
      expect(custom.isDefault, isFalse);
      expect(custom.reset().isDefault, isTrue);
    });
  });

  group('codec round-trips and tolerates unknown/partial input', () {
    test('encode then decode preserves order and hidden set', () {
      final HomeLayout custom = HomeLayout.defaultLayout
          .moveUp(HomeSectionKind.progress)
          .hide(HomeSectionKind.focus);
      final HomeLayout decoded = HomeLayoutCodec.decode(
        HomeLayoutCodec.encode(custom),
      );
      expect(decoded.order, custom.order);
      expect(decoded.hidden, custom.hidden);
    });

    test('null or empty decodes to the default layout', () {
      expect(HomeLayoutCodec.decode(null).isDefault, isTrue);
      expect(HomeLayoutCodec.decode('').isDefault, isTrue);
    });

    test('unknown section wires are ignored, missing ones appended', () {
      final HomeLayout decoded = HomeLayoutCodec.decode(
        'order=progress,not_a_section;hidden=ghost',
      );
      expect(decoded.order.first, HomeSectionKind.progress);
      expect(decoded.order.toSet(), HomeSectionKind.values.toSet());
      expect(decoded.hidden, isEmpty);
    });
  });
}
