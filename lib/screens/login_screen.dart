import 'package:flutter/material.dart';

import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../theme/responsive.dart';
import '../theme/tokens.dart';
import '../widgets/app_alerts.dart';

/// The admin login card (§3.2). Calls [ApiService.login] on submit and,
/// on success, persists the org id and calls [onLoginSuccess].
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLoginSuccess});

  final ValueChanged<int> onLoginSuccess;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _api = ApiService();
  final _storage = StorageService();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscure = true;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);

    final result = await _api.login(
      _emailController.text,
      _passwordController.text,
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    switch (result) {
      case LoginSuccess(:final orgId):
        await _storage.setOrgId(orgId);
        if (!mounted) return;
        widget.onLoginSuccess(orgId);
      case LoginFailure(:final message):
        await showErrorAlert(
          context,
          title: 'লগইন ব্যর্থ',
          message: message,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final responsive = Responsive.of(context);
    final width = responsive.width;
    final needsMargin = width < 460;
    final iconSize = responsive.loginIconSize;
    final titleSize = responsive.loginTitleSize;

    return Container(
      margin: needsMargin
          ? const EdgeInsets.symmetric(horizontal: 16)
          : EdgeInsets.zero,
      constraints: BoxConstraints(maxWidth: responsive.loginCardMaxWidth),
      padding: responsive.loginCardPadding,
      decoration: BoxDecoration(
        color: AppTokens.ivory,
        borderRadius: BorderRadius.circular(AppTokens.radiusXl),
        border: Border.all(color: AppTokens.white.withOpacity(0.14)),
        boxShadow: AppTokens.shModal,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: iconSize,
            height: iconSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTokens.verdant,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                  color: AppTokens.verdant.withOpacity(0.38),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Icon(
              Icons.local_hospital,
              color: AppTokens.white,
              size: iconSize * 0.367, // 22/60 of the original icon size
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'অ্যাডমিন প্যানেল',
            style: TextStyle(
              fontFamily: AppTheme.headingFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontWeight: FontWeight.w700,
              fontSize: titleSize,
              color: AppTokens.ink,
              letterSpacing: -0.02 * titleSize,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            'আপনার অ্যাকাউন্টে প্রবেশ করুন',
            style: TextStyle(
              fontFamily: AppTheme.bodyFontFamily,
              fontFamilyFallback: AppTheme.bengaliFallback,
              fontSize: 13,
              color: AppTokens.inkMuted,
            ),
          ),
          const SizedBox(height: 36),
          _AuthField(
            label: 'ইমেইল',
            hint: 'admin@example.com',
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          _AuthField(
            label: 'পাসওয়ার্ড',
            hint: '••••••••',
            controller: _passwordController,
            obscureText: _obscure,
            suffix: _EyeToggle(
              obscured: _obscure,
              onToggle: () => setState(() => _obscure = !_obscure),
            ),
          ),
          const SizedBox(height: 10),
          _PrimaryLoginButton(onPressed: _submit, loading: _isSubmitting),
        ],
      ),
    );
  }
}

class _AuthField extends StatefulWidget {
  const _AuthField({
    required this.label,
    required this.hint,
    required this.controller,
    this.obscureText = false,
    this.keyboardType,
    this.suffix,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffix;

  @override
  State<_AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<_AuthField> {
  final _focusNode = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() => _focused = _focusNode.hasFocus);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontFamily: AppTheme.bodyFontFamily,
            fontFamilyFallback: AppTheme.bengaliFallback,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppTokens.inkMid,
            letterSpacing: 1.32, // 0.12em * 11px
          ),
        ),
        const SizedBox(height: 7),
        AnimatedContainer(
          duration: AppTokens.durFast,
          curve: AppTokens.curveStandard,
          decoration: BoxDecoration(
            color: AppTokens.white,
            borderRadius: BorderRadius.circular(AppTokens.radiusSm),
            border: Border.all(
              color: _focused ? AppTokens.verdant : AppTokens.border,
              width: 1.5,
            ),
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: AppTokens.verdant.withOpacity(0.12),
                      spreadRadius: 3,
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _focusNode,
                  obscureText: widget.obscureText,
                  keyboardType: widget.keyboardType,
                  style: const TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontFamilyFallback: AppTheme.bengaliFallback,
                    fontSize: 15,
                    color: AppTokens.ink,
                  ),
                  cursorColor: AppTokens.verdant,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: widget.hint,
                    hintStyle: const TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontSize: 15,
                      color: AppTokens.inkMuted,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              if (widget.suffix != null) widget.suffix!,
            ],
          ),
        ),
      ],
    );
  }
}

class _EyeToggle extends StatefulWidget {
  const _EyeToggle({required this.obscured, required this.onToggle});

  final bool obscured;
  final VoidCallback onToggle;

  @override
  State<_EyeToggle> createState() => _EyeToggleState();
}

class _EyeToggleState extends State<_EyeToggle> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 11, 6),
        child: Icon(
          widget.obscured ? Icons.visibility : Icons.visibility_off,
          size: 18,
          color: _pressed ? AppTokens.ink : AppTokens.inkMuted,
        ),
      ),
    );
  }
}

class _PrimaryLoginButton extends StatefulWidget {
  const _PrimaryLoginButton({required this.onPressed, required this.loading});

  final VoidCallback onPressed;
  final bool loading;

  @override
  State<_PrimaryLoginButton> createState() => _PrimaryLoginButtonState();
}

class _PrimaryLoginButtonState extends State<_PrimaryLoginButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.loading ? null : widget.onPressed,
      child: AnimatedContainer(
        duration: AppTokens.durMid,
        curve: AppTokens.curveStandard,
        width: double.infinity,
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.symmetric(vertical: 13, horizontal: 20),
        transform: Matrix4.translationValues(0, _pressed ? -1 : 0, 0),
        decoration: BoxDecoration(
          color: _pressed ? AppTokens.verdantMid : AppTokens.verdant,
          borderRadius: BorderRadius.circular(AppTokens.radiusSm),
          boxShadow: [
            BoxShadow(
              color: AppTokens.verdant.withOpacity(_pressed ? 0.38 : 0.32),
              blurRadius: _pressed ? 22 : 14,
              offset: Offset(0, _pressed ? 7 : 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.login, color: AppTokens.white, size: 18),
            SizedBox(width: 9),
            Text(
              'প্রবেশ করুন',
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontFamilyFallback: AppTheme.bengaliFallback,
                color: AppTokens.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
