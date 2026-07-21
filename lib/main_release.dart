import 'package:flutter/widgets.dart';
import 'package:forge/app/composition_root.dart';
import 'package:forge/config/app_config.dart';
import 'package:forge/forge_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final AppConfig config = AppConfig.fromEnvironment()..validateForRelease();
  runApp(
    ForgeCompositionRoot(
      config: config,
      child: ForgeApp(config: config),
    ),
  );
}
