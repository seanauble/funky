import 'session.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdaysLong = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "1:00 AM"
String clockLabel(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "Sat, Apr 12"
String dayLabel(DateTime d) => '${_weekdays[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

/// "Late night", "Night", "Evening", "Afternoon", "Morning".
String partOfNightLabel(DateTime d) {
  final h = d.hour;
  if (h < 5) return 'Late night';
  if (h < 12) return 'Morning';
  if (h < 17) return 'Afternoon';
  if (h < 21) return 'Evening';
  return 'Night';
}

/// "Sat, Apr 12 · 1:00 AM"
String whenLabel(DateTime d) => '${dayLabel(d)} · ${clockLabel(d)}';

/// The heading for a night in the Upcoming list: "Tomorrow night",
/// "Saturday night", or "Sat, Nov 21" further out. [night] is a session key
/// ("2026-11-07").
String nightHeading(String night, [DateTime? now]) {
  final d = DateTime.tryParse(night);
  final today = DateTime.tryParse(sessionKey(now));
  if (d == null || today == null) return night;
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days <= 0) return 'Tonight';
  if (days == 1) return 'Tomorrow night';
  if (days < 7) return '${_weekdaysLong[d.weekday - 1]} night';
  return dayLabel(d);
}

/// Short "in 3 days" / "tomorrow" for a card.
String nightsAwayLabel(String night, [DateTime? now]) {
  final d = DateTime.tryParse(night);
  final today = DateTime.tryParse(sessionKey(now));
  if (d == null || today == null) return '';
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(today.year, today.month, today.day)).inDays;
  if (days <= 0) return 'tonight';
  if (days == 1) return 'tomorrow';
  return 'in $days days';
}
