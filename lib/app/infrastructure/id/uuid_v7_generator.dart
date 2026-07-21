import 'dart:math';
import 'dart:typed_data';

import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';

/// Production [IdGenerator] that mints RFC 9562 UUID version 7 values.
///
/// Layout (RFC 9562 §5.7): a 48-bit big-endian Unix-epoch millisecond
/// timestamp, the 4-bit version `0b0111`, a 12-bit `rand_a` field, the 2-bit
/// variant `0b10`, and a 62-bit `rand_b` field.
///
/// Monotonicity within a single millisecond is guaranteed with the RFC's
/// "fixed-length dedicated counter" method (§6.2 method 1): `rand_a` is seeded
/// from CSPRNG bytes when the clock advances into a new millisecond and is
/// incremented for every subsequent id minted in that same millisecond. If the
/// 12-bit counter would overflow, the logical timestamp is nudged forward by
/// one millisecond and the counter reseeded, so emitted values never regress
/// even under burst allocation or a backward wall-clock step. `rand_b` is drawn
/// fresh from the CSPRNG on every call for global uniqueness.
final class UuidV7Generator implements IdGenerator {
  UuidV7Generator({Clock? clock, Random? random})
    : _nowMillis = (clock == null
          ? () => DateTime.now().toUtc().millisecondsSinceEpoch
          : () => clock.utcNow().millisecondsSinceEpoch),
      _random = random ?? Random.secure();

  /// Builds a generator whose timestamps come from [clock] (kept in one place
  /// so bootstrap can share the process clock).
  factory UuidV7Generator.fromClock(Clock clock) =>
      UuidV7Generator(clock: clock);

  final int Function() _nowMillis;
  final Random _random;

  static const int _counterBits = 12;
  static const int _counterMax = (1 << _counterBits) - 1;

  int _lastMillis = -1;
  int _counter = 0;

  @override
  String uuidV7() {
    int millis = _nowMillis();
    if (millis > _lastMillis) {
      _lastMillis = millis;
      // Seed the in-millisecond counter with 12 random bits so ids are not
      // trivially guessable, while leaving head-room to increment.
      _counter = _random.nextInt(1 << _counterBits) & (_counterMax >> 1);
    } else {
      // Same millisecond (or a backward clock step): keep advancing.
      millis = _lastMillis;
      _counter += 1;
      if (_counter > _counterMax) {
        // Counter exhausted: borrow from the timestamp so ordering holds.
        _lastMillis += 1;
        millis = _lastMillis;
        _counter = 0;
      }
    }

    final Uint8List bytes = Uint8List(16);
    // 48-bit big-endian millisecond timestamp.
    bytes[0] = (millis >> 40) & 0xff;
    bytes[1] = (millis >> 32) & 0xff;
    bytes[2] = (millis >> 24) & 0xff;
    bytes[3] = (millis >> 16) & 0xff;
    bytes[4] = (millis >> 8) & 0xff;
    bytes[5] = millis & 0xff;
    // Version 7 in the high nibble of byte 6, top 4 bits of the 12-bit counter.
    bytes[6] = 0x70 | ((_counter >> 8) & 0x0f);
    bytes[7] = _counter & 0xff;
    // Variant 0b10 in the top two bits of byte 8; remaining bits are rand_b.
    bytes[8] = 0x80 | (_random.nextInt(64) & 0x3f);
    for (int i = 9; i < 16; i++) {
      bytes[i] = _random.nextInt(256);
    }
    return _format(bytes);
  }

  static const String _hex = '0123456789abcdef';

  String _format(Uint8List b) {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        out.write('-');
      }
      final int byte = b[i];
      out
        ..write(_hex[(byte >> 4) & 0x0f])
        ..write(_hex[byte & 0x0f]);
    }
    return out.toString();
  }
}
