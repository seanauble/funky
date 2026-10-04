/// Represents common aspect ratios for video cropping
enum VideoAspectRatio {
  /// 16:9 aspect ratio (widescreen)
  ratio16x9('16:9'),

  /// 4:3 aspect ratio (standard)
  ratio4x3('4:3'),

  /// 1:1 aspect ratio (square)
  ratio1x1('1:1'),

  /// 9:16 aspect ratio (vertical video)
  ratio9x16('9:16'),

  /// 3:4 aspect ratio (vertical standard)
  ratio3x4('3:4');

  /// Creates a new VideoAspectRatio instance
  const VideoAspectRatio(this.value);

  /// The string representation of the aspect ratio (e.g., '16:9')
  final String value;
}
