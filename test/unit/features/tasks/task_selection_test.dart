import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/ui/range_selection.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';

/// Unit tests for desktop-aware task multi-selection (ux-design §9). Batch
/// actions run over these selected ids.
void main() {
  late ProviderContainer container;
  const List<String> order = <String>['t1', 't2', 't3', 't4'];

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  TaskSelectionController controller() =>
      container.read(taskSelectionProvider.notifier);
  TaskSelectionState state() => container.read(taskSelectionProvider);

  test('given_fresh_when_built_then_inactive_and_empty', () {
    expect(state().active, isFalse);
    expect(state().isEmpty, isTrue);
  });

  test('given_plain_click_then_selects_one', () {
    controller().enter();
    controller().click('t2', order, SelectionModifier.none);
    expect(state().ids, <String>{'t2'});
    expect(state().active, isTrue);
  });

  test('given_shift_click_then_selects_range_from_anchor', () {
    controller().click('t1', order, SelectionModifier.none);
    controller().click('t3', order, SelectionModifier.range);
    expect(state().ids, <String>{'t1', 't2', 't3'});
  });

  test('given_ctrl_click_then_adds_without_clearing', () {
    controller().click('t1', order, SelectionModifier.none);
    controller().click('t4', order, SelectionModifier.toggle);
    expect(state().ids, <String>{'t1', 't4'});
  });

  test('given_toggle_when_same_id_then_deselects', () {
    controller().toggle('t2');
    controller().toggle('t2');
    expect(state().isEmpty, isTrue);
  });

  test('given_selectAll_then_all_selected', () {
    controller().selectAll(order);
    expect(state().ids, order.toSet());
    expect(state().count, 4);
  });

  test('given_pruneTo_when_ids_removed_then_dropped', () {
    controller().selectAll(order);
    controller().pruneTo(<String>['t1', 't2']);
    expect(state().ids, <String>{'t1', 't2'});
  });

  test('given_clear_then_inactive_and_empty', () {
    controller().selectAll(order);
    controller().clear();
    expect(state().active, isFalse);
    expect(state().isEmpty, isTrue);
  });
}
