/// Class representing video metadata
class VideoMetadata {
  /// Duration of the video in milliseconds
  final int duration;

  /// Width of the video in pixels
  final int width;

  /// Height of the video in pixels
  final int height;

  /// Title of the video (may be null)
  final String? title;

  /// Author or artist of the video (may be null)
  final String? author;

  /// Rotation in degrees (0, 90, 180, or 270)
  final int rotation;

  /// File size in bytes
  final int fileSize;

  final String? date;

  /// Creates a new VideoMetadata instance
  const VideoMetadata({
    required this.duration,
    required this.width,
    required this.height,
    this.title,
    this.author,
    required this.rotation,
    required this.fileSize,
    this.date,
  });

  /// Create a VideoMetadata from a map (typically from the platform channel)
  factory VideoMetadata.fromMap(Map<dynamic, dynamic> map) {
    return VideoMetadata(
      duration: map['duration'] as int,
      width: map['width'] as int,
      height: map['height'] as int,
      title: map['title'] as String?,
      author: map['author'] as String?,
      rotation: map['rotation'] as int,
      fileSize: map['fileSize'] as int,
      date: map['date'] as String?,
    );
  }

  /// Convert this metadata to a map
  Map<String, dynamic> toMap() {
    return {
      'duration': duration,
      'width': width,
      'height': height,
      'title': title,
      'author': author,
      'rotation': rotation,
      'fileSize': fileSize,
      'date': date,
    };
  }

  @override
  String toString() {
    return 'VideoMetadata(duration: $duration ms, '
        'width: $width, height: $height, '
        'title: $title, author: $author, '
        'rotation: $rotation°, '
        'fileSize: ${(fileSize / 1024).toStringAsFixed(2)} KB, '
        'date: $date)';
  }
}
