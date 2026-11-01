import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoDatePickerMode;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../widgets/ios_ui.dart';
import '../data/app_store.dart';
import '../data/geo.dart';
import '../widgets/ui_widgets.dart';
import 'account_screen.dart';
import 'camera_capture_screen.dart';

/// The POST tab of the create flow: up to five photos, a caption, and
/// optionally the place it's at. Everyone whose radius reaches it sees it.
class PostFormPage extends StatefulWidget {
  const PostFormPage({super.key});

  @override
  State<PostFormPage> createState() => _PostFormPageState();
}

class _PostFormPageState extends State<PostFormPage> {
  final _caption = TextEditingController();
  // Event posts (a flyer for something happening): name, date/time, cover.
  bool _isEvent = false;
  final _eventName = TextEditingController();
  final _cover = TextEditingController();
  DateTime _eventDay = DateTime.now();
  TimeOfDay _eventTime = const TimeOfDay(hour: 21, minute: 0);
  final List<String> _photos = [];
  String? _placeId;
  bool _posting = false;

  @override
  void dispose() {
    _caption.dispose();
    _eventName.dispose();
    _cover.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  int get _left => AppStore.maxPostPhotos - _photos.length;

  Future<void> _fromLibrary() async {
    final left = _left;
    if (left <= 0) return;
    try {
      final picker = ImagePicker();
      if (left == 1) {
        final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2160, maxHeight: 2160);
        if (x != null && mounted) setState(() => _photos.add(x.path));
      } else {
        final xs = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2160, maxHeight: 2160, limit: left);
        if (xs.isNotEmpty && mounted) setState(() => _photos.addAll(xs.take(left).map((x) => x.path)));
      }
    } catch (e) {
      _toast("Couldn't open your photos: $e");
    }
  }

  Future<void> _fromCamera() async {
    if (_left <= 0) return;
    final media = await Navigator.of(context).push<CapturedMedia>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const CameraCaptureScreen()),
    );
    if (media == null || !mounted) return;
    if (media.isVideo) {
      _toast('Posts are photos for now. Tap the shutter instead of holding it.');
      return;
    }
    setState(() => _photos.add(media.file.path));
  }

  Future<void> _pickPlace(AppStore store) async {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final nearby = [...store.rankedPlaces]..sort((a, b) => a.distance.compareTo(b.distance));
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: tokens.surface,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheetContext).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text('Where was this?', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              ListTile(
                leading: Icon(Icons.my_location, color: tokens.mute),
                title: Text('No place (no location shown)', style: TextStyle(color: tokens.ink)),
                onTap: () => Navigator.of(sheetContext).pop(''),
              ),
              for (final p in nearby.take(40))
                ListTile(
                  leading: Icon(Icons.location_on, color: tokens.orange),
                  title: Text(p.name, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600)),
                  subtitle: Text(formatMiles(p.distance), style: TextStyle(color: tokens.mute)),
                  onTap: () => Navigator.of(sheetContext).pop(p.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _placeId = picked.isEmpty ? null : picked);
  }

  bool get _canPost =>
      !_posting && (_isEvent ? _eventName.text.trim().isNotEmpty : (_photos.isNotEmpty || _caption.text.trim().isNotEmpty));

  DateTime get _eventAt => DateTime(_eventDay.year, _eventDay.month, _eventDay.day, _eventTime.hour, _eventTime.minute);

  Future<void> _pickDay() async {
    final now = DateTime.now();
    final picked = await showIosDateTimePicker(
      context,
      mode: CupertinoDatePickerMode.date,
      title: 'What day?',
      initial: _eventDay,
      minimum: DateTime(now.year, now.month, now.day),
      maximum: now.add(const Duration(days: 180)),
    );
    if (picked != null && mounted) setState(() => _eventDay = DateTime(picked.year, picked.month, picked.day));
  }

  Future<void> _pickTime() async {
    final base = DateTime(_eventDay.year, _eventDay.month, _eventDay.day, _eventTime.hour, _eventTime.minute);
    final picked = await showIosDateTimePicker(context, mode: CupertinoDatePickerMode.time, title: 'What time?', initial: base);
    if (picked != null && mounted) setState(() => _eventTime = TimeOfDay(hour: picked.hour, minute: picked.minute));
  }

  String _dayLabel(DateTime d) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day}';
  }

  String _timeLabel(TimeOfDay t) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _post(AppStore store) async {
    if (!_canPost) return;
    requireAccountThen(context, store, () async {
      setState(() => _posting = true);
      final err = await store.createPost(
        photoPaths: List.of(_photos),
        caption: _caption.text,
        placeId: _placeId,
        eventTitle: _isEvent ? _eventName.text : null,
        eventAt: _isEvent ? _eventAt : null,
        eventCover: _isEvent ? _cover.text : null,
      );
      if (!mounted) return;
      setState(() => _posting = false);
      if (err != null) {
        _toast(err);
        return;
      }
      _toast('Posted!');
      Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();
    String? placeName;
    final pid = _placeId;
    if (pid != null) {
      for (final p in store.places) {
        if (p.id == pid) {
          placeName = p.name;
          break;
        }
      }
    }

    Widget addTile(IconData icon, String label, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            width: 96,
            height: 128,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: tokens.raised,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tokens.line),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: tokens.orange),
                const SizedBox(height: 6),
                Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700, fontSize: 12.5)),
              ],
            ),
          ),
        );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Photos (${_photos.length}/${AppStore.maxPostPhotos}) · optional, a post can be just text', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 8),
          SizedBox(
            height: 128,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (var i = 0; i < _photos.length; i++)
                  Container(
                    width: 96,
                    height: 128,
                    margin: const EdgeInsets.only(right: 8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(File(_photos[i]), fit: BoxFit.cover),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () => setState(() => _photos.removeAt(i)),
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white, size: 15),
                            ),
                          ),
                        ),
                        if (i == 0)
                          Positioned(
                            left: 6,
                            bottom: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
                              child: const Text('Cover', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_left > 0) ...[
                  addTile(Icons.photo_library_outlined, 'Library', _fromLibrary),
                  addTile(Icons.photo_camera_outlined, 'Camera', _fromCamera),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('Caption', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(
            controller: _caption,
            onChanged: (_) => setState(() {}),
            maxLength: AppStore.maxPostCaption,
            minLines: 3,
            maxLines: 6,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              hintText: _photos.isEmpty ? 'Ask your area something… "Anyone up for trivia?"' : 'Say something about these pics',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 6),
          Text('Location', style: TextStyle(color: tokens.mute, fontSize: 13)),
          const SizedBox(height: 6),
          Material(
            color: tokens.raised,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _pickPlace(store),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.location_on, color: tokens.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        placeName ?? 'No place tagged',
                        style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(placeName == null ? 'Tag a place' : 'Change', style: TextStyle(color: tokens.orange, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Event
          Container(
            decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: Row(
              children: [
                Icon(Icons.event_rounded, color: tokens.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('This is an event', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                      Text('Adds a date, cover and an "I\'m going" button', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    ],
                  ),
                ),
                Switch.adaptive(value: _isEvent, activeColor: tokens.brand, onChanged: (v) => setState(() => _isEvent = v)),
              ],
            ),
          ),
          if (_isEvent) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _eventName,
              maxLength: 60,
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                hintText: 'Event name, e.g. "Friday Live"',
                hintStyle: TextStyle(color: tokens.mute),
                filled: true,
                fillColor: tokens.raised,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickDay,
                    icon: Icon(Icons.calendar_today_outlined, size: 18, color: tokens.orange),
                    label: Text(_dayLabel(_eventDay), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: tokens.line),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickTime,
                    icon: Icon(Icons.schedule_rounded, size: 18, color: tokens.orange),
                    label: Text(_timeLabel(_eventTime), style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: tokens.line),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _cover,
              maxLength: 20,
              decoration: InputDecoration(
                hintText: r'Cover: "No cover", "$10"… (optional)',
                hintStyle: TextStyle(color: tokens.mute),
                filled: true,
                fillColor: tokens.raised,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              style: TextStyle(color: tokens.ink),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            placeName == null
                ? 'Everyone nearby can see it, like it and comment. No location is shown unless you tag a place.'
                : 'Everyone nearby can see it, like it and comment. It shows as posted at $placeName.',
            style: TextStyle(color: tokens.mute, fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _canPost ? () => _post(store) : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.brand,
                disabledBackgroundColor: tokens.brand.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: _posting
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(
                      _canPost || _posting ? (_isEvent ? 'Post event' : 'Post') : (_isEvent ? 'Name your event' : 'Add a photo or write something'),
                      style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
