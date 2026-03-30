import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/database_service.dart';

final databaseProvider = FutureProvider<DatabaseService>((ref) async {
  final service = DatabaseService();
  await service.init();
  ref.onDispose(service.dispose);
  return service;
});
