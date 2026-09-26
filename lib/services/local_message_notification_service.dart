import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final localMessageNotificationServiceProvider =
    Provider<LocalMessageNotificationService>(
      (ref) => LocalMessageNotificationService(),
    );

/// Bumps whenever a message notification is tapped while the app is running.
final messageNotificationTapEvents = ValueNotifier<int>(0);

/// Posts privacy-preserving notifications for messages received in the background.
class LocalMessageNotificationService {
  LocalMessageNotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _channelId = 'incoming_messages';
  static const _channelName = 'Messages';
  static const _channelDescription =
      'Alerts when Meshenger receives a message in the background.';

  final FlutterLocalNotificationsPlugin _plugin;
  Future<void>? _initialization;

  AndroidFlutterLocalNotificationsPlugin? get _androidPlugin => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_meshenger'),
      ),
      onDidReceiveNotificationResponse: (_) {
        messageNotificationTapEvents.value++;
      },
    );
  }

  Future<bool?> areNotificationsEnabled() async {
    await initialize();
    return _androidPlugin?.areNotificationsEnabled();
  }

  Future<bool> requestNotificationsPermission() async {
    await initialize();
    return await _androidPlugin?.requestNotificationsPermission() ?? false;
  }

  Future<void> openNotificationSettings() async {
    await initialize();
    await _plugin.openAppNotificationSettings();
  }

  Future<bool> showIncomingMessage(String messageId) async {
    try {
      await initialize();
      final android = _androidPlugin;
      if (android == null || await android.areNotificationsEnabled() != true) {
        return false;
      }

      await _plugin.show(
        id: _notificationId(messageId),
        title: 'Meshenger',
        body: 'New message',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            icon: 'ic_stat_meshenger',
            category: AndroidNotificationCategory.message,
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.private,
            autoCancel: true,
          ),
        ),
      );
      return true;
    } catch (error, stackTrace) {
      debugPrint(
        'Unable to show incoming message notification: $error\n$stackTrace',
      );
      return false;
    }
  }

  int _notificationId(String messageId) {
    // A stable positive ID means duplicate stream updates refresh the same alert.
    var hash = 0x811c9dc5;
    for (final codeUnit in messageId.codeUnits) {
      hash = ((hash ^ codeUnit) * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }
}
