import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../widgets/kind_picker.dart';
import '../widgets/ui_widgets.dart';
import 'place_detail_screen.dart';

/// Opens the single reused Story/Poll/Place sheet (rule 6) as a modal —
/// the center "+" tab and every "add a place"/"ask a poll" shortcut in the
/// app all funnel through here with a different starting kind.
Future<void> showCreateSheet(BuildContext context, {CreateKind initial = CreateKind.story}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => CreateSheet(initial: initial),
  );
}

class CreateSheet extends StatefulWidget {
  final CreateKind initial;
  const CreateSheet({super.key, this.initial = CreateKind.story});

  @override
  State<CreateSheet> createState() => _CreateSheetState();
}

class _CreateSheetState extends State<CreateSheet> {
  late CreateKind _kind = widget.initial;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(color: tokens.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(20))),
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(color: tokens.line, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              KindPicker(active: _kind, onChanged: (k) => setState(() => _kind = k)),
              switch (_kind) {
                CreateKind.story => const _StoryForm(),
                CreateKind.poll => const _PollForm(),
                CreateKind.place => const _PlaceForm(),
              },
            ],
          ),
        ),
      ),
    );
  }
}

class _StoryForm extends StatefulWidget {
  const _StoryForm();

  @override
  State<_StoryForm> createState() => _StoryFormState();
}

class _StoryFormState extends State<_StoryForm> {
  final _textController = TextEditingController();
  bool _anon = false;
  String _place = 'main';

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final canPost = _textController.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Camera Stories are coming next — text Stories work today and post the same way (full screen, auto-advance, likes).",
          style: TextStyle(color: tokens.mute, fontSize: 13),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _textController,
          maxLength: 200,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: "What's happening?",
            hintStyle: TextStyle(color: tokens.mute),
            filled: true,
            fillColor: tokens.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          ),
          style: TextStyle(color: tokens.ink),
        ),
        const SizedBox(height: 6),
        Text('Post to', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FunkyChip(label: 'Area', active: _place == 'main', onPressed: () => setState(() => _place = 'main')),
            ...store.rankedPlaces.take(6).map((p) => FunkyChip(label: p.name, active: _place == p.id, onPressed: () => setState(() => _place = p.id))),
          ],
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: () => setState(() => _anon = !_anon),
          child: Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  border: Border.all(color: tokens.line, width: 1.5),
                  borderRadius: BorderRadius.circular(5),
                  color: _anon ? tokens.brand : Colors.transparent,
                ),
              ),
              const SizedBox(width: 10),
              Text('Post anonymously', style: TextStyle(color: tokens.ink)),
            ],
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: canPost
                ? () {
                    store.addStory(text: _textController.text.trim(), place: _place, anon: _anon);
                    Navigator.of(context).pop();
                  }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.brand,
              disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text('Post Story', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

class _PollForm extends StatefulWidget {
  const _PollForm();

  @override
  State<_PollForm> createState() => _PollFormState();
}

class _PollFormState extends State<_PollForm> {
  final _questionController = TextEditingController();
  final List<TextEditingController> _optionControllers = [TextEditingController(), TextEditingController()];

  @override
  void dispose() {
    _questionController.dispose();
    for (final c in _optionControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final filledOptions = _optionControllers.where((c) => c.text.trim().isNotEmpty).length;
    final canPost = _questionController.text.trim().isNotEmpty && filledOptions >= 2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Question', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: _questionController,
          maxLength: 80,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Best bar tonight?',
            hintStyle: TextStyle(color: tokens.mute),
            filled: true,
            fillColor: tokens.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
          style: TextStyle(color: tokens.ink),
        ),
        const SizedBox(height: 10),
        Text('Options', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        ...List.generate(_optionControllers.length, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: _optionControllers[i],
              maxLength: 40,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Option ${i + 1}',
                hintStyle: TextStyle(color: tokens.mute),
                filled: true,
                fillColor: tokens.raised,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              style: TextStyle(color: tokens.ink),
            ),
          );
        }),
        if (_optionControllers.length < 8)
          TextButton(
            onPressed: () => setState(() => _optionControllers.add(TextEditingController())),
            child: Text('+ Add option', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: canPost
                ? () {
                    final options = _optionControllers.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();
                    store.addPoll(_questionController.text.trim(), options);
                    Navigator.of(context).pop();
                  }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.brand,
              disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text('Post poll', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

const _placeKinds = [
  (PlaceKind.frat, 'Fraternity'),
  (PlaceKind.party, 'Party'),
  (PlaceKind.bar, 'Bar'),
  (PlaceKind.club, 'Club'),
  (PlaceKind.event, 'Event'),
  (PlaceKind.tailgate, 'Tailgate'),
];

class _PlaceForm extends StatefulWidget {
  const _PlaceForm();

  @override
  State<_PlaceForm> createState() => _PlaceFormState();
}

class _PlaceFormState extends State<_PlaceForm> {
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  PlaceKind _kind = PlaceKind.party;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final canPost = _nameController.text.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Name', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: _nameController,
          maxLength: 40,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Taverns Bar',
            hintStyle: TextStyle(color: tokens.mute),
            filled: true,
            fillColor: tokens.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
          style: TextStyle(color: tokens.ink),
        ),
        const SizedBox(height: 14),
        Text('Type', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _placeKinds.map((k) => FunkyChip(label: k.$2, active: _kind == k.$1, onPressed: () => setState(() => _kind = k.$1))).toList(),
        ),
        const SizedBox(height: 14),
        Text('Address', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: _addressController,
          decoration: InputDecoration(
            hintText: 'Street address',
            hintStyle: TextStyle(color: tokens.mute),
            filled: true,
            fillColor: tokens.raised,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          ),
          style: TextStyle(color: tokens.ink),
        ),
        const SizedBox(height: 6),
        Text(
          store.locationStatus == LocationStatus.granted
              ? 'The pin drops at your current location — address lookup is a near-term follow-up (see HANDOFF.md).'
              : 'Enable location first so this place can be placed on the map.',
          style: TextStyle(color: tokens.mute, fontSize: 12),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: canPost
                ? () {
                    final place = store.addPlace(_nameController.text.trim(), _kind, _addressController.text.trim().isEmpty ? 'Address not given' : _addressController.text.trim());
                    Navigator.of(context).pop();
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaceDetailScreen(placeId: place.id)));
                  }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.brand,
              disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text('Add place', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}
