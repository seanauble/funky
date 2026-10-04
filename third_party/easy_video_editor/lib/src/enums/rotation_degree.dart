/// Enum for video rotation degrees
enum RotationDegree {
  /// Rotate 90 degrees
  degree90(90),

  /// Rotate 180 degrees
  degree180(180),

  /// Rotate 270 degrees
  degree270(270);

  /// The degree value
  final int value;

  /// Constructor
  const RotationDegree(this.value);
}
