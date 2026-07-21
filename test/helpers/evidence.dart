import 'package:flutter_test/flutter_test.dart';

enum ReleaseTag {
  mvp('MVP'),
  v1('V1'),
  postV1('Post-V1');

  const ReleaseTag(this.label);
  final String label;
}

final class EvidenceId {
  EvidenceId(String value) : value = _validate(value);

  final String value;

  static String _validate(String value) {
    if (!_pattern.hasMatch(value) || value.contains('--')) {
      throw FormatException('Invalid automated evidence ID: $value');
    }
    return value;
  }

  static final RegExp _pattern = RegExp(
    r'^(?:TEST|AUTO|WIDGET|GOLDEN)(?:-[A-Z0-9]+){2,}$',
  );
}

final class RequirementId {
  RequirementId(String value) : value = _validate(value);

  final String value;

  static String _validate(String value) {
    if (!_pattern.hasMatch(value)) {
      throw FormatException('Invalid exact requirement ID: $value');
    }
    return value;
  }

  static final RegExp _pattern = RegExp(r'^(?:R|NFR)-[A-Z]+-[0-9]{3}$');
}

final class SpecTaskId {
  SpecTaskId(String value) : value = _validate(value);

  final String value;

  static String _validate(String value) {
    if (!_pattern.hasMatch(value)) {
      throw FormatException('Invalid leaf task ID: $value');
    }
    return value;
  }

  static final RegExp _pattern = RegExp(r'^[1-9][0-9]*\.[1-9][0-9]*$');
}

final class EvidenceMetadata {
  EvidenceMetadata({
    required this.evidenceId,
    required this.releaseTag,
    required this.taskId,
    required Iterable<RequirementId> requirements,
  }) : requirements = List<RequirementId>.unmodifiable(requirements) {
    if (this.requirements.isEmpty) {
      throw ArgumentError.value(
        requirements,
        'requirements',
        'Must not be empty.',
      );
    }
    final Set<String> exactIds = this.requirements
        .map((RequirementId requirement) => requirement.value)
        .toSet();
    if (exactIds.length != this.requirements.length) {
      throw ArgumentError.value(
        requirements,
        'requirements',
        'Must not contain duplicate exact requirement IDs.',
      );
    }
  }

  final EvidenceId evidenceId;
  final ReleaseTag releaseTag;
  final SpecTaskId taskId;
  final List<RequirementId> requirements;

  String testName(String behavior) {
    if (behavior.trim().isEmpty) {
      throw ArgumentError.value(behavior, 'behavior', 'Must not be empty.');
    }
    final String requirementList = requirements
        .map((RequirementId requirement) => requirement.value)
        .join(',');
    return '[${evidenceId.value}][${releaseTag.label}]'
        '[TASK-${taskId.value}][$requirementList] $behavior';
  }
}

void testWithEvidence(
  EvidenceMetadata metadata,
  String behavior,
  dynamic Function() body,
) {
  test(metadata.testName(behavior), body);
}

void testWidgetsWithEvidence(
  EvidenceMetadata metadata,
  String behavior,
  WidgetTesterCallback body,
) {
  testWidgets(metadata.testName(behavior), body);
}
