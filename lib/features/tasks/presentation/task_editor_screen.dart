import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/app/infrastructure/database/command/command_write.dart';
import 'package:forge/core/domain/clock.dart';
import 'package:forge/core/domain/id.dart';
import 'package:forge/core/domain/local_date.dart';
import 'package:forge/core/domain/local_date_time.dart';
import 'package:forge/core/domain/result.dart';
import 'package:forge/core/ui/forge_tokens.dart';
import 'package:forge/core/ui/localization.dart';
import 'package:forge/features/tasks/application/recurrence_commands.dart';
import 'package:forge/features/tasks/application/task_command_service.dart';
import 'package:forge/features/tasks/application/task_commands.dart';
import 'package:forge/features/tasks/application/task_detail.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_end.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_frequency.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_rule.dart';
import 'package:forge/features/tasks/domain/recurrence/recurrence_weekday.dart';
import 'package:forge/features/tasks/domain/task_due.dart';
import 'package:forge/features/tasks/domain/task_priority.dart';
import 'package:forge/features/tasks/presentation/task_labels.dart';
import 'package:forge/features/tasks/presentation/task_providers.dart';
import 'package:forge/l10n/generated/app_localizations.dart';

enum _DueType { none, date, instant }

/// Progressive-disclosure task editor (R-TASK-001, R-TASK-003, R-TASK-004,
/// R-TASK-005, R-TASK-010).
///
/// Title comes first (fast path); every other field lives behind "More
/// options" so quick capture stays one field (ux-design §7). All fields are
/// keyboard reachable with labels and validation messages that are not
/// color-only (NFR-A11Y-001/002). On a storage/validation failure the entered
/// text is retained (ux-design Error Handling).
final class TaskEditorScreen extends ConsumerStatefulWidget {
  const TaskEditorScreen({this.initial, super.key});

  /// The task being edited, or null when creating a new task.
  final TaskDetail? initial;

  bool get isEditing => initial != null;

  @override
  ConsumerState<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends ConsumerState<TaskEditorScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _dueDate;
  late final TextEditingController _dueTime;
  late final TextEditingController _scheduled;
  late final TextEditingController _estimate;
  late final TextEditingController _tags;
  late final TextEditingController _noteId;
  late final TextEditingController _parentId;
  late final TextEditingController _interval;
  late final TextEditingController _count;

