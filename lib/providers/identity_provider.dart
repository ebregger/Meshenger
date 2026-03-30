import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/identity_service.dart';

final identityServiceProvider = Provider<IdentityService>((ref) {
  return IdentityService();
});

final myNodeIdProvider = FutureProvider<String>((ref) async {
  return ref.read(identityServiceProvider).getOrCreateMyNodeId();
});

