import 'package:flutter/material.dart';

/// Small LED-style indicator for mesh GATT central vs peripheral activity.
class MeshRadioStatusDot extends StatelessWidget {
  const MeshRadioStatusDot({
    super.key,
    required this.connecting,
    required this.advertising,
  });

  final bool connecting;
  final bool advertising;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String tooltip;
    if (connecting) {
      color = Colors.redAccent;
      tooltip = 'Mesh: connecting (central sync)';
    } else if (advertising) {
      color = Colors.green;
      tooltip = 'Mesh: advertising + scan';
    } else {
      color = Colors.grey;
      tooltip = 'Mesh: idle (no session or radio off)';
    }

    return Tooltip(
      message: tooltip,
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.55),
              blurRadius: 5,
            ),
          ],
        ),
      ),
    );
  }
}
