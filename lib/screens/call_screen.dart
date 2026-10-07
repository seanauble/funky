import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../widgets/ui_widgets.dart';

/// Rings [personId] and opens the call screen — or says why it can't.
Future<void> placeVideoCall(BuildContext context, AppStore store, String personId) async {
  final id = await store.startCall(personId);
  if (!context.mounted) return;
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(store.lastCallError ?? "Couldn't start that call.")));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => CallScreen(callId: id, peerId: personId, isCaller: true)),
  );
}

/// Shown when a friend is ringing you: their picture, "is calling", and
/// Answer / Decline. Answering moves straight into [CallScreen].
class IncomingCallScreen extends StatefulWidget {
  final String callId;
  final String fromId;
  const IncomingCallScreen({super.key, required this.callId, required this.fromId});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  Timer? _poll;
  Timer? _giveUp;
  bool _busy = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    // If the caller hangs up or the ring runs out, close this screen.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    _giveUp = Timer(const Duration(seconds: 50), () => _close());
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _giveUp?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_closed || _busy) return;
    final call = await context.read<AppStore>().fetchCall(widget.callId);
    if (!mounted || _closed || _busy) return;
    if (call != null && !call.isLive) _close();
  }

  void _close() {
    if (_closed || !mounted) return;
    _closed = true;
    context.read<AppStore>().clearIncomingCall();
    Navigator.of(context).pop();
  }

  Future<void> _answer() async {
    if (_busy || _closed) return;
    setState(() => _busy = true);
    final store = context.read<AppStore>();
    final error = await store.respondToCall(widget.callId, 'accept');
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      _closed = true;
      store.clearIncomingCall();
      Navigator.of(context).pop();
      return;
    }
    _closed = true;
    store.clearIncomingCall();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => CallScreen(callId: widget.callId, peerId: widget.fromId, isCaller: false)),
    );
  }

  Future<void> _decline() async {
    if (_busy || _closed) return;
    setState(() => _busy = true);
    final store = context.read<AppStore>();
    unawaited(store.respondToCall(widget.callId, 'decline'));
    _closed = true;
    store.clearIncomingCall();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final person = store.personById(widget.fromId);
    final handle = person?.handle ?? 'someone';
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              FunkyAvatar(seed: widget.fromId, label: handle, size: 120, photoPath: person?.photoPath, photoUrl: person?.photoUrl),
              const SizedBox(height: 20),
              Text('@$handle', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('FUNKY video call…', style: TextStyle(color: Colors.white70, fontSize: 16)),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RoundCallButton(icon: Icons.call_end, color: const Color(0xFFE53935), label: 'Decline', onTap: _decline),
                    _RoundCallButton(icon: Icons.videocam, color: const Color(0xFF2EBF5E), label: 'Answer', onTap: _answer),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundCallButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  final double size;
  const _RoundCallButton({required this.icon, required this.color, required this.label, required this.onTap, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: size * 0.45),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The live video call. [isCaller] is true for the person who rang.
class CallScreen extends StatefulWidget {
  final String callId;
  final String peerId;
  final bool isCaller;
  const CallScreen({super.key, required this.callId, required this.peerId, required this.isCaller});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  VideoTrack? _remoteVideo;
  VideoTrack? _localVideo;
  bool _remoteCamOff = false;
  bool _micOn = true;
  bool _camOn = true;
  bool _frontCamera = true;
  bool _remoteJoined = false;
  bool _ending = false;
  String _status = 'Connecting…';
  DateTime? _connectedAt;
  Duration _elapsed = Duration.zero;
  Timer? _poll;
  Timer? _ticker;
  Timer? _noAnswer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _ticker?.cancel();
    _noAnswer?.cancel();
    _listener?.dispose();
    _room?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final store = context.read<AppStore>();
    final creds = await store.fetchCallCredentials(widget.callId);
    if (!mounted || _ending) return;
    if (creds == null) {
      _finish(store.lastCallError ?? "Couldn't connect the call.");
      return;
    }
    final room = Room();
    _room = room;
    final listener = room.createListener();
    _listener = listener;
    listener
      ..on<TrackSubscribedEvent>((e) {
        final t = e.track;
        if (t is VideoTrack && mounted) setState(() => _remoteVideo = t);
      })
      ..on<TrackUnsubscribedEvent>((e) {
        if (mounted && identical(e.track, _remoteVideo)) setState(() => _remoteVideo = null);
      })
      ..on<LocalTrackPublishedEvent>((e) {
        final t = e.publication.track;
        if (t is VideoTrack && mounted) setState(() => _localVideo = t as VideoTrack);
      })
      // The other person turned their camera off / back on.
      ..on<TrackMutedEvent>((e) {
        if (mounted && e.participant is RemoteParticipant && e.publication.kind == TrackType.VIDEO) setState(() => _remoteCamOff = true);
      })
      ..on<TrackUnmutedEvent>((e) {
        if (mounted && e.participant is RemoteParticipant && e.publication.kind == TrackType.VIDEO) setState(() => _remoteCamOff = false);
      })
      ..on<ParticipantConnectedEvent>((_) => _onRemoteJoined())
      ..on<ParticipantDisconnectedEvent>((_) => _onRemoteLeft())
      ..on<RoomDisconnectedEvent>((_) {
        if (!_ending) _finish('Call ended');
      });

    try {
      await room.connect(creds.url, creds.token, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true));
      if (!mounted || _ending) return;
      await room.localParticipant?.setMicrophoneEnabled(true);
      await room.localParticipant?.setCameraEnabled(true);
    } catch (e) {
      if (!mounted || _ending) return;
      _finish("Couldn't start the video — check that FUNKY can use your camera and microphone.");
      return;
    }
    if (!mounted || _ending) return;

    if (room.remoteParticipants.isNotEmpty) {
      _onRemoteJoined();
    } else {
      setState(() => _status = widget.isCaller ? 'Calling…' : 'Connecting…');
    }

    // Watch the call row so a decline / cancel / hang-up on the other end
    // closes this screen.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkCall());
    if (widget.isCaller && !_remoteJoined) {
      _noAnswer = Timer(const Duration(seconds: 45), () {
        if (!_remoteJoined && !_ending) {
          unawaited(context.read<AppStore>().respondToCall(widget.callId, 'cancel'));
          _finish('No answer');
        }
      });
    }
  }

  void _onRemoteJoined() {
    if (_remoteJoined || !mounted) return;
    _noAnswer?.cancel();
    setState(() {
      _remoteJoined = true;
      _status = 'Connected';
      _connectedAt = DateTime.now();
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final at = _connectedAt;
      if (at != null && mounted) setState(() => _elapsed = DateTime.now().difference(at));
    });
  }

  void _onRemoteLeft() {
    if (_ending) return;
    unawaited(context.read<AppStore>().respondToCall(widget.callId, 'end'));
    _finish('Call ended');
  }

  Future<void> _checkCall() async {
    if (_ending) return;
    final call = await context.read<AppStore>().fetchCall(widget.callId);
    if (!mounted || _ending || call == null) return;
    switch (call.status) {
      case 'declined':
        _finish('Declined');
      case 'cancelled':
      case 'missed':
        _finish('No answer');
      case 'ended':
        _finish('Call ended');
    }
  }

  /// Shows [message] for a moment, then leaves the call screen.
  Future<void> _finish(String message) async {
    if (_ending) return;
    _ending = true;
    _poll?.cancel();
    _ticker?.cancel();
    _noAnswer?.cancel();
    if (mounted) setState(() => _status = message);
    try {
      await _room?.disconnect();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _hangUp() async {
    if (_ending) return;
    final store = context.read<AppStore>();
    final action = widget.isCaller && !_remoteJoined ? 'cancel' : 'end';
    unawaited(store.respondToCall(widget.callId, action));
    _ending = true;
    _poll?.cancel();
    _ticker?.cancel();
    _noAnswer?.cancel();
    try {
      await _room?.disconnect();
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleMic() async {
    final next = !_micOn;
    setState(() => _micOn = next);
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(next);
    } catch (_) {}
  }

  Future<void> _toggleCamera() async {
    final next = !_camOn;
    setState(() => _camOn = next);
    try {
      await _room?.localParticipant?.setCameraEnabled(next);
    } catch (_) {}
  }

  Future<void> _flipCamera() async {
    if (!_camOn) return;
    final next = !_frontCamera;
    try {
      final track = _localVideo;
      if (track is LocalVideoTrack) {
        await track.restartTrack(CameraCaptureOptions(cameraPosition: next ? CameraPosition.front : CameraPosition.back));
      }
      if (mounted) setState(() => _frontCamera = next);
    } catch (_) {}
  }

  String get _clock {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final person = store.personById(widget.peerId);
    final handle = person?.handle ?? 'friend';
    final remote = _remoteCamOff ? null : _remoteVideo;
    final local = _localVideo;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (remote != null)
              VideoTrackRenderer(remote, fit: VideoViewFit.cover)
            else
              SafeArea(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FunkyAvatar(seed: widget.peerId, label: handle, size: 110, photoPath: person?.photoPath, photoUrl: person?.photoUrl),
                      const SizedBox(height: 18),
                      Text('@$handle', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      Text(_remoteJoined ? (_remoteCamOff ? 'Their camera is off' : 'Connecting video…') : _status, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    ],
                  ),
                ),
              ),

            // Who you're talking to + how long.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 140, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('@$handle', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16, shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
                      Text(
                        _remoteJoined ? _clock : _status,
                        style: const TextStyle(color: Colors.white70, fontSize: 13, shadows: [Shadow(blurRadius: 6, color: Colors.black54)]),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Your own camera, small in the corner.
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 12, 0),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 104,
                      height: 148,
                      color: const Color(0xFF1C1C1E),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (local != null && _camOn)
                            VideoTrackRenderer(local, fit: VideoViewFit.cover)
                          else
                            const Center(child: Icon(Icons.videocam_off, color: Colors.white54)),
                          if (!_micOn)
                            const Positioned(
                              left: 6,
                              bottom: 6,
                              child: CircleAvatar(radius: 11, backgroundColor: Color(0xFFE53935), child: Icon(Icons.mic_off, size: 14, color: Colors.white)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Mute / camera / flip / hang up.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
                  ),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 30, 20, 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _ControlButton(icon: _micOn ? Icons.mic : Icons.mic_off, active: _micOn, label: _micOn ? 'Mute' : 'Unmute', onTap: _toggleMic),
                        _ControlButton(icon: _camOn ? Icons.videocam : Icons.videocam_off, active: _camOn, label: _camOn ? 'Camera off' : 'Camera on', onTap: _toggleCamera),
                        _ControlButton(icon: Icons.flip_camera_ios_outlined, active: true, label: 'Flip', onTap: _flipCamera),
                        _HangUpButton(label: 'End', onTap: _hangUp),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final String label;
  final VoidCallback onTap;
  const _ControlButton({required this.icon, required this.active, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            // Filled white when it's switched OFF, so it's obvious at a glance.
            decoration: BoxDecoration(color: active ? Colors.white24 : Colors.white, shape: BoxShape.circle),
            child: Icon(icon, color: active ? Colors.white : Colors.black, size: 26),
          ),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _HangUpButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _HangUpButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: const BoxDecoration(color: Color(0xFFE53935), shape: BoxShape.circle),
            child: const Icon(Icons.call_end, color: Colors.white, size: 28),
          ),
          const SizedBox(height: 5),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// Starts a video call in a group chat — or joins the one already going.
Future<void> joinGroupVideoCall(BuildContext context, AppStore store, String groupId) async {
  final id = await store.startGroupCall(groupId);
  if (!context.mounted) return;
  if (id == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(store.lastCallError ?? "Couldn't start that call.")));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => GroupCallScreen(callId: id, groupId: groupId)),
  );
}

/// A video call with everyone in a group chat who joins: a grid of tiles,
/// yours included, with the same mute / camera / flip / hang-up controls.
class GroupCallScreen extends StatefulWidget {
  final String callId;
  final String groupId;
  const GroupCallScreen({super.key, required this.callId, required this.groupId});

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  final Map<String, VideoTrack> _videos = {}; // participant identity -> their camera
  final Set<String> _camOffIds = {}; // people whose camera is switched off
  VideoTrack? _localVideo;
  bool _micOn = true;
  bool _camOn = true;
  bool _frontCamera = true;
  bool _ending = false;
  bool _connected = false;
  String _status = 'Connecting…';
  DateTime? _connectedAt;
  Duration _elapsed = Duration.zero;
  Timer? _ping;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _ping?.cancel();
    _ticker?.cancel();
    _listener?.dispose();
    _room?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final store = context.read<AppStore>();
    final creds = await store.fetchCallCredentials(widget.callId, group: true);
    if (!mounted || _ending) return;
    if (creds == null) {
      _failAndLeave(store.lastCallError ?? "Couldn't connect the call.");
      return;
    }
    final room = Room();
    _room = room;
    final listener = room.createListener();
    _listener = listener;
    listener
      ..on<TrackSubscribedEvent>((e) {
        final t = e.track;
        if (t is VideoTrack && mounted) setState(() => _videos[e.participant.identity] = t);
      })
      ..on<TrackUnsubscribedEvent>((e) {
        if (!mounted) return;
        _videos.removeWhere((_, v) => identical(v, e.track));
        setState(() {});
      })
      ..on<LocalTrackPublishedEvent>((e) {
        final t = e.publication.track;
        if (t is VideoTrack && mounted) setState(() => _localVideo = t as VideoTrack);
      })
      ..on<TrackMutedEvent>((e) {
        if (mounted && e.participant is RemoteParticipant && e.publication.kind == TrackType.VIDEO) setState(() => _camOffIds.add(e.participant.identity));
      })
      ..on<TrackUnmutedEvent>((e) {
        if (mounted && e.participant is RemoteParticipant && e.publication.kind == TrackType.VIDEO) setState(() => _camOffIds.remove(e.participant.identity));
      })
      ..on<ParticipantConnectedEvent>((e) {
        context.read<AppStore>().ensurePerson(e.participant.identity);
        if (mounted) setState(() {});
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        if (!mounted) return;
        _videos.remove(e.participant.identity);
        setState(() {});
      })
      ..on<RoomDisconnectedEvent>((_) {
        if (!_ending && mounted) _failAndLeave('Call ended');
      });

    try {
      await room.connect(creds.url, creds.token, roomOptions: RoomOptions(adaptiveStream: true, dynacast: true));
      if (!mounted || _ending) return;
      await room.localParticipant?.setMicrophoneEnabled(true);
      await room.localParticipant?.setCameraEnabled(true);
    } catch (e) {
      if (!mounted || _ending) return;
      _failAndLeave("Couldn't start the video — check that FUNKY can use your camera and microphone.");
      return;
    }
    if (!mounted || _ending) return;
    for (final p in room.remoteParticipants.values) {
      store.ensurePerson(p.identity);
    }
    setState(() {
      _connected = true;
      _status = 'Connected';
      _connectedAt = DateTime.now();
    });
    // Tell the group this call is still live.
    unawaited(store.pingGroupCall(widget.callId));
    _ping = Timer.periodic(const Duration(seconds: 25), (_) => store.pingGroupCall(widget.callId));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final at = _connectedAt;
      if (at != null && mounted) setState(() => _elapsed = DateTime.now().difference(at));
    });
  }

  Future<void> _failAndLeave(String message) async {
    if (_ending) return;
    _ending = true;
    _ping?.cancel();
    _ticker?.cancel();
    if (mounted) setState(() => _status = message);
    try {
      await _room?.disconnect();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _leave() async {
    if (_ending) return;
    _ending = true;
    _ping?.cancel();
    _ticker?.cancel();
    final store = context.read<AppStore>();
    // The last person out ends the call for the group.
    if (_connected && (_room?.remoteParticipants.isEmpty ?? true)) {
      unawaited(store.endGroupCall(widget.callId));
    }
    try {
      await _room?.disconnect();
    } catch (_) {}
    unawaited(store.refreshGroupCalls());
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleMic() async {
    final next = !_micOn;
    setState(() => _micOn = next);
    try {
      await _room?.localParticipant?.setMicrophoneEnabled(next);
    } catch (_) {}
  }

  Future<void> _toggleCamera() async {
    final next = !_camOn;
    setState(() => _camOn = next);
    try {
      await _room?.localParticipant?.setCameraEnabled(next);
    } catch (_) {}
  }

  Future<void> _flipCamera() async {
    if (!_camOn) return;
    final next = !_frontCamera;
    try {
      final track = _localVideo;
      if (track is LocalVideoTrack) {
        await track.restartTrack(CameraCaptureOptions(cameraPosition: next ? CameraPosition.front : CameraPosition.back));
      }
      if (mounted) setState(() => _frontCamera = next);
    } catch (_) {}
  }

  String get _clock {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _grid(List<Widget> tiles) {
    final n = tiles.length;
    final cols = n <= 1 ? 1 : (n <= 4 ? 2 : 3);
    final rows = (n / cols).ceil();
    return Column(
      children: [
        for (var r = 0; r < rows; r++)
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < cols; c++)
                  Expanded(
                    child: r * cols + c < n
                        ? Padding(padding: const EdgeInsets.all(2), child: tiles[r * cols + c])
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final group = store.groupById(widget.groupId);
    final remotes = _room?.remoteParticipants.values.toList() ?? const <RemoteParticipant>[];

    final tiles = <Widget>[
      _ParticipantTile(
        video: _camOn ? _localVideo : null,
        label: _micOn ? 'You' : 'You · muted',
        seed: 'me',
        photoPath: store.me.photoPath,
        photoUrl: store.me.photoUrl,
      ),
      for (final p in remotes)
        Builder(builder: (context) {
          final person = store.personById(p.identity);
          final handle = person?.handle ?? (p.name.isNotEmpty ? p.name : 'friend');
          return _ParticipantTile(
            video: _camOffIds.contains(p.identity) ? null : _videos[p.identity],
            label: '@$handle',
            seed: p.identity,
            photoPath: person?.photoPath,
            photoUrl: person?.photoUrl,
          );
        }),
    ];

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(group?.name ?? 'Group call', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
                          Text(
                            _connected ? '${remotes.length + 1} on the call · $_clock' : _status,
                            style: const TextStyle(color: Colors.white70, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _grid(tiles)),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ControlButton(icon: _micOn ? Icons.mic : Icons.mic_off, active: _micOn, label: _micOn ? 'Mute' : 'Unmute', onTap: _toggleMic),
                    _ControlButton(icon: _camOn ? Icons.videocam : Icons.videocam_off, active: _camOn, label: _camOn ? 'Camera off' : 'Camera on', onTap: _toggleCamera),
                    _ControlButton(icon: Icons.flip_camera_ios_outlined, active: true, label: 'Flip', onTap: _flipCamera),
                    _HangUpButton(label: 'Leave', onTap: _leave),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One person's square in the group call grid: their camera, or their
/// picture when it's off.
class _ParticipantTile extends StatelessWidget {
  final VideoTrack? video;
  final String label;
  final String seed;
  final String? photoPath;
  final String? photoUrl;
  const _ParticipantTile({required this.video, required this.label, required this.seed, this.photoPath, this.photoUrl});

  @override
  Widget build(BuildContext context) {
    final v = video;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        color: const Color(0xFF1C1C1E),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (v != null)
              VideoTrackRenderer(v, fit: VideoViewFit.cover)
            else
              Center(
                child: FunkyAvatar(
                  seed: seed,
                  label: label.startsWith('@') ? label.substring(1) : label,
                  size: 64,
                  photoPath: photoPath,
                  photoUrl: photoUrl,
                ),
              ),
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
