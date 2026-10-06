import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/app_store.dart';
import '../theme/colors.dart';
import '../widgets/ui_widgets.dart';

/// Gates posting and messaging behind a real account. Browsing FUNKY is
/// always anonymous and free — but posting a Story/poll/place or sending a
/// message needs an email + password account, created or logged into right
/// here. Reached two ways: from Settings (manage an existing account), or
/// via [requireAccountThen] the instant someone who isn't signed in taps
/// Post or Send — in that case [closeOnSuccess] pops this screen the moment
/// sign-up/log-in succeeds, dropping straight back into whatever they were
/// doing.
///
/// A REAL Supabase account as of the backend migration — see AppStore's
/// signUp/signIn/etc. Anyone who created a local-only account before that
/// migration will need to sign up again here; the old local accounts were
/// never backed by anything a second device could ever see anyway.
class AccountScreen extends StatefulWidget {
  final bool closeOnSuccess;

  /// Opens on the "Log in" form instead of "Create account".
  final bool startInLogIn;
  const AccountScreen({super.key, this.closeOnSuccess = false, this.startInLogIn = false});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  late bool _signUpMode = !widget.startInLogIn;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _authError;
  bool _busy = false;

  bool _showChangeEmail = false;
  bool _showChangePassword = false;
  final _newEmailController = TextEditingController();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  String? _accountError;

  bool _showResetPassword = false;
  String? _resetError;
  bool _resetSent = false;
  bool _resetBusy = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _newEmailController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submitAuth(AppStore store) async {
    setState(() => _busy = true);
    final error = _signUpMode
        ? await store.signUp(_emailController.text, _passwordController.text)
        : await store.signIn(_emailController.text, _passwordController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _authError = error;
    });
    if (error == null && widget.closeOnSuccess && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    final store = context.watch<AppStore>();

    return Scaffold(
      backgroundColor: tokens.bg,
      appBar: AppBar(backgroundColor: tokens.bg, foregroundColor: tokens.ink, elevation: 0, title: const Text('Account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: store.signedIn ? _buildSignedIn(tokens, store) : _buildAuthForm(tokens, store),
        ),
      ),
    );
  }

