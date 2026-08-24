import 'package:flutter/material.dart';

class DiagnosticTile extends StatelessWidget {
  const DiagnosticTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.isOk,
    required this.onFix,
    required this.fixLabel,
    this.warningColor,
  });

  final String title;
  final String? subtitle;
  final bool isOk;
  final VoidCallback onFix;
  final String fixLabel;
  final Color? warningColor;

  @override
  Widget build(BuildContext context) {
    final statusColor = isOk ? (warningColor ?? Colors.green) : Colors.red;

    return ListTile(
      leading: Icon(
        isOk
            ? (warningColor != null ? Icons.warning_amber : Icons.check_circle)
            : Icons.error,
        color: statusColor,
      ),
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: !isOk
          ? OutlinedButton(onPressed: onFix, child: Text(fixLabel))
          : null,
    );
  }
}
