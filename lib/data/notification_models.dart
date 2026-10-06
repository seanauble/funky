/// One row of the server's `notifications` table (see supabase/phase7.sql).
/// [kind] is 'dm', 'friend', 'place' or 'report'; [data] carries the ids
/// needed to open the right screen when it's tapped (`from`, `place_id`).
class AppNotification {
  final String id;
  final String kind;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final bool read;

  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.data,
    required this.createdAt,
    required this.read,
  });

  AppNotification copyWith({bool? read}) => AppNotification(
        id: id,
        kind: kind,
        title: title,
        body: body,
        data: data,
        createdAt: createdAt,
        read: read ?? this.read,
      );

  static AppNotification? fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    final kind = row['kind'] as String?;
    if (id == null || kind == null) return null;
    final createdRaw = row['created_at'] as String?;
    final rawData = row['data'];
    return AppNotification(
      id: id,
      kind: kind,
      title: row['title'] as String? ?? '',
      body: row['body'] as String? ?? '',
      data: rawData is Map ? Map<String, dynamic>.from(rawData) : const {},
      createdAt: createdRaw != null ? (DateTime.tryParse(createdRaw)?.toLocal() ?? DateTime.now()) : DateTime.now(),
      read: row['read_at'] != null,
    );
  }
}

/// Which kinds of notification the signed-in person wants.
class NotificationPrefs {
  final bool dm;
  final bool friend;
  final bool place;
  final bool report;

  const NotificationPrefs({this.dm = true, this.friend = true, this.place = true, this.report = true});

  NotificationPrefs copyWith({bool? dm, bool? friend, bool? place, bool? report}) => NotificationPrefs(
        dm: dm ?? this.dm,
        friend: friend ?? this.friend,
        place: place ?? this.place,
        report: report ?? this.report,
      );

  bool forKind(String kind) {
    switch (kind) {
      case 'dm':
        return dm;
      case 'friend':
        return friend;
      case 'place':
        return place;
      case 'report':
        return report;
    }
    return true;
  }

  Map<String, dynamic> toRow(String uid) => {
        'user_id': uid,
        'dm_on': dm,
        'friend_on': friend,
        'place_on': place,
        'report_on': report,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  static NotificationPrefs fromRow(Map<String, dynamic> row) => NotificationPrefs(
        dm: row['dm_on'] as bool? ?? true,
        friend: row['friend_on'] as bool? ?? true,
        place: row['place_on'] as bool? ?? true,
        report: row['report_on'] as bool? ?? true,
      );
}
