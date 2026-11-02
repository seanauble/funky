import 'package:flutter/material.dart';
import '../widgets/kind_picker.dart';
import 'create_flow_screen.dart';

/// Opens the camera-first create flow (lib/screens/create_flow_screen.dart)
/// as a full-screen route — the center "+" tab and every "add a
/// place"/"ask a poll" shortcut in the app all funnel through here with a
/// different starting kind. This used to open a bottom sheet with a
/// Story/Poll/Place picker; it's a full screen now so the Story option can
/// open straight into the live camera instead of a form.
///
/// [eventAtPlaceId] opens straight into "add an event" at that bar or club
/// (an owner posting from their place's page).
Future<void> showCreateSheet(BuildContext context, {CreateKind initial = CreateKind.story, String? eventAtPlaceId}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CreateFlowScreen(initial: eventAtPlaceId != null ? CreateKind.place : initial, eventAtPlaceId: eventAtPlaceId),
    ),
  );
}
