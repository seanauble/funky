/// FUNKY's own avatars — the pictures new accounts start with, and that
/// anyone can pick instead of a photo. A profile's picture is stored as
/// "preset:<name>" (supabase/phase33.sql gives every new account a random
/// one), and the image itself ships inside the app.
class AvatarPreset {
  final String key;
  final String label;
  const AvatarPreset(this.key, this.label);

  String get value => 'preset:$key';
  String get asset => 'assets/avatars/$key.jpg';
}

const avatarPresets = <AvatarPreset>[
  AvatarPreset('raccoon', 'Party Raccoon'),
  AvatarPreset('giraffe', 'Shades Giraffe'),
  AvatarPreset('seagull', 'Shore Gull'),
  AvatarPreset('pup', 'Cap Pup'),
  AvatarPreset('cat', 'Sly Cat'),
  AvatarPreset('blob', 'Cool Blob'),
  AvatarPreset('flame', 'Lil Flame'),
  AvatarPreset('star', 'Night Owl Star'),
  AvatarPreset('ghost', 'Ghost'),
  AvatarPreset('disco', 'Disco Ball'),
  AvatarPreset('cloud', 'Sleepy Cloud'),
  AvatarPreset('elephant', 'Ellie'),
];

bool isPresetAvatar(String? url) => url != null && url.startsWith('preset:');

/// The bundled image for a "preset:<name>" picture, or null if it isn't one
/// (or it's a name this version of the app doesn't have).
String? presetAvatarAsset(String? url) {
  if (!isPresetAvatar(url)) return null;
  final key = url!.substring(7);
  for (final p in avatarPresets) {
    if (p.key == key) return p.asset;
  }
  return null;
}
