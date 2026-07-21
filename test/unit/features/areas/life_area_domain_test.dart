import 'package:flutter_test/flutter_test.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/features/areas/domain/life_area.dart';
import 'package:forge/features/areas/domain/life_area_rank.dart';

/// Unit tests for Life Area domain values (R-GEN-002).
void main() {
  group('LifeAreaRank', () {
    test('between produces a rank strictly ordered between its neighbours', () {
      final LifeAreaRank a = LifeAreaRank.initial;
      final LifeAreaRank b = LifeAreaRank.append(a);
      expect(a.value.compareTo(b.value) < 0, isTrue);
      final LifeAreaRank mid = LifeAreaRank.between(a, b);
      expect(a.value.compareTo(mid.value) < 0, isTrue);
      expect(mid.value.compareTo(b.value) < 0, isTrue);
    });

    test('between with open lower end sorts before the first item', () {
      final LifeAreaRank first = LifeAreaRank.initial;
      final LifeAreaRank before = LifeAreaRank.between(null, first);
      expect(before.value.compareTo(first.value) < 0, isTrue);
    });

    test('out-of-order bounds are rejected', () {
      expect(
        () => LifeAreaRank.between(
          const LifeAreaRank('z'),
          const LifeAreaRank('a'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('LifeArea', () {
    test('normalizeName lowercases and collapses whitespace', () {
      expect(LifeArea.normalizeName('  Personal   Growth '), 'personal growth');
    });

    test('blank name is rejected', () {
      expect(
        () => LifeArea(
          id: LifeAreaId('a1'),
          profileId: ProfileId('p1'),
          name: '   ',
          rank: LifeAreaRank.initial,
          isDefault: false,
          createdAtUtc: 0,
          updatedAtUtc: 0,
        ),
        throwsFormatException,
      );
    });

    test('copyWith can clear the archived flag', () {
      final LifeArea archived = LifeArea(
        id: LifeAreaId('a1'),
        profileId: ProfileId('p1'),
        name: 'Career',
        rank: LifeAreaRank.initial,
        isDefault: false,
        archivedAtUtc: 100,
        createdAtUtc: 0,
        updatedAtUtc: 0,
      );
      expect(archived.isArchived, isTrue);
      final LifeArea restored = archived.copyWith(archivedAtUtc: null);
      expect(restored.isArchived, isFalse);
    });
  });
}
