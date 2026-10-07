/// What the app knows about a place's star ratings: the average and number
/// of ratings from everyone, plus this person's own rating and when they're
/// next allowed to rate it (once every 30 days per place).
class PlaceRatingStats {
  final double avg;
  final int count;
  final double? mine;
  final DateTime? nextAt;

  const PlaceRatingStats({required this.avg, required this.count, this.mine, this.nextAt});

  bool get hasRatings => count > 0;

  bool get canRate => nextAt == null || !nextAt!.isAfter(DateTime.now());

  /// "4.5" — one decimal, always.
  String get avgLabel => avg.toStringAsFixed(1);

  /// "1 rating" / "12 ratings".
  String get countLabel => '$count rating${count == 1 ? '' : 's'}';

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "Nov 6" — when rating this place opens up again.
  String get nextLabel {
    final d = nextAt;
    if (d == null) return '';
    return '${_months[d.month - 1]} ${d.day}';
  }
}
