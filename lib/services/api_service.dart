import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/chat_provider.dart';
import '../providers/database_provider.dart';
import '../providers/identity_provider.dart';
import '../providers/ble_network_provider.dart';
import '../services/native_mesh_service.dart';
import '../services/ui_debug_snapshot.dart';

class ApiService {
  static HttpServer? _server;
  
  // Network simulation variables
  static double dropRate = 0.0;
  static String? ignoreMac;

  static Future<void> start(ProviderContainer container) async {
    if (_server != null) return;
    
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
      debugPrint('Stress Test API running on port 8080');
      
      _server!.listen((HttpRequest request) async {
        final path = request.uri.path;
        
        try {
          if (path == '/info' && request.method == 'GET') {
            final identityService = container.read(identityServiceProvider);
            final nodeId = await identityService.getOrCreateMyNodeId();
            _respond(request, 200, {'nodeId': nodeId, 'status': 'ok'});
            
          } else if (path == '/messages' && request.method == 'GET') {
            final db = await container.read(databaseProvider.future);
            final msgs = await db.fetchTextMessages();
            // Return only fields needed for propagation checking to minimize payload size
            final jsonList = msgs.map((m) => {
              'msgId': m.msgId,
              'textContent': m.textContent,
            }).toList();
            _respond(request, 200, {'messages': jsonList});

          } else if (path == '/has_message' && request.method == 'GET') {
            final needle = request.uri.queryParameters['text'] ?? '';
            final db = await container.read(databaseProvider.future);
            final msgs = await db.fetchTextMessages();
            final found = needle.isNotEmpty &&
                msgs.any((m) => m.textContent.contains(needle));
            _respond(request, 200, {'found': found, 'text': needle});

          } else if (path == '/ui' && request.method == 'GET') {
            // What the chat list has painted — revision bumps only when UI content changes.
            _respond(request, 200, UiDebugSnapshot.toJson());

          } else if (path == '/peers' && request.method == 'GET') {
            final peers =
                container.read(activePeersProvider).asData?.value ?? const [];
            _respond(request, 200, {
              'peers': [
                for (final p in peers)
                  {
                    'id': p.id,
                    'name': p.name,
                    'status': p.status.name,
                    'macAddress': p.macAddress,
                    'routeViaId': p.routeViaId,
                    'routeViaName': p.routeViaName,
                    'lastSeenMs': p.lastSeen.millisecondsSinceEpoch,
                  },
              ],
            });

          } else if (path == '/send' && request.method == 'POST') {
            final bodyStr = await utf8.decoder.bind(request).join();
            var body = <String, dynamic>{};
            if (bodyStr.isNotEmpty) {
              try { body = jsonDecode(bodyStr); } catch (_) {}
            }
            final text = body['text']?.toString() ?? 'Stress Test Message Ping!';
            
            final chatActions = container.read(chatActionsProvider.notifier);
            await chatActions.sendMessage(text);
            // Belt-and-suspenders: chat hook can be drowned by scan log throttle.
            container.read(bleNetworkProvider.notifier).onLocalDatabaseWrite();
            
            _respond(request, 200, {'status': 'sent', 'text': text});
            
          } else if (path == '/config' && request.method == 'POST') {
            final bodyStr = await utf8.decoder.bind(request).join();
            var body = <String, dynamic>{};
            if (bodyStr.isNotEmpty) {
              try { body = jsonDecode(bodyStr); } catch (_) {}
            }
            
            if (body.containsKey('dropRate')) {
              dropRate = (body['dropRate'] as num).toDouble();
            }
            if (body.containsKey('ignoreMac')) {
              ignoreMac = body['ignoreMac']?.toString();
            }
            if (body.containsKey('reset') && body['reset'] == true) {
              dropRate = 0.0;
              ignoreMac = null;
            }
            
            _respond(request, 200, {
              'status': 'configured',
              'dropRate': dropRate,
              'ignoreMac': ignoreMac
            });

          } else if (path == '/reset_ble' && request.method == 'POST') {
            // Closes and reopens the GATT server to flush leaked connection slots.
            // Android allows ~7 concurrent GATT server connections; after extended
            // testing they fill up and new clients can't connect until this is called.
            await NativeMeshService().resetServer();
            // IMPORTANT: Restart the GATT pipeline using the persistent provider so it binds
            // the new GATT slots and broadcasts the exact 8-byte payload again with our node ID suffix!
            await container.read(bleNetworkProvider.notifier).startAdvertising();
            _respond(request, 200, {'status': 'ble_reset'});

          } else {
            _respond(request, 404, {'error': 'Not found: $path'});
          }
        } catch (e, st) {
          debugPrint('API Error: $e\\n$st');
          _respond(request, 500, {'error': e.toString()});
        }
      });
    } catch (e) {
      debugPrint('Failed to start API Server: $e');
    }
  }

  static void _respond(HttpRequest request, int statusCode, Map<String, dynamic> data) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(data))
      ..close();
  }
}
