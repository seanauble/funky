/// Video resolution options
enum VideoResolution {
  /// 360p resolution (640x360)
  p360(360),

  /// 480p resolution (854x480)
  p480(480),

  /// 720p resolution (1280x720)
  p720(720),

  /// 1080p resolution (1920x1080)
  p1080(1080),

  /// 4K resolution (3840x2160)
  p2160(2160);

  /// Constructor
  const VideoResolution(this.height);

  /// Height in pixels
  final int height;
}
