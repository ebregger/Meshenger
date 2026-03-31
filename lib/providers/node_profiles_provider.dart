import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/generated/mesh_data.pb.dart';
import 'database_provider.dart';

final nodeProfilesProvider = StreamProvider<List<NodeProfile>>((ref) async* {
  final db = await ref.watch(databaseProvider.future);
  await for (final batch in db.watchNodeProfiles()) {
    yield batch;
  }
});

