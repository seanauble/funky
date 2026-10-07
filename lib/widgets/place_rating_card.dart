import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/place_rating.dart';
import '../screens/account_screen.dart';
import 'ui_widgets.dart';

/// A read-only row of five orange stars filled to [value] (halves count).
class StarRow extends StatelessWidget {
  final double value;
  final double size;
  const StarRow({super.key, required this.value, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 5; i++)
          Icon(
            value >= i + 1
                ? Icons.star_rounded
                : (value >= i + 0.5 ? Icons.star_half_rounded : Icons.star_outline_rounded),
            size: size,
            color: tokens.orange,
          ),
      ],
    );
  }
}

/// Tap or slide across the five stars to pick 0.5–5 in half-star steps.
class StarPicker extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final double size;
  const StarPicker({super.key, required this.value, required this.onChanged, this.size = 42});

  void _pick(double dx) {
    final v = ((dx / size) * 2).ceil() / 2;
    onChanged(v.clamp(0.5, 5.0).toDouble());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _pick(d.localPosition.dx),
      onHorizontalDragStart: (d) => _pick(d.localPosition.dx),
      onHorizontalDragUpdate: (d) => _pick(d.localPosition.dx),
      child: SizedBox(
        width: size * 5,
        height: size,
        child: StarRow(value: value, size: size),
      ),
    );
  }
}

/// The small line under a place's name on cards: "★ 4.5 (12)" or a quiet
/// "No ratings yet".
class RatingSummaryLine extends StatelessWidget {
  final String placeId;
  final double fontSize;
  const RatingSummaryLine({super.key, required this.placeId, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final stats = context.select<AppStore, PlaceRatingStats?>((s) => s.ratingFor(placeId));
    if (stats == null || !stats.hasRatings) {
      return Text('No ratings yet', style: TextStyle(color: tokens.mute, fontSize: fontSize));
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: fontSize + 3, color: tokens.orange),
        const SizedBox(width: 2),
        Text(stats.avgLabel, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: fontSize)),
        const SizedBox(width: 4),
        Text('(${stats.count})', style: TextStyle(color: tokens.mute, fontSize: fontSize)),
      ],
    );
  }
}

/// The "Rate this place" section on Place Detail: average + count for
/// everyone, then either the star picker (when you're allowed to rate) or
/// your current rating and when you can rate again. You can always remove
/// your rating.
class PlaceRatingCard extends StatefulWidget {
  final String placeId;
  const PlaceRatingCard({super.key, required this.placeId});

  @override
  State<PlaceRatingCard> createState() => _PlaceRatingCardState();
}

class _PlaceRatingCardState extends State<PlaceRatingCard> {
  double? _draft;
  bool _busy = false;

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit(AppStore store, double stars) async {
    setState(() => _busy = true);
    final error = await store.ratePlace(widget.placeId, stars);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error == null) _draft = null;
    });
    _toast(error ?? 'Thanks — rating saved.');
  }

  Future<void> _remove(AppStore store) async {
    setState(() => _busy = true);
    await store.removeMyRating(widget.placeId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _draft = null;
    });
    _toast('Your rating was removed.');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    final stats = store.ratingFor(widget.placeId);
    final mine = stats?.mine;
    final canRate = stats == null || stats.canRate;
    final shown = _draft ?? mine ?? 0;

    String label(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

    return FunkyCard(
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('RATINGS', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w800, fontSize: 13, letterSpacing: 0.4)),
              const Spacer(),
              if (stats != null && stats.hasRatings) ...[
                Text(stats.avgLabel, style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800, fontSize: 20)),
                const SizedBox(width: 6),
                StarRow(value: stats.avg, size: 16),
                const SizedBox(width: 6),
                Text('(${stats.count})', style: TextStyle(color: tokens.mute, fontSize: 13)),
              ] else
                Text('No ratings yet', style: TextStyle(color: tokens.mute, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 12),
          if (canRate) ...[
            Text(
              mine == null ? 'Rate this place' : 'Update your rating',
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Center(child: StarPicker(value: shown, onChanged: (v) => setState(() => _draft = v))),
            const SizedBox(height: 6),
            Center(
              child: Text(
                shown == 0 ? 'Tap or slide across the stars — half stars work too' : '${label(shown)} star${shown == 1 ? '' : 's'}',
                style: TextStyle(color: tokens.mute, fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_busy || _draft == null)
                        ? null
                        : () => requireAccountThen(context, store, () => _submit(store, _draft!)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tokens.brand,
                      disabledBackgroundColor: tokens.raised,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      mine == null ? 'Submit rating' : 'Update rating',
                      style: TextStyle(color: _draft == null ? tokens.mute : tokens.onOrange, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
                if (mine != null) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: _busy ? null : () => _remove(store),
                    child: Text('Remove mine', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'You can rate each place once a month.',
              style: TextStyle(color: tokens.mute, fontSize: 12),
            ),
          ] else ...[
            if (mine != null) ...[
              Row(
                children: [
                  Text('Your rating', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 10),
                  StarRow(value: mine, size: 20),
                  const SizedBox(width: 6),
                  Text(label(mine), style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => _remove(store),
                    child: Text('Remove', style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ],
            Text(
              'You can rate this place again on ${stats!.nextLabel}.',
              style: TextStyle(color: tokens.mute, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
