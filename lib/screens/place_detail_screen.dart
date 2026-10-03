import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../data/models.dart';
import '../widgets/ui_widgets.dart';
import 'place_story_viewer_screen.dart';

class PlaceDetailScreen extends StatefulWidget {
  final String placeId;
  const PlaceDetailScreen({super.key, required this.placeId});

  @override
  State<PlaceDetailScreen> createState() => _PlaceDetailScreenState();
}

class _PlaceDetailScreenState extends State<PlaceDetailScreen> {
  final _coverController = TextEditingController();

  @override
  void dispose() {
    _coverController.dispose();
    super.dispose();
  }

  void _submit(AppStore store, ReportKind kind, {String? detail}) {
    store.submitReport(widget.placeId, kind, detail: detail);
  }

  void _confirm(AppStore store, String reportId) {
    final error = store.confirmReport(reportId);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    RankedPlace? found;
    for (final p in store.rankedPlaces) {
      if (p.id == widget.placeId) {
        found = p;
        break;
      }
    }

    if (found == null) {
      return Scaffold(
        backgroundColor: tokens.bg,
        appBar: AppBar(backgroundColor: tokens.bg),
        body: Padding(
          padding: const EdgeInsets.all(20),
          child: Text("This place isn't around anymore tonight.", style: TextStyle(color: tokens.ink)),
        ),
      );
    }

    final place = found;
    final going = store.me.move == place.id;
    final reports = store.reportsFor(place.id);
    final venueStories = store.storiesFor(place.id);
    final venueVerified = store.isPlaceVerified(place.id);
    final venueConfirmations = store.venueConfirmationCount(place.id);
    final iConfirmedVenue = store.hasConfirmedPlace(place.id);

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: Text(place.name)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          GestureDetector(
            onTap: venueStories.isEmpty
                ? null
                : () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => PlaceStoryViewerScreen(placeId: place.id, placeName: place.name)),
                    ),
            child: Container(
              height: 160,
              decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(18)),
              alignment: Alignment.center,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(place.name.substring(0, 1), style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: tokens.mute)),
                  if (venueStories.isNotEmpty)
                    Positioned(
                      bottom: 10,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(color: tokens.brand, borderRadius: BorderRadius.circular(999)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.camera_alt, color: Colors.white, size: 13),
                            const SizedBox(width: 5),
                            Text(
                              '${venueStories.length} Stor${venueStories.length == 1 ? 'y' : 'ies'} tonight',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(place.name, style: TextStyle(color: tokens.ink, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${place.address} · ${formatMiles(place.distance)}', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => store.setMove(going ? 'in' : place.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: going ? tokens.raised : tokens.brand,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: Text(
                going ? "You're going ✓" : "I'm going",
                style: TextStyle(color: going ? tokens.ink : tokens.onOrange, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('🔥 ${place.going} going tonight', style: TextStyle(color: tokens.mute)),
          const SizedBox(height: 20),
          FunkyCard(
            child: Row(
              children: [
                Icon(venueVerified ? Icons.verified : Icons.help_outline, color: venueVerified ? tokens.gold : tokens.mute, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        venueVerified ? 'Verified venue' : 'Is this venue real & active?',
                        style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$venueConfirmations of ${AppStore.venueVerificationThreshold} confirmations',
                        style: TextStyle(color: tokens.mute, fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  onPressed: iConfirmedVenue ? null : () => store.confirmPlace(place.id),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: iConfirmedVenue ? tokens.raised : tokens.brand,
                    disabledBackgroundColor: tokens.raised,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(
                    iConfirmedVenue ? 'Confirmed ✓' : 'Confirm',
                    style: TextStyle(color: iConfirmedVenue ? tokens.ink : tokens.onOrange, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          FunkyCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Reports tonight', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Text(
                  'Unverified until 8 different people confirm it — nobody can tell who reported or confirmed.',
                  style: TextStyle(color: tokens.mute, fontSize: 12.5),
                ),
                const SizedBox(height: 14),
                // Cover charge has a typed detail ("$15"), so it gets its own
                // input row instead of the generic one-tap button below.
                _ReportTile(
                  label: reports[ReportKind.cover]?.detail != null ? '${reports[ReportKind.cover]!.detail} cover' : 'Cover charge',
                  report: reports[ReportKind.cover],
                  onConfirm: (id) => _confirm(store, id),
                  trailing: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: TextField(
                          controller: _coverController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            hintText: '\$ amount',
                            hintStyle: TextStyle(color: tokens.mute),
                            filled: true,
                            fillColor: tokens.raised,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                          ),
                          style: TextStyle(color: tokens.ink),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          final amt = int.tryParse(_coverController.text);
                          if (amt == null || amt < 0) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a cover amount first')));
                            return;
                          }
                          _submit(store, ReportKind.cover, detail: '\$$amt');
                          _coverController.clear();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: tokens.raised,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 24),
                _ReportTile(
                  label: '🚨 Police',
                  report: reports[ReportKind.police],
                  onConfirm: (id) => _confirm(store, id),
                  trailing: ElevatedButton(
                    onPressed: () => _submit(store, ReportKind.police),
                    style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  ),
                ),
                const Divider(height: 24),
                _ReportTile(
                  label: 'Shut down',
                  report: reports[ReportKind.shutdown],
                  onConfirm: (id) => _confirm(store, id),
                  trailing: ElevatedButton(
                    onPressed: () => _submit(store, ReportKind.shutdown),
                    style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  ),
                ),
                const Divider(height: 24),
                _ReportTile(
                  label: reports[ReportKind.line]?.detail != null ? 'Line · ${reports[ReportKind.line]!.detail}' : 'Line / wait',
                  report: reports[ReportKind.line],
                  onConfirm: (id) => _confirm(store, id),
                  trailing: ElevatedButton(
                    onPressed: () => _submit(store, ReportKind.line, detail: '20 min'),
                    style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  ),
                ),
                const Divider(height: 24),
                _ReportTile(
                  label: 'At capacity',
                  report: reports[ReportKind.capacity],
                  onConfirm: (id) => _confirm(store, id),
                  trailing: ElevatedButton(
                    onPressed: () => _submit(store, ReportKind.capacity),
                    style: ElevatedButton.styleFrom(backgroundColor: tokens.raised, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                    child: Text('Report', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One report kind's current state: the label, the verified/unverified
/// status line with its real confirmation count, a big Confirm/Confirmed✓
/// button when there's an active report, and a "report it fresh" control
/// (a text input + button for cover, a plain button for everything else)
/// passed in as [trailing].
class _ReportTile extends StatelessWidget {
  final String label;
  final PlaceReport? report;
  final void Function(String reportId) onConfirm;
  final Widget trailing;
  const _ReportTile({required this.label, required this.report, required this.onConfirm, required this.trailing});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final r = report;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 6),
        if (r == null)
          Text('No report yet tonight.', style: TextStyle(color: tokens.mute, fontSize: 12.5))
        else
          Row(
            children: [
              Icon(
                r.verified ? Icons.verified : Icons.warning_amber_rounded,
                size: 16,
                color: r.verified ? tokens.gold : tokens.mute,
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  r.verified
                      ? '✓ VERIFIED · Confirmed by ${r.confirmations} ${r.confirmations == 1 ? 'person' : 'people'}'
                      : '⚠️ UNVERIFIED · Confirmed by ${r.confirmations} ${r.confirmations == 1 ? 'person' : 'people'}',
                  style: TextStyle(
                    color: r.verified ? tokens.gold : tokens.mute,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                  ),
                ),
              ),
            ],
          ),
        if (r != null) ...[
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              onPressed: r.confirmedBy.contains('me') ? null : () => onConfirm(r.id),
              style: ElevatedButton.styleFrom(
                backgroundColor: r.confirmedBy.contains('me') ? tokens.raised : tokens.brand,
                disabledBackgroundColor: tokens.raised,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                r.confirmedBy.contains('me') ? 'Confirmed ✓' : 'Confirm',
                style: TextStyle(
                  color: r.confirmedBy.contains('me') ? tokens.ink : tokens.onOrange,
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ] else
          const SizedBox(height: 4),
        trailing,
      ],
    );
  }
}
