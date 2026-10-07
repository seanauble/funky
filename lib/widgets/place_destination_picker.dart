import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import 'ui_widgets.dart';

/// One compact "Post to: Area ▾" button. With lots of places nearby a row of
/// chips gets huge, so the choice lives in a searchable sheet instead.
/// [value] is 'main' (the whole area) or a place id.
class PlaceDestinationPill extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  // True over the camera/photo (white on dark); false on a normal page.
  final bool onDark;
  const PlaceDestinationPill({super.key, required this.value, required this.onChanged, this.onDark = false});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    var label = 'Area';
    if (value != 'main') {
      for (final p in store.rankedPlaces) {
        if (p.id == value) {
          label = p.name;
          break;
        }
      }
    }
    final fg = onDark ? Colors.white : tokens.ink;
    return GestureDetector(
      onTap: () async {
        final picked = await _pickDestination(context, value);
        if (picked != null) onChanged(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: onDark ? Colors.black54 : tokens.raised,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: onDark ? Colors.white24 : tokens.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(value == 'main' ? Icons.public : Icons.place_outlined, size: 16, color: fg),
            const SizedBox(width: 6),
            Text('Post to: ', style: TextStyle(color: onDark ? Colors.white70 : tokens.mute, fontSize: 13)),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 13)),
            ),
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down_rounded, size: 20, color: fg),
          ],
        ),
      ),
    );
  }
}

Future<String?> _pickDestination(BuildContext context, String current) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    builder: (_) => _DestinationSheet(current: current),
  );
}

class _DestinationSheet extends StatefulWidget {
  final String current;
  const _DestinationSheet({required this.current});

  @override
  State<_DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends State<_DestinationSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final q = _query.trim().toLowerCase();
    final places = store.rankedPlaces.where((p) => q.isEmpty || p.name.toLowerCase().contains(q)).toList()
      ..sort((a, b) => a.distance.compareTo(b.distance));
    final showArea = q.isEmpty || 'area'.contains(q);

    Widget mark(bool on) => on ? Icon(Icons.check_rounded, color: tokens.brand) : const SizedBox.shrink();

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Post to', style: TextStyle(color: tokens.ink, fontSize: 17, fontWeight: FontWeight.w800)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: tokens.ink),
                decoration: InputDecoration(
                  hintText: 'Search places',
                  hintStyle: TextStyle(color: tokens.mute),
                  prefixIcon: Icon(Icons.search, color: tokens.mute),
                  filled: true,
                  fillColor: tokens.raised,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  if (showArea)
                    ListTile(
                      onTap: () => Navigator.of(context).pop('main'),
                      leading: Icon(Icons.public, color: tokens.ink),
                      title: Text('Area', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      subtitle: Text('Everyone within 25 miles', style: TextStyle(color: tokens.mute, fontSize: 12)),
                      trailing: mark(widget.current == 'main'),
                    ),
                  for (final p in places)
                    ListTile(
                      onTap: () => Navigator.of(context).pop(p.id),
                      leading: Icon(Icons.place_outlined, color: tokens.ink),
                      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      subtitle: Text(formatMiles(p.distance), style: TextStyle(color: tokens.mute, fontSize: 12)),
                      trailing: mark(widget.current == p.id),
                    ),
                  if (!showArea && places.isEmpty)
                    Padding(padding: const EdgeInsets.all(20), child: EmptyNote(text: 'No places match that.')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
