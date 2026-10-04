import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../data/models.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';
import 'person_profile_screen.dart';

/// Reached by tapping the magnifying glass on the Friends screen — search
/// for someone by @handle instead of only being able to Add Friend from a
/// Story/DM/chat you already saw them in. Tapping a result opens their
/// profile, which already has the right Add/Cancel/Accept button for
/// whatever your current relationship with them is (see PersonProfileScreen)
/// so this screen doesn't need to duplicate that logic.
class AddFriendsScreen extends StatefulWidget {
  const AddFriendsScreen({super.key});

  @override
  State<AddFriendsScreen> createState() => _AddFriendsScreenState();
}

class _AddFriendsScreenState extends State<AddFriendsScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<Person>? _results;
  bool _loading = false;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(AppStore store, String value) {
    _debounce?.cancel();
    setState(() => _query = value);
    if (value.trim().isEmpty) {
      setState(() {
        _results = null;
        _loading = false;
      });
      return;
    }
    // A short debounce so a quick typist doesn't fire a search per
    // keystroke — same idea as any other live-search field.
    _debounce = Timer(const Duration(milliseconds: 350), () => _runSearch(store, value));
  }

  Future<void> _runSearch(AppStore store, String value) async {
    setState(() => _loading = true);
    final results = await store.searchPeopleByHandle(value);
    if (!mounted || _controller.text != value) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(
        backgroundColor: tokens.bg,
        foregroundColor: tokens.ink,
        elevation: 0,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (v) => _onChanged(store, v),
            onSubmitted: (v) => _runSearch(store, v),
            decoration: InputDecoration(
              hintText: 'Search by @username',
              hintStyle: TextStyle(color: tokens.mute),
              filled: true,
              fillColor: tokens.raised,
              prefixIcon: Icon(Icons.search, color: tokens.mute, size: 20),
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(19), borderSide: BorderSide.none),
            ),
            style: TextStyle(color: tokens.ink),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _buildBody(tokens),
      ),
    );
  }

  Widget _buildBody(ThemeTokens tokens) {
    if (_query.trim().isEmpty) {
      return EmptyNote(text: "Search for a username to add someone as a friend.");
    }
    if (_loading && _results == null) {
      return const Center(child: Padding(padding: EdgeInsets.only(top: 40), child: CircularProgressIndicator()));
    }
    final results = _results ?? const [];
    if (results.isEmpty) {
      return EmptyNote(text: 'No one on FUNKY matches "@${_query.trim()}" right now.');
    }
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, i) {
        final p = results[i];
        return FunkyCard(
          margin: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PersonProfileScreen(personId: p.id))),
            child: Row(
              children: [
                FunkyAvatar(seed: p.id, label: p.handle.isNotEmpty ? p.handle : '?', size: 40, photoPath: p.photoPath),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FunkyHandle(handle: p.handle, person: p),
                      if (p.bio.isNotEmpty)
                        Text(p.bio, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: tokens.mute, fontSize: 12.5)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: tokens.mute),
              ],
            ),
          ),
        );
      },
    );
  }
}
