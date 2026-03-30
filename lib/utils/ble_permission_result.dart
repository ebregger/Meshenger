/// Outcome of an Android BLE permission request (for UI: retry vs Settings).
enum BlePermissionRequestResult {
  granted,
  denied,
  permanentlyDenied,
}

/// Thrown when a caller opts into strict handling and the user chose "Don't ask again".
class BlePermissionsPermanentlyDeniedException implements Exception {
  const BlePermissionsPermanentlyDeniedException();

  @override
  String toString() =>
      'Bluetooth permissions were permanently denied. Open app settings to enable them.';
}
