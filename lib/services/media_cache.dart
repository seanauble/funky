import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

/// Keeps photos and videos from FUNKY's server on the phone after the first
/// download, so scrolling past the same story, post or place picture again
/// (even after closing the app) doesn't download it again. Every download
/// counts against the Supabase plan's egress, so this matters.
///
/// Only FUNKY's own files (anything on supabase.co) are kept; GIFs and other
/// outside images load the normal way.
class MediaCache {
  MediaCache._();

  static const _maxBytes = 600 * 1024 * 1024; // trimmed back when over this
  static Directory? _dir;
  static final Map<String, Future<File?>> _inFlight = {};
  static bool _pruned = false;

  static bool isCacheable(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') return false;
    return uri.host.endsWith('.supabase.co') || uri.host.endsWith('.supabase.in');
  }

  /// Signed Storage links change their token every time they're made, but
  /// it's the same file — so the token isn't part of the key. (Public links
  /// keep theirs: a new profile picture changes its "?v=".)
  static String keyFor(String url) {
    if (url.contains('/storage/v1/object/sign/')) return url.split('?').first;
    return url;
  }

  static String _fileName(String url) {
    final key = keyFor(url);
    final digest = sha1.convert(utf8.encode(key)).toString();
    final path = Uri.tryParse(key)?.path ?? '';
    final dot = path.lastIndexOf('.');
    var ext = dot != -1 && path.length - dot <= 5 ? path.substring(dot) : '';
    if (ext.contains('/')) ext = '';
    return '$digest$ext';
  }

  static Future<Directory> _cacheDir() async {
    final have = _dir;
    if (have != null) return have;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/media_cache');
    if (!await d.exists()) await d.create(recursive: true);
    _dir = d;
    if (!_pruned) {
      _pruned = true;
      unawaited(_prune(d));
    }
    return d;
  }

  /// The file on the phone for [url], downloading it the first time.
  /// Null if it can't be downloaded (the caller should fall back to the
  /// network).
  static Future<File?> file(String url) {
    final key = keyFor(url);
    final running = _inFlight[key];
    if (running != null) return running;
    final f = _get(url).whenComplete(() => _inFlight.remove(key));
    _inFlight[key] = f;
    return f;
  }

  static Future<File?> _get(String url) async {
    try {
      final dir = await _cacheDir();
      final target = File('${dir.path}/${_fileName(url)}');
      if (await target.exists() && await target.length() > 0) {
        // Touch it so the trim keeps what's still being looked at.
        unawaited(target.setLastModified(DateTime.now()).catchError((_) {}));
        return target;
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final req = await client.getUrl(Uri.parse(url));
        final res = await req.close().timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          await res.drain<void>();
          return null;
        }
        // Write next to it, then rename, so a half download is never used.
        final part = File('${target.path}.part');
        final sink = part.openWrite();
        await res.timeout(const Duration(seconds: 60)).pipe(sink);
        if (await part.length() == 0) {
          await part.delete();
          return null;
        }
        return await part.rename(target.path);
      } finally {
        client.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// Drops the oldest files once the cache is over its size.
  static Future<void> _prune(Directory d) async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final e in d.list()) {
        if (e is! File) continue;
        if (e.path.endsWith('.part')) {
          await e.delete().catchError((_) => e);
          continue;
        }
        files.add(e);
        total += await e.length();
      }
      if (total <= _maxBytes) return;
      final stamped = <(File, DateTime)>[for (final f in files) (f, await f.lastModified())]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (f, _) in stamped) {
        if (total <= _maxBytes * 0.8) break;
        final n = await f.length();
        await f.delete().catchError((_) => f);
        total -= n;
      }
    } catch (_) {}
  }
}

/// A picture from FUNKY's server that's downloaded once and then read from
/// the phone. Anything else falls back to a normal network image.
class CachedUrlImage extends ImageProvider<CachedUrlImage> {
  final String url;
  const CachedUrlImage(this.url);

  @override
  Future<CachedUrlImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<CachedUrlImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedUrlImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1,
      debugLabel: url,
      informationCollector: () => [DiagnosticsProperty<String>('URL', url)],
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    Uint8List? bytes;
    final f = await MediaCache.file(url);
    if (f != null) {
      try {
        bytes = await f.readAsBytes();
      } catch (_) {}
    }
    if (bytes == null || bytes.isEmpty) {
      // Couldn't keep it — just load it the normal way this time.
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final res = await (await client.getUrl(Uri.parse(url))).close();
        if (res.statusCode != 200) throw NetworkImageLoadException(statusCode: res.statusCode, uri: Uri.parse(url));
        bytes = await consolidateHttpClientResponseBytes(res);
      } finally {
        client.close();
      }
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) => other is CachedUrlImage && MediaCache.keyFor(other.url) == MediaCache.keyFor(url);

  @override
  int get hashCode => MediaCache.keyFor(url).hashCode;

  @override
  String toString() => 'CachedUrlImage("$url")';
}

/// The image provider to use for [url]: kept on the phone when it's one of
/// FUNKY's own files, a plain network image otherwise.
ImageProvider netImageProvider(String url) => MediaCache.isCacheable(url) ? CachedUrlImage(url) : NetworkImage(url);

/// Drop-in for `Image.network` that keeps FUNKY's own pictures on the phone.
Widget netImage(
  String url, {
  Key? key,
  ImageFrameBuilder? frameBuilder,
  ImageLoadingBuilder? loadingBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
  String? semanticLabel,
  double? width,
  double? height,
  Color? color,
  BlendMode? colorBlendMode,
  BoxFit? fit,
  AlignmentGeometry alignment = Alignment.center,
  bool gaplessPlayback = false,
  FilterQuality filterQuality = FilterQuality.medium,
  int? cacheWidth,
  int? cacheHeight,
}) {
  return Image(
    key: key,
    image: ResizeImage.resizeIfNeeded(cacheWidth, cacheHeight, netImageProvider(url)),
    frameBuilder: frameBuilder,
    loadingBuilder: loadingBuilder,
    errorBuilder: errorBuilder,
    semanticLabel: semanticLabel,
    width: width,
    height: height,
    color: color,
    colorBlendMode: colorBlendMode,
    fit: fit,
    alignment: alignment,
    gaplessPlayback: gaplessPlayback,
    filterQuality: filterQuality,
  );
}

/// A video player for a file on the phone ([path]) or one of FUNKY's videos
/// ([url]) — downloaded once and played from the phone after that. Falls
/// back to streaming if the download doesn't work.
Future<VideoPlayerController> openVideoController({String? path, String? url}) async {
  if (path != null) return VideoPlayerController.file(File(path));
  final u = url!;
  if (MediaCache.isCacheable(u)) {
    final f = await MediaCache.file(u);
    if (f != null) return VideoPlayerController.file(f);
  }
  return VideoPlayerController.networkUrl(Uri.parse(u));
}
