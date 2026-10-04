/// Types of video operations supported by the editor
enum VideoOperationType {
  /// Trim video to specified duration
  trim,

  /// Merge multiple videos
  merge,

  /// Adjust video speed
  speed,

  /// Remove audio track
  removeAudio,

  /// Crop video to specific aspect ratio
  crop,

  /// Rotate video
  rotate,

  /// Compress video
  compress,

  /// Flip video
  flip,
}
