import 'package:flutter/material.dart';

import '../../screens/key_verification_screen.dart';

class PrivacyAndLicenses extends StatelessWidget {
  const PrivacyAndLicenses({super.key});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Privacy', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 10),
      const Text(
        'Everyone is a public room. Nearby Meshenger phones can read, store and relay its messages. Private and group chats relay encrypted contents, but participant IDs, timestamps and chat membership remain visible. Deleting messages changes your phone only.',
      ),
      const SizedBox(height: 8),
      const Text(
        'Compare encryption fingerprints with the other person before sharing sensitive information. Android backup and phone-to-phone data transfer are disabled for Meshenger. Uninstalling loses this phone’s identity and history.',
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.key_outlined),
        title: const Text('Your encryption fingerprint'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const KeyVerificationScreen(),
          ),
        ),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.description_outlined),
        title: const Text('Third-party licenses'),
        subtitle: const Text('Meshenger’s own source is currently unlicensed.'),
        onTap: () =>
            showLicensePage(context: context, applicationName: 'Meshenger'),
      ),
    ],
  );
}
