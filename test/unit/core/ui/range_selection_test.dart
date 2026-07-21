import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/ui/range_selection.dart';

/// Unit tests for the pure desktop multi-selection model (ux-design §9).
void main() {
  const List<String> order = <String>['a', 'b', 'c', 'd', 'e'];

  group('RangeSelection', () {
    test('given_empty_when_selectOnly_then_single_and_anchored', () {
      final RangeSelection result = const RangeSelection().selectOnly('c');
      expect(result.ids, <String>{'c'});
      expect(result.anchor, 'c');
      expect(result.count, 1);
    });

    test('given_selection_when_selectOnly_then_replaces_others', () {
      final RangeSelection start = const RangeSelection(
        ids: <String>{'a', 'b'},
        anchor: 'b',
      );
      final RangeSelection result = start.selectOnly('d');
      expect(result.ids, <String>{'d'});
      expect(result.anchor, 'd');
    });

    test('given_item_when_toggle_added_then_anchor_moves_to_it', () {
      final RangeSelection result = const RangeSelection(
        ids: <String>{'a'},
        anchor: 'a',
      ).toggle('c');
      expect(result.ids, <String>{'a', 'c'});
      expect(result.anchor, 'c');
    });

    test('given_selected_item_when_toggle_removed_then_anchor_cleared', () {
      final RangeSelection result = const RangeSelection(
        ids: <String>{'a', 'c'},
        anchor: 'c',
      ).toggle('c');
      expect(result.ids, <String>{'a'});
      expect(result.anchor, isNull);
    });

    test('given_anchor_when_extendTo_forward_then_selects_inclusive_range', () {
      final RangeSelection result = const RangeSelection(
        ids: <String>{'b'},
        anchor: 'b',
      ).extendTo('d', order);
      expect(result.ids, <String>{'b', 'c', 'd'});
      // Anchor is preserved so successive shift-clicks re-extend from it.
      expect(result.anchor, 'b');
    });

    test(
      'given_anchor_when_extendTo_backward_then_selects_inclusive_range',
      () {
        final RangeSelection result = const RangeSelection(
          ids: <String>{'d'},
          anchor: 'd',
        ).extendTo('b', order);
        expect(result.ids, <String>{'b', 'c', 'd'});
        expect(result.anchor, 'd');
      },
    );

    test('given_anchor_when_extend_then_re_extend_replaces_prior_range', () {
      final RangeSelection first = const RangeSelection(
        ids: <String>{'b'},
        anchor: 'b',
      ).extendTo('d', order);
      final RangeSelection second = first.extendTo('a', order);
      expect(second.ids, <String>{'a', 'b'});
      expect(second.anchor, 'b');
    });

    test('given_no_anchor_when_extendTo_then_behaves_like_selectOnly', () {
      final RangeSelection result = const RangeSelection().extendTo('c', order);
      expect(result.ids, <String>{'c'});
      expect(result.anchor, 'c');
    });

    test('given_order_when_selectAll_then_selects_every_id', () {
      final RangeSelection result = const RangeSelection().selectAll(order);
      expect(result.ids, order.toSet());
      expect(result.anchor, 'a');
    });

    test('given_selection_when_pruneTo_then_drops_absent_ids_and_anchor', () {
      final RangeSelection result = const RangeSelection(
        ids: <String>{'a', 'z'},
        anchor: 'z',
      ).pruneTo(order);
      expect(result.ids, <String>{'a'});
      expect(result.anchor, isNull);
    });
  });

  group('applySelectionClick', () {
    test('none_modifier_selects_one', () {
      final RangeSelection result = applySelectionClick(
        current: const RangeSelection(ids: <String>{'a', 'b'}, anchor: 'b'),
        id: 'd',
        order: order,
        modifier: SelectionModifier.none,
      );
      expect(result.ids, <String>{'d'});
    });

    test('toggle_modifier_adds_without_clearing', () {
      final RangeSelection result = applySelectionClick(
        current: const RangeSelection(ids: <String>{'a'}, anchor: 'a'),
        id: 'c',
        order: order,
        modifier: SelectionModifier.toggle,
      );
      expect(result.ids, <String>{'a', 'c'});
    });

    test('range_modifier_extends_from_anchor', () {
      final RangeSelection result = applySelectionClick(
        current: const RangeSelection(ids: <String>{'b'}, anchor: 'b'),
        id: 'd',
        order: order,
        modifier: SelectionModifier.range,
      );
      expect(result.ids, <String>{'b', 'c', 'd'});
    });
  });
}
