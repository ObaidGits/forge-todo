import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/home/presentation/home_providers.dart';

/// The pinned title-only quick capture at the top of Today (R-HOME-003,
/// R-TASK-001, NFR-USAB-001).
///
/// It is always available (offline included, R-GEN-001), keeps the entered text
/// on validation or storage failure (ux-design Error Handling), and shows
/// committed feedback inline once the command bus returns a durable receipt —
/// never on dispatch acknowledgement (R-GEN-005).
final class QuickCaptureField extends ConsumerStatefulWidget {
  const QuickCaptureField({super.key});

  @override
  ConsumerState<QuickCaptureField> createState() => _QuickCaptureFieldState();
}

class _QuickCaptureFieldState extends ConsumerState<QuickCaptureField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final String title = _controller.text;
    final bool committed = await ref
        .read(quickCaptureControllerProvider.notifier)
        .submit(title);
    if (!mounted) {
      return;
    }
    if (committed) {
      _controller.clear();
      // Keep focus so the user can capture several items quickly (fast path).
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final QuickCaptureState capture = ref.watch(quickCaptureControllerProvider);
    final bool saving = capture is QuickCaptureSaving;

    // Surface a retained input after a failure without clobbering active typing.
    ref.listen<QuickCaptureState>(quickCaptureControllerProvider, (
      QuickCaptureState? previous,
      QuickCaptureState next,
    ) {
      if (next is QuickCaptureFailed &&
          next.retainedInput.isNotEmpty &&
          _controller.text.isEmpty) {
        _controller.text = next.retainedInput;
      }
    });

    final ThemeData theme = Theme.of(context);
    final String? errorText = switch (capture) {
      QuickCaptureFailed(failure: final failure) => _messageFor(
        context,
        failure.code,
      ),
      _ => null,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: context.l10n.quickCaptureLabel,
                  hintText: context.l10n.quickCaptureHint,
                  errorText: errorText,
                  prefixIcon: const Icon(Icons.add_task),
                ),
              ),
            ),
            const SizedBox(width: ForgeSpacing.xs),
            Padding(
              padding: const EdgeInsets.only(top: ForgeSpacing.xxs),
              child: SizedBox(
                height: ForgeSizes.minimumInteractiveDimension,
                child: FilledButton(
                  onPressed: saving ? null : _submit,
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(context.l10n.quickCaptureSubmit),
                ),
              ),
            ),
          ],
        ),
        if (capture is QuickCaptureCommitted)
          Padding(
            padding: const EdgeInsets.only(top: ForgeSpacing.xs),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.check_circle,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: ForgeSpacing.xxs),
                Text(
                  context.l10n.quickCaptureAdded,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _messageFor(BuildContext context, String code) {
    return switch (code) {
      'home.capture_empty_title' => context.l10n.quickCaptureEmpty,
      'home.capture_unavailable' => context.l10n.quickCaptureUnavailable,
      _ => context.l10n.errorUnexpected,
    };
  }
}