  Widget _buildAuthForm(ThemeTokens tokens, AppStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Browsing FUNKY is always anonymous and free. You just need an account — a real email and a password — to post a Story, poll, or place, or send a message.',
          style: TextStyle(color: tokens.mute, fontSize: 13.5, height: 1.4),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(10)),
          child: Row(
            children: [
              _ModeTab(label: 'Sign Up', active: _signUpMode, onTap: () => setState(() {
                    _signUpMode = true;
                    _authError = null;
                  })),
              _ModeTab(label: 'Log In', active: !_signUpMode, onTap: () => setState(() {
                    _signUpMode = false;
                    _authError = null;
                  })),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text('Email', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: _fieldDecoration(tokens, 'you@example.com'),
          style: TextStyle(color: tokens.ink),
        ),
        const SizedBox(height: 14),
        Text('Password', style: TextStyle(color: tokens.mute, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: _passwordController,
          obscureText: true,
          decoration: _fieldDecoration(tokens, _signUpMode ? 'At least 8 characters' : 'Your password'),
          style: TextStyle(color: tokens.ink),
        ),
        if (_authError != null) ...[
          const SizedBox(height: 10),
          Text(_authError!, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600)),
        ],
        if (!_signUpMode) ...[
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() {
                _showResetPassword = !_showResetPassword;
                _resetError = null;
                _resetSent = false;
              }),
              child: Text('Forgot password?', style: TextStyle(color: tokens.mute, fontWeight: FontWeight.w600)),
            ),
          ),
          if (_showResetPassword) _buildResetPasswordForm(tokens, store),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busy ? null : () => _submitAuth(store),
            style: ElevatedButton.styleFrom(
              backgroundColor: tokens.brand,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: Text(_signUpMode ? 'Create account' : 'Log in', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _buildSignedIn(ThemeTokens tokens, AppStore store) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FunkyCard(
          child: Row(
            children: [
              Icon(Icons.verified_user, color: tokens.brand),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Signed in', style: TextStyle(color: tokens.mute, fontSize: 12)),
                    Text(store.accountEmail ?? '', style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _AccountActionRow(
          label: 'Change email',
          expanded: _showChangeEmail,
          onTap: () => setState(() {
            _showChangeEmail = !_showChangeEmail;
            _accountError = null;
          }),
        ),
        if (_showChangeEmail) _buildChangeEmailForm(tokens, store),
        const SizedBox(height: 10),
        _AccountActionRow(
          label: 'Change password',
          expanded: _showChangePassword,
          onTap: () => setState(() {
            _showChangePassword = !_showChangePassword;
            _accountError = null;
          }),
        ),
        if (_showChangePassword) _buildChangePasswordForm(tokens, store),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            // signOut() is async now and calls notifyListeners() itself once
            // Supabase confirms — store.watch above already rebuilds this
            // screen off of that, so no local setState needed to drive it.
            onPressed: () => store.signOut(),
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.danger,
              side: BorderSide(color: tokens.danger),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: const Text('Log out', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  Widget _buildChangeEmailForm(ThemeTokens tokens, AppStore store) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _newEmailController,
            keyboardType: TextInputType.emailAddress,
            decoration: _fieldDecoration(tokens, 'New email'),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _currentPasswordController,
            obscureText: true,
            decoration: _fieldDecoration(tokens, 'Current password'),
            style: TextStyle(color: tokens.ink),
          ),
          if (_accountError != null) ...[
            const SizedBox(height: 8),
            Text(_accountError!, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: () async {
              // A real email change needs a confirmation-link click before it
              // takes effect (see AppStore.changeEmail) — there's no "it
              // worked" state to collapse into yet, so (like sign-up's email
              // confirmation message) this reuses the error slot to surface
              // that instruction and deliberately leaves the form open.
              final err = await store.changeEmail(_newEmailController.text, _currentPasswordController.text);
              if (!mounted) return;
              setState(() => _accountError = err);
            },
            style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text('Save email', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _buildChangePasswordForm(ThemeTokens tokens, AppStore store) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _currentPasswordController,
            obscureText: true,
            decoration: _fieldDecoration(tokens, 'Current password'),
            style: TextStyle(color: tokens.ink),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _newPasswordController,
            obscureText: true,
            decoration: _fieldDecoration(tokens, 'New password (8+ characters)'),
            style: TextStyle(color: tokens.ink),
          ),
          if (_accountError != null) ...[
            const SizedBox(height: 8),
            Text(_accountError!, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: () async {
              final err = await store.changePassword(_currentPasswordController.text, _newPasswordController.text);
              if (!mounted) return;
              setState(() {
                _accountError = err;
                if (err == null) {
                  _showChangePassword = false;
                  _currentPasswordController.clear();
                  _newPasswordController.clear();
                }
              });
            },
            style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text('Save password', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// A REAL password-reset email now (see AppStore.resetPassword's doc
  /// comment) — there's no way to hand back a "type your new password"
  /// field directly anymore, since nothing here can prove you actually own
  /// that inbox without an emailed link. This only gets as far as "the
  /// email's been sent"; actually catching that link and finishing the
  /// reset needs deep linking, which isn't wired up yet.
  Widget _buildResetPasswordForm(ThemeTokens tokens, AppStore store) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: tokens.raised, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_resetSent)
            Text(
              "Check ${_emailController.text.trim()} for a password-reset link.",
              style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w600, fontSize: 13, height: 1.3),
            )
          else ...[
            Text(
              "We'll email the address above a reset link.",
              style: TextStyle(color: tokens.mute, fontSize: 12, height: 1.3),
            ),
            if (_resetError != null) ...[
              const SizedBox(height: 8),
              Text(_resetError!, style: TextStyle(color: tokens.danger, fontWeight: FontWeight.w600, fontSize: 13)),
            ],
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _resetBusy
                  ? null
                  : () async {
                      setState(() => _resetBusy = true);
                      final err = await store.resetPassword(_emailController.text);
                      if (!mounted) return;
                      setState(() {
                        _resetBusy = false;
                        _resetError = err;
                        _resetSent = err == null;
                      });
                    },
              style: ElevatedButton.styleFrom(backgroundColor: tokens.brand, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: Text('Send reset email', style: TextStyle(color: tokens.onOrange, fontWeight: FontWeight.w700)),
            ),
          ],
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(ThemeTokens tokens, String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: tokens.mute),
        filled: true,
        fillColor: tokens.raised,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      );
}

class _ModeTab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ModeTab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(color: active ? tokens.surface : null, borderRadius: BorderRadius.circular(8)),
          alignment: Alignment.center,
          child: Text(label, style: TextStyle(color: active ? tokens.ink : tokens.mute, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }
}

class _AccountActionRow extends StatelessWidget {
  final String label;
  final bool expanded;
  final VoidCallback onTap;
  const _AccountActionRow({required this.label, required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<FunkyTokens>()!.tokens;
    return FunkyCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: TextStyle(color: tokens.ink, fontWeight: FontWeight.w700)),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, color: tokens.mute),
            ],
          ),
        ),
      ),
    );
  }
}

/// Call this instead of calling a posting/messaging AppStore method
/// directly. If already signed in, runs [action] immediately. Otherwise it
/// pushes the account screen as a forced prompt and, the moment sign-up or
/// log-in succeeds, pops back and runs [action] — so from the UI's
/// perspective, Post/Send just works once they've created an account.
Future<void> requireAccountThen(BuildContext context, AppStore store, VoidCallback action) async {
  if (store.signedIn) {
    action();
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const AccountScreen(closeOnSuccess: true)));
  if (store.signedIn) action();
}
