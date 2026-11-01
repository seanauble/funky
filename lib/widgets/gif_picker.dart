import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/app_store.dart';
import 'ui_widgets.dart';

/// One GIF from GIPHY: a small preview for the grid and the link to send.
class _Gif {
  final String preview;
  final String url;
  const _Gif(this.preview, this.url);
}

/// GIF search (GIPHY). Returns the picked GIF's link, or null. Needs the
/// GIPHY key an admin saves (app_config); without it, admins get a box to
/// paste one and everyone else a short note.
Future<String?> showGifPicker(BuildContext context, AppStore store) {
  final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: tokens.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => _GifSheet(store: store),
  );
}

class _GifSheet extends StatefulWidget {
  final AppStore store;
  const _GifSheet({required this.store});

  @override
  State<_GifSheet> createState() => _GifSheetState();
}

class _GifSheetState extends State<_GifSheet> {
  final _search = TextEditingController();
  final _keyField = TextEditingController();
  Timer? _debounce;
  List<_Gif> _gifs = const [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    if (widget.store.giphyKey != null) _load('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _keyField.dispose();
    super.dispose();
  }

  Future<void> _load(String q) async {
    final key = widget.store.giphyKey;
    if (key == null) return;
    final mySeq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    final query = q.trim();
    final uri = query.isEmpty
        ? Uri.https('api.giphy.com', '/v1/gifs/trending', {'api_key': key, 'limit': '30', 'rating': 'pg-13'})
        : Uri.https('api.giphy.com', '/v1/gifs/search', {'api_key': key, 'q': query, 'limit': '30', 'rating': 'pg-13'});
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();
      client.close();
      if (res.statusCode != 200) throw HttpException('GIPHY said ${res.statusCode}');
      final data = (jsonDecode(body) as Map<String, dynamic>)['data'] as List<dynamic>? ?? const [];
      final gifs = <_Gif>[];
      for (final raw in data) {
        final images = (raw as Map<String, dynamic>)['images'] as Map<String, dynamic>?;
        if (images == null) continue;
        String? pick(String name) => (images[name] as Map<String, dynamic>?)?['url'] as String?;
        final preview = pick('fixed_width_small') ?? pick('fixed_width') ?? pick('downsized');
        final full = pick('fixed_height') ?? pick('downsized') ?? pick('original');
        if (preview == null || full == null) continue;
        // Plain media link, no tracking query — what the server accepts.
        final clean = full.split('?').first;
        if (!RegExp(r'^https://(media[0-9]*|i)\.giphy\.com/').hasMatch(clean)) continue;
        gifs.add(_Gif(preview, clean));
      }
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _gifs = gifs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _loading = false;
        _error = "Couldn't load GIFs. Check your connection.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = widget.store;
    final height = MediaQuery.of(context).size.height * 0.72;
    if (store.giphyKey == null) {
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('GIFs', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 18)),
              const SizedBox(height: 6),
              Text(
                store.isAdmin
                    ? 'Paste a free GIPHY API key (developers.giphy.com → Create an App → API) to turn on GIF search for everyone.'
                    : "GIFs aren't switched on yet.",
                style: TextStyle(color: tokens.mute, height: 1.35),
              ),
              if (store.isAdmin) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _keyField,
                  style: TextStyle(color: tokens.ink),
                  decoration: InputDecoration(
                    hintText: 'GIPHY API key',
                    hintStyle: TextStyle(color: tokens.mute),
                    filled: true,
                    fillColor: tokens.raised,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                FunkyChip(
                  label: 'Save key',
                  active: true,
                  onPressed: () async {
                    final err = await store.setGiphyKey(_keyField.text);
                    if (!mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                    } else {
                      setState(() {});
                      _load('');
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(color: tokens.ink),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 350), () => _load(v));
                  },
                  decoration: InputDecoration(
                    hintText: 'Search GIFs',
                    hintStyle: TextStyle(color: tokens.mute),
                    prefixIcon: Icon(Icons.search_rounded, color: tokens.mute),
                    filled: true,
                    fillColor: tokens.raised,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(
                child: _loading && _gifs.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(child: Text(_error!, style: TextStyle(color: tokens.mute)))
                        : _gifs.isEmpty
                            ? Center(child: Text('No GIFs found.', style: TextStyle(color: tokens.mute)))
                            : GridView.builder(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                                itemCount: _gifs.length,
                                itemBuilder: (context, i) => GestureDetector(
                                  onTap: () => Navigator.of(context).pop(_gifs[i].url),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.network(
                                      _gifs[i].preview,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => ColoredBox(color: tokens.raised),
                                    ),
                                  ),
                                ),
                              ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('Powered by GIPHY', style: TextStyle(color: tokens.mute, fontSize: 11, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
