import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iPhone-style pieces used across FUNKY instead of Android/Material ones:
/// alerts, action sheets and the spinning date/time wheel.

/// Shows an iOS alert. [builder] usually returns an [IosAlert].
Future<T?> showIosDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  // Accepted for drop-in use where showDialog was; iOS alerts don't use it.
  Color? barrierColor,
  bool useRootNavigator = true,
}) {
  return showCupertinoDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    useRootNavigator: useRootNavigator,
    builder: builder,
  );
}

const _destructiveWords = ['delete', 'remove', 'ban', 'block', 'report', 'leave', 'sign out', 'log out', 'unfriend', 'end', 'clear'];

/// An iOS alert with the same shape as Material's AlertDialog (title,
/// content, actions), so screens can switch over without other changes.
/// Buttons given as TextButton/ElevatedButton are turned into iOS alert
/// buttons — red for delete/remove/ban and the like, bold for the last one.
class IosAlert extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  // Material-only options, accepted and ignored.
  final Color? backgroundColor;
  final ShapeBorder? shape;
  final MainAxisAlignment? actionsAlignment;
  final EdgeInsetsGeometry? contentPadding;
  final EdgeInsetsGeometry? titlePadding;
  final EdgeInsetsGeometry? actionsPadding;
  final EdgeInsets? insetPadding;
  final bool scrollable;
  final Widget? icon;

  const IosAlert({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.backgroundColor,
    this.shape,
    this.actionsAlignment,
    this.contentPadding,
    this.titlePadding,
    this.actionsPadding,
    this.insetPadding,
    this.scrollable = false,
    this.icon,
  });

  static String? _label(Widget? w) {
    if (w is Text) return w.data ?? w.textSpan?.toPlainText();
    return null;
  }

  Widget _toIos(Widget action, bool last) {
    VoidCallback? onPressed;
    Widget? child;
    if (action is ButtonStyleButton) {
      onPressed = action.onPressed;
      child = action.child;
    } else {
      return action;
    }
    final label = _label(child);
    final lower = (label ?? '').toLowerCase();
    final destructive = _destructiveWords.any((w) => lower.startsWith(w) || lower.contains(' $w'));
    return CupertinoDialogAction(
      onPressed: onPressed,
      isDestructiveAction: destructive,
      isDefaultAction: last && !destructive && lower != 'cancel',
      child: label != null ? Text(label) : (child ?? const SizedBox.shrink()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = actions ?? const <Widget>[];
    return CupertinoAlertDialog(
      title: title == null ? null : DefaultTextStyle.merge(style: const TextStyle(fontWeight: FontWeight.w700), child: title!),
      // Text fields and buttons inside need a Material ancestor.
      content: content == null ? null : Material(type: MaterialType.transparency, child: content!),
      actions: [for (var i = 0; i < list.length; i++) _toIos(list[i], i == list.length - 1)],
    );
  }
}

/// One button in an iOS action sheet.
class IosSheetAction<T> {
  final String label;
  final T value;
  final bool destructive;
  final IconData? icon;
  const IosSheetAction(this.label, this.value, {this.destructive = false, this.icon});
}

/// An iOS action sheet (slides up from the bottom, with a Cancel button).
/// Returns the picked action's value, or null.
Future<T?> showIosActionSheet<T>(
  BuildContext context, {
  String? title,
  String? message,
  Widget? header,
  required List<IosSheetAction<T>> actions,
  String cancelLabel = 'Cancel',
}) {
  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetContext) => CupertinoActionSheet(
      title: title == null ? null : Text(title),
      message: header ?? (message == null ? null : Text(message)),
      actions: [
        for (final a in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: a.destructive,
            onPressed: () => Navigator.of(sheetContext).pop(a.value),
            child: a.icon == null
                ? Text(a.label)
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(a.icon, size: 21, color: a.destructive ? CupertinoColors.destructiveRed : CupertinoColors.activeBlue),
                      const SizedBox(width: 8),
                      Flexible(child: Text(a.label)),
                    ],
                  ),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.of(sheetContext).pop(),
        child: Text(cancelLabel),
      ),
    ),
  );
}

/// The iOS date/time wheel in a sheet with Cancel and Done. Returns the
/// picked moment, or null if cancelled.
Future<DateTime?> showIosDateTimePicker(
  BuildContext context, {
  required DateTime initial,
  DateTime? minimum,
  DateTime? maximum,
  CupertinoDatePickerMode mode = CupertinoDatePickerMode.dateAndTime,
  String title = '',
  int minuteInterval = 5,
}) {
  var picked = initial;
  // The wheel needs a start that sits on its minute steps and in range.
  var start = DateTime(initial.year, initial.month, initial.day, initial.hour, initial.minute - initial.minute % minuteInterval);
  if (minimum != null) {
    // Line the earliest allowed time up with the wheel's minute steps too.
    final m = minimum.minute % minuteInterval;
    if (m != 0) minimum = DateTime(minimum.year, minimum.month, minimum.day, minimum.hour, minimum.minute - m + minuteInterval);
  }
  if (minimum != null && start.isBefore(minimum)) start = minimum;
  if (maximum != null && start.isAfter(maximum)) start = maximum;
  picked = start;
  return showCupertinoModalPopup<DateTime>(
    context: context,
    builder: (sheetContext) {
      final bg = CupertinoColors.systemBackground.resolveFrom(sheetContext);
      return Container(
        height: 330,
        decoration: BoxDecoration(color: bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(14))),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              SizedBox(
                height: 48,
                child: Row(
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      child: const Text('Cancel'),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: CupertinoColors.label.resolveFrom(sheetContext),
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      onPressed: () => Navigator.of(sheetContext).pop(picked),
                      child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ),
              Container(height: 0.5, color: CupertinoColors.separator.resolveFrom(sheetContext)),
              Expanded(
                child: CupertinoDatePicker(
                  mode: mode,
                  initialDateTime: start,
                  minimumDate: minimum,
                  maximumDate: maximum,
                  minuteInterval: minuteInterval,
                  use24hFormat: false,
                  onDateTimeChanged: (d) => picked = d,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
