import 'package:flutter/material.dart';

/// Design tokens for the Feedback Machine app. Never hardcode a colour,
/// radius, shadow, or motion value anywhere else — always reference these.
class AppTokens {
  AppTokens._();

  // ── Palette ──────────────────────────────────────────────
  static const Color verdant = Color(0xFF1B4D3E);
  static const Color verdantMid = Color(0xFF2E6B52);
  static const Color verdantLit = Color(0xFF3D8A68);
  static const Color sageFill = Color(0xFFE8F2EC);
  static const Color ivory = Color(0xFFF9F6EE);
  static const Color parchment = Color(0xFFEDE8D9);
  static const Color border = Color(0xFFD4C9B0);
  static const Color borderMid = Color(0xFFC0B49A);
  static const Color ink = Color(0xFF1C1C1A);
  static const Color inkMid = Color(0xFF4A4438);
  static const Color inkMuted = Color(0xFF8C7B6B);
  static const Color amber = Color(0xFFB5813D);
  static const Color amberLit = Color(0xFFF5E9D0);
  static const Color white = Color(0xFFFFFFFF);
  static const Color error = Color(0xFF922B21);
  static const Color errorMid = Color(0xFFC0392B);
  static const Color errorLit = Color(0xFFFDECEA);

  // ── Rating accent colours ────────────────────────────────
  static const Color cVeryGood = Color(0xFF1B4D3E);
  static const Color cGood = Color(0xFF2E6B52);
  static const Color cSatisfact = Color(0xFFB5813D);
  static const Color cPoor = Color(0xFF922B21);
  static const Color cVeryPoor = Color(0xFF6B1A1A);

  // ── Radii ────────────────────────────────────────────────
  static const double radiusXs = 6;
  static const double radiusSm = 10;
  static const double radiusMd = 14;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  // ── Shadows ──────────────────────────────────────────────
  static const List<BoxShadow> shCard = [
    BoxShadow(
      color: Color(0x121C1C1A), // black 7%
      blurRadius: 10,
      offset: Offset(0, 2),
    ),
    BoxShadow(
      color: Color(0x0A1C1C1A), // black 4%
      blurRadius: 3,
      offset: Offset(0, 1),
    ),
  ];

  static const List<BoxShadow> shFloat = [
    BoxShadow(
      color: Color(0x2E000000), // black 18%
      blurRadius: 40,
      offset: Offset(0, 12),
    ),
    BoxShadow(
      color: Color(0x14000000), // black 8%
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> shModal = [
    BoxShadow(
      color: Color(0x4D000000), // black 30%
      blurRadius: 80,
      offset: Offset(0, 28),
    ),
    BoxShadow(
      color: Color(0x24000000), // black 14%
      blurRadius: 24,
      offset: Offset(0, 8),
    ),
  ];

  // ── Motion ───────────────────────────────────────────────
  static const Duration durFast = Duration(milliseconds: 160);
  static const Duration durMid = Duration(milliseconds: 220);
  static const Curve curveStandard = Curves.easeInOutCubic;
  static const Curve curveSpring = Cubic(0.34, 1.56, 0.64, 1.0);

  /// Used only for the feedback dialog's enter animation (§3.4).
  static const Curve curveDialogEnter = Cubic(0.34, 1.24, 0.64, 1.0);
}
