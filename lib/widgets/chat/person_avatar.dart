import 'package:flutter/material.dart';

/// Round avatar with the person's initial on a colour picked from their id.
/// A selected avatar swaps the initial for a check mark, like Google Messages.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.selected = false,
    this.radius = 22,
  });

  final String id;
  final String name;
  final bool selected;
  final double radius;

  static const _palette = <Color>[
    Color(0xFF5B7DB1),
    Color(0xFF3F9E8F),
    Color(0xFFB0705B),
    Color(0xFF8A6BB5),
    Color(0xFF6E9B4E),
    Color(0xFFB0567B),
    Color(0xFFB08F3F),
    Color(0xFF4E8FA8),
  ];

  static String initialOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _palette[id.hashCode.abs() % _palette.length];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? scheme.primary : color,
      ),
      alignment: Alignment.center,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: selected
            ? Icon(
                Icons.check,
                key: const ValueKey('selected'),
                size: radius,
                color: scheme.onPrimary,
              )
            : Text(
                initialOf(name),
                key: const ValueKey('initial'),
                style: TextStyle(
                  color: Colors.white,
                  fontSize: radius * 0.9,
                  fontWeight: FontWeight.w500,
                ),
              ),
      ),
    );
  }
}
