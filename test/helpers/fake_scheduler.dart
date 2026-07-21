enum FakeSchedulerPermission { granted, denied, revoked }

final class ScheduledItem<T extends Object> {
  const ScheduledItem({
    required this.id,
    required this.dueAtUtc,
    required this.payload,
  });

  final String id;
  final DateTime dueAtUtc;
  final T payload;
}

final class FakeScheduler<T extends Object> {
  FakeScheduler({this.permission = FakeSchedulerPermission.granted});

  final Map<String, ScheduledItem<T>> _items = <String, ScheduledItem<T>>{};
  FakeSchedulerPermission permission;
  Exception? _nextFailure;

  List<ScheduledItem<T>> get scheduled {
    final List<ScheduledItem<T>> result = _items.values.toList();
    result.sort(_compareItems);
    return List<ScheduledItem<T>>.unmodifiable(result);
  }

  void setPermission(FakeSchedulerPermission value) {
    permission = value;
  }

  void failNext(Exception error) {
    _nextFailure = error;
  }

  Future<void> schedule(ScheduledItem<T> item) async {
    _throwInjectedFailure();
    if (permission != FakeSchedulerPermission.granted) {
      throw StateError('Scheduler permission is ${permission.name}.');
    }
    if (!item.dueAtUtc.isUtc) {
      throw ArgumentError.value(item.dueAtUtc, 'dueAtUtc', 'Must be UTC.');
    }
    if (item.id.isEmpty) {
      throw ArgumentError.value(item.id, 'id', 'Must not be empty.');
    }
    _items[item.id] = item;
  }

  Future<bool> cancel(String id) async {
    _throwInjectedFailure();
    return _items.remove(id) != null;
  }

  List<ScheduledItem<T>> dueAt(DateTime utcNow) {
    if (!utcNow.isUtc) {
      throw ArgumentError.value(utcNow, 'utcNow', 'Must be UTC.');
    }
    return List<ScheduledItem<T>>.unmodifiable(
      scheduled.where(
        (ScheduledItem<T> item) => !item.dueAtUtc.isAfter(utcNow),
      ),
    );
  }

  void _throwInjectedFailure() {
    final Exception? failure = _nextFailure;
    _nextFailure = null;
    if (failure != null) {
      throw failure;
    }
  }

  static int _compareItems<T extends Object>(
    ScheduledItem<T> left,
    ScheduledItem<T> right,
  ) {
    final int dueComparison = left.dueAtUtc.compareTo(right.dueAtUtc);
    return dueComparison == 0 ? left.id.compareTo(right.id) : dueComparison;
  }
}

enum FakeBackgroundCapability { available, unavailable, permissionDenied }

final class FakeBackgroundScheduler {
  FakeBackgroundScheduler({
    this.capability = FakeBackgroundCapability.available,
  });

  FakeBackgroundCapability capability;
  int configureCount = 0;

  Future<FakeBackgroundCapability> configure() async {
    configureCount += 1;
    return capability;
  }
}