  LifeAreaId? _areaId;
  String _priority = 'none';
  _DueType _dueType = _DueType.none;
  RecurrenceFrequency? _frequency;
  final Set<RecurrenceWeekday> _weekdays = <RecurrenceWeekday>{};
  bool _endAfterCount = false;
  bool _expanded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final TaskDetail? initial = widget.initial;
    _title = TextEditingController(text: initial?.title ?? '');
    _dueDate = TextEditingController(text: initial?.dueDate ?? '');
    _dueTime = TextEditingController();
    _scheduled = TextEditingController(text: initial?.scheduledDate ?? '');
    _estimate = TextEditingController(
      text: initial?.estimateMinutes?.toString() ?? '',
    );
    _tags = TextEditingController(text: initial?.tagIds.join(', ') ?? '');
    _noteId = TextEditingController(text: initial?.noteId ?? '');
    _parentId = TextEditingController(text: initial?.parentTaskId ?? '');
    _interval = TextEditingController(text: '1');
    _count = TextEditingController(text: '10');
    _priority = initial?.priorityWire ?? 'none';
    _areaId = initial == null ? null : LifeAreaId(initial.lifeAreaId);
    if (initial != null) {
      if (initial.dueDate != null) {
        _dueType = _DueType.date;
      } else if (initial.dueAtUtc != null) {
        _dueType = _DueType.instant;
      }
      _expanded = true;
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _dueDate.dispose();
    _dueTime.dispose();
    _scheduled.dispose();
    _estimate.dispose();
    _tags.dispose();
    _noteId.dispose();
    _parentId.dispose();
    _interval.dispose();
    _count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = context.l10n;
    final List<TaskAreaOption> areas = ref.watch(tasksAreaOptionsProvider);
    _areaId ??= ref.watch(tasksDefaultAreaProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isEditing ? l10n.taskEditorEditTitle : l10n.taskEditorNewTitle,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l10n.taskEditorSave),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          restorationId: 'content-task-editor',
          padding: const EdgeInsets.all(ForgeSpacing.lg),
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: ForgeSizes.formMaxWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TextFormField(
                    controller: _title,
                    autofocus: !widget.isEditing,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: l10n.taskEditorTitleLabel,
                      hintText: l10n.taskEditorTitleHint,
                    ),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty)
                        ? l10n.taskEditorTitleRequired
                        : null,
                  ),
                  const SizedBox(height: ForgeSpacing.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => _expanded = !_expanded),
                      icon: Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                      ),
                      label: Text(
                        _expanded
                            ? l10n.taskEditorFewerOptions
                            : l10n.taskEditorMoreOptions,
                      ),
                    ),
                  ),
                  if (_expanded) ..._advancedFields(context, l10n, areas),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _advancedFields(
    BuildContext context,
    AppLocalizations l10n,
    List<TaskAreaOption> areas,
  ) {
    return <Widget>[
      const SizedBox(height: ForgeSpacing.sm),
      if (areas.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: _areaId?.value,
          decoration: InputDecoration(labelText: l10n.taskEditorArea),
          items: <DropdownMenuItem<String>>[
            for (final TaskAreaOption area in areas)
              DropdownMenuItem<String>(
                value: area.id.value,
                child: Text(area.name),
              ),
          ],
          onChanged: (String? value) => setState(
            () => _areaId = value == null ? _areaId : LifeAreaId(value),
          ),
        ),
      const SizedBox(height: ForgeSpacing.sm),
      DropdownButtonFormField<String>(
        initialValue: _priority,
        decoration: InputDecoration(labelText: l10n.taskEditorPriority),
        items: <DropdownMenuItem<String>>[
          for (final String wire in const <String>[
            'none',
            'low',
            'medium',
            'high',
            'urgent',
          ])
            DropdownMenuItem<String>(
              value: wire,
              child: Text(TaskLabels.priority(l10n, wire)),
            ),
        ],
        onChanged: (String? value) =>
            setState(() => _priority = value ?? 'none'),
      ),
      const SizedBox(height: ForgeSpacing.md),
      Text(l10n.taskEditorDue, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: ForgeSpacing.xs),
      SegmentedButton<_DueType>(
        segments: <ButtonSegment<_DueType>>[
          ButtonSegment<_DueType>(
            value: _DueType.none,
            label: Text(l10n.taskEditorDueNone),
          ),
          ButtonSegment<_DueType>(
            value: _DueType.date,
            label: Text(l10n.taskEditorDueDate),
          ),
          ButtonSegment<_DueType>(
            value: _DueType.instant,
            label: Text(l10n.taskEditorDueInstant),
          ),
        ],
        selected: <_DueType>{_dueType},
        onSelectionChanged: (Set<_DueType> value) =>
            setState(() => _dueType = value.first),
      ),
      if (_dueType != _DueType.none) ...<Widget>[
        const SizedBox(height: ForgeSpacing.sm),
        TextFormField(
          controller: _dueDate,
          decoration: InputDecoration(labelText: l10n.taskEditorDate),
          validator: _validateOptionalDate,
        ),
      ],
      if (_dueType == _DueType.instant) ...<Widget>[
        const SizedBox(height: ForgeSpacing.sm),
        TextFormField(
          controller: _dueTime,
          decoration: InputDecoration(labelText: l10n.taskEditorTime),
          validator: _validateOptionalTime,
        ),
      ],
      const SizedBox(height: ForgeSpacing.sm),
      TextFormField(
        controller: _scheduled,
        decoration: InputDecoration(labelText: l10n.taskEditorScheduledDate),
        validator: _validateOptionalDate,
      ),
      const SizedBox(height: ForgeSpacing.sm),
      TextFormField(
        controller: _estimate,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: l10n.taskEditorEstimate),
      ),
      const SizedBox(height: ForgeSpacing.sm),
      TextFormField(
        controller: _tags,
        decoration: InputDecoration(labelText: l10n.taskEditorTags),
      ),
      const SizedBox(height: ForgeSpacing.sm),
      TextFormField(
        controller: _noteId,
        decoration: InputDecoration(labelText: l10n.taskEditorNoteId),
      ),
      const SizedBox(height: ForgeSpacing.sm),
      TextFormField(
        controller: _parentId,
        decoration: InputDecoration(labelText: l10n.taskEditorParentId),
      ),
      if (!widget.isEditing) ..._recurrenceFields(context, l10n),
    ];
  }

  List<Widget> _recurrenceFields(BuildContext context, AppLocalizations l10n) {
    return <Widget>[
      const SizedBox(height: ForgeSpacing.md),
      Text(
        l10n.taskEditorRecurrence,
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: ForgeSpacing.xs),
      DropdownButtonFormField<String>(
        initialValue: _frequency?.wire ?? 'none',
        decoration: InputDecoration(labelText: l10n.taskEditorRecurrence),
        items: <DropdownMenuItem<String>>[
          DropdownMenuItem<String>(
            value: 'none',
            child: Text(l10n.recurrenceNone),
          ),
          DropdownMenuItem<String>(
            value: 'daily',
            child: Text(l10n.recurrenceDaily),
          ),
          DropdownMenuItem<String>(
            value: 'weekly',
            child: Text(l10n.recurrenceWeekly),
          ),
          DropdownMenuItem<String>(
            value: 'monthly',
            child: Text(l10n.recurrenceMonthly),
          ),
          DropdownMenuItem<String>(
            value: 'yearly',
            child: Text(l10n.recurrenceYearly),
          ),
        ],
        onChanged: (String? value) => setState(() {
          _frequency = (value == null || value == 'none')
              ? null
              : RecurrenceFrequency.fromWire(value);
        }),
      ),
      if (_frequency != null) ...<Widget>[
        const SizedBox(height: ForgeSpacing.sm),
        TextFormField(
          controller: _interval,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: l10n.recurrenceInterval),
        ),
        if (_frequency == RecurrenceFrequency.weekly) ...<Widget>[
          const SizedBox(height: ForgeSpacing.sm),
          Wrap(
            spacing: ForgeSpacing.xs,
            children: <Widget>[
              for (final RecurrenceWeekday day in RecurrenceWeekday.values)
                FilterChip(
                  label: Text(day.wire),
                  selected: _weekdays.contains(day),
                  onSelected: (bool value) => setState(() {
                    if (value) {
                      _weekdays.add(day);
                    } else {
                      _weekdays.remove(day);
                    }
                  }),
                ),
            ],
          ),
        ],
        const SizedBox(height: ForgeSpacing.sm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.recurrenceEndAfter),
          value: _endAfterCount,
          onChanged: (bool value) => setState(() => _endAfterCount = value),
        ),
        if (_endAfterCount)
          TextFormField(
            controller: _count,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l10n.recurrenceEndCount),
          ),
      ],
    ];
  }

  String? _validateOptionalDate(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    try {
      LocalDate.parse(value.trim());
      return null;
    } on FormatException {
      return context.l10n.taskEditorInvalidDate;
    }
  }

  String? _validateOptionalTime(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null;
    }
    try {
      LocalTime.parse(value.trim());
      return null;
    } on FormatException {
      return context.l10n.taskEditorInvalidTime;
    }
  }

  Future<void> _save() async {
    final AppLocalizations l10n = context.l10n;
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final TaskCommandService? commands = ref.read(tasksCommandServiceProvider);
    final ProfileId? profile = ref.read(tasksProfileProvider);
    final Clock clock = ref.read(tasksClockProvider);
    if (commands == null || profile == null) {
      _showError(l10n, 'tasks.unavailable');
      return;
    }

    final TaskDue? due = _buildDue(clock);
    if (due == null && _dueType != _DueType.none) {
      _showError(l10n, 'task.invalid_field');
      return;
    }

    setState(() => _saving = true);
    final CommandId Function() nextId = ref.read(tasksCommandIdFactoryProvider);

    Result<CommittedCommandResult> result;
    String? createdId;
    if (widget.isEditing) {
      result = await commands.update(
        commandId: nextId(),
        profileId: profile,
        taskId: TaskId(widget.initial!.id),
        input: UpdateTaskInput(
          title: _title.text.trim(),
          priority: TaskPriority.fromWire(_priority),
          due: due ?? TaskDue.none,
          scheduledDate: Opt<String?>(_trimOrNull(_scheduled.text)),
          estimateMinutes: Opt<int?>(_intOrNull(_estimate.text)),
          noteId: Opt<NoteId?>(_noteOrNull(_noteId.text)),
          lifeAreaId: _areaId,
        ),
      );
    } else {
      final LifeAreaId? area = _areaId;
      if (area == null) {
        setState(() => _saving = false);
        _showError(l10n, 'tasks.unavailable');
        return;
      }
      result = await commands.create(
        commandId: nextId(),
        profileId: profile,
        input: CreateTaskInput(
          lifeAreaId: area,
          title: _title.text.trim(),
          priority: TaskPriority.fromWire(_priority),
          due: due ?? TaskDue.none,
          scheduledDate: _trimOrNull(_scheduled.text),
          estimateMinutes: _intOrNull(_estimate.text),
          noteId: _noteOrNull(_noteId.text),
          parentTaskId: _parentOrNull(_parentId.text),
          tagIds: _tagList(),
        ),
      );
      createdId = result.valueOrNull == null
          ? null
          : _idFromPayload(result.valueOrNull!.resultPayload);
    }

    // Attach recurrence for a freshly created task (R-TASK-005).
    if (!widget.isEditing &&
        _frequency != null &&
        createdId != null &&
        result is Success<CommittedCommandResult>) {
      final recurrence = ref.read(tasksRecurrenceServiceProvider);
      final RecurrenceRule? rule = _buildRule(clock, due);
      if (recurrence != null && rule != null) {
        await recurrence.setRecurrence(
          commandId: nextId(),
          profileId: profile,
          taskId: TaskId(createdId),
          input: SetRecurrenceInput(rule: rule),
        );
      }
    }

    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    switch (result) {
      case Success<CommittedCommandResult>():
        Navigator.of(context).pop(true);
      case Failed<CommittedCommandResult>(failure: final Failure failure):
        _showError(l10n, failure.code);
    }
  }

  TaskDue? _buildDue(Clock clock) {
    switch (_dueType) {
      case _DueType.none:
        return TaskDue.none;
      case _DueType.date:
        final String date = _dueDate.text.trim();
        if (date.isEmpty) {
          return null;
        }
        try {
          LocalDate.parse(date);
          return TaskDue.onDate(date);
        } on FormatException {
          return null;
        }
      case _DueType.instant:
        final String date = _dueDate.text.trim();
        final String time = _dueTime.text.trim();
        if (date.isEmpty || time.isEmpty) {
          return null;
        }
        try {
          final LocalDate d = LocalDate.parse(date);
          final LocalTime t = LocalTime.parse(time);
          final int micros = DateTime.utc(
            d.year,
            d.month,
            d.day,
            t.hour,
            t.minute,
            t.second,
          ).microsecondsSinceEpoch;
          return TaskDue.atInstant(
            utcMicros: micros,
            timezoneId: clock.timezoneId(),
          );
        } on FormatException {
          return null;
        }
    }
  }

  RecurrenceRule? _buildRule(Clock clock, TaskDue? due) {
    final RecurrenceFrequency? freq = _frequency;
    if (freq == null) {
      return null;
    }
    final String startIso =
        due?.dueDate ??
        (_scheduled.text.trim().isNotEmpty ? _scheduled.text.trim() : null) ??
        _todayIso(clock);
    try {
      final LocalDate start = LocalDate.parse(startIso);
      final int interval = int.tryParse(_interval.text.trim()) ?? 1;
      final RecurrenceEnd end = _endAfterCount
          ? RecurrenceEnd.count(int.tryParse(_count.text.trim()) ?? 1)
          : RecurrenceEnd.never;
      return RecurrenceRule(
        frequency: freq,
        start: start,
        timezoneId: clock.timezoneId(),
        interval: interval < 1 ? 1 : interval,
        byWeekdays: freq == RecurrenceFrequency.weekly && _weekdays.isNotEmpty
            ? _weekdays
            : null,
        end: end,
      );
    } on FormatException {
      return null;
    }
  }

  void _showError(AppLocalizations l10n, String code) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(TaskLabels.failure(l10n, code))));
  }

  List<String> _tagList() => _tags.text
      .split(',')
      .map((String t) => t.trim())
      .where((String t) => t.isNotEmpty)
      .toList(growable: false);

  static String? _trimOrNull(String value) =>
      value.trim().isEmpty ? null : value.trim();

  static int? _intOrNull(String value) => int.tryParse(value.trim());

  static NoteId? _noteOrNull(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      return NoteId(trimmed);
    } on FormatException {
      return null;
    }
  }

  static TaskId? _parentOrNull(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      return TaskId(trimmed);
    } on FormatException {
      return null;
    }
  }

  static String _todayIso(Clock clock) {
    final DateTime now = clock.utcNow();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  static String? _idFromPayload(String? payload) {
    if (payload == null) {
      return null;
    }
    final RegExp idPattern = RegExp(r'"id"\s*:\s*"([^"]+)"');
    return idPattern.firstMatch(payload)?.group(1);
  }
}
