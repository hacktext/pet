import 'package:flutter/material.dart';

import 'main_window_model.dart';
import 'theme.dart';

const _accentDeep = Color(0xFFE0673A);

/// Opens the sign-in page; it closes itself once the account is signed in.
Future<void> openLogin(BuildContext context, MainWindowModel model, {String? reason}) {
  model.clearAccountError();
  return Navigator.of(context).push(narrowRoute<void>(
    builder: (_) => LoginPage(model: model, reason: reason),
  ));
}

/// Phone number and SMS code on a page of their own (web platform spec 8).
/// The pet window does the work; this only asks.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.model, this.reason});

  final MainWindowModel model;

  /// Why sign-in was asked for (立即定制 while signed out), under the title.
  final String? reason;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  bool _closed = false;

  MainWindowModel get _m => widget.model;

  @override
  void initState() {
    super.initState();
    _m.addListener(_changed);
  }

  @override
  void dispose() {
    _m.removeListener(_changed);
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (_m.account.signedIn && !_closed) {
      _closed = true;
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final busy = _m.accountBusy;
    final wait = _m.codeWait;
    final error = _m.accountError;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFEFE2), AppColors.page, Color(0xFFFFF3EA)],
          ),
        ),
        child: SafeArea(
          child: Stack(children: [
            Positioned(
              left: 8,
              top: 8,
              child: IconButton(
                tooltip: '返回',
                icon: const Icon(Icons.arrow_back, color: AppColors.text),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [AppColors.accent, _accentDeep]),
                      ),
                      child: const Icon(Icons.pets, size: 40, color: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Text('AI 桌宠',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.text)),
                  const SizedBox(height: 8),
                  Text(widget.reason ?? '手机号验证码登录，未注册将自动创建账号',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14, color: AppColors.textMuted)),
                  const SizedBox(height: 32),
                  _Field(
                    icon: Icons.phone_iphone,
                    child: TextField(
                      key: const Key('account-phone'),
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      decoration: const InputDecoration(
                          hintText: '手机号', border: InputBorder.none, counterText: '', isDense: true),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _Field(
                    icon: Icons.lock_outline,
                    trailing: TextButton(
                      onPressed: busy || wait > 0 ? null : () => _m.sendCode(_phone.text),
                      child: Text(wait > 0 ? '$wait秒后重发' : '获取验证码'),
                    ),
                    child: TextField(
                      key: const Key('account-code'),
                      controller: _code,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      onSubmitted: (_) => busy ? null : _m.login(_phone.text, _code.text),
                      decoration: const InputDecoration(
                          hintText: '验证码', border: InputBorder.none, counterText: '', isDense: true),
                    ),
                  ),
                  SizedBox(
                    height: 36,
                    child: error == null
                        ? null
                        : Padding(
                            padding: const EdgeInsets.only(top: 10, left: 4),
                            child: Text(error,
                                style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error)),
                          ),
                  ),
                  _GradientButton(
                    label: '登录',
                    busy: busy,
                    onPressed: busy ? null : () => _m.login(_phone.text, _code.text),
                  ),
                  const SizedBox(height: 20),
                  const Text('登录后，宠物和养成数据可在多台电脑间同步，还能定制专属宠物',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// A rounded, softly shadowed field with a leading icon.
class _Field extends StatelessWidget {
  const _Field({required this.icon, required this.child, this.trailing});

  final IconData icon;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
        constraints: const BoxConstraints(minHeight: 58),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFF5DCC8)),
          boxShadow: const [BoxShadow(color: Color(0x14F08A3C), blurRadius: 16, offset: Offset(0, 6))],
        ),
        child: Row(children: [
          Icon(icon, color: AppColors.textMuted),
          const SizedBox(width: 12),
          Expanded(child: child),
          ?trailing,
        ]),
      );
}

class _GradientButton extends StatelessWidget {
  const _GradientButton({required this.label, required this.busy, required this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onPressed == null ? 0.6 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: const LinearGradient(colors: [AppColors.accent, _accentDeep]),
            boxShadow: const [BoxShadow(color: Color(0x33E0673A), blurRadius: 14, offset: Offset(0, 6))],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onPressed,
              child: SizedBox(
                height: 56,
                child: Center(
                  child: busy
                      ? const SizedBox(
                          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                      : Text(label,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ),
          ),
        ),
      );
}
