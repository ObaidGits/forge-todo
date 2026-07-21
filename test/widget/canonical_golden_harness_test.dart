import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/helpers.dart';

void main() {
  final EvidenceMetadata evidence = EvidenceMetadata(
    evidenceId: EvidenceId('GOLDEN-REL-SETUP-001'),
    releaseTag: ReleaseTag.mvp,
    taskId: SpecTaskId('2.6'),
    requirements: <RequirementId>[RequirementId('NFR-REL-004')],
  );

  testWidgetsWithEvidence(
    evidence,
    'canonical setup pins viewport locale text scale contrast and platform',
    (WidgetTester tester) async {
      const CanonicalGoldenVariant variant = CanonicalGoldenVariant(
        viewport: GoldenViewport.expanded,
        brightness: Brightness.dark,
        textScale: 2,
        highContrast: true,
      );
      await pumpCanonicalGolden(
        tester,
        const Builder(builder: _captureEnvironment),
        variant: variant,
      );

      expect(find.text('1440x1024|2.0|true|dark|linux|en_US'), findsOneWidget);
      expect(variant.suffix, 'expanded-dark-2.0x-high-contrast');
      expect(canonicalGoldenVariants, hasLength(3));
      expect(
        canonicalGoldenVariants.map(
          (CanonicalGoldenVariant value) => value.viewport,
        ),
        containsAll(GoldenViewport.values),
      );
    },
  );
}

Widget _captureEnvironment(BuildContext context) {
  final MediaQueryData media = MediaQuery.of(context);
  final ThemeData theme = Theme.of(context);
  final Locale locale = Localizations.localeOf(context);
  return Text(
    '${media.size.width.toInt()}x${media.size.height.toInt()}|'
    '${media.textScaler.scale(1)}|${media.highContrast}|'
    '${theme.brightness.name}|${theme.platform.name}|$locale',
  );
}
