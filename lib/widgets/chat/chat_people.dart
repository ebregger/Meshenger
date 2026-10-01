import '../../models/conversation.dart';
import '../../models/generated/mesh_data.pb.dart';
import '../../providers/ble_network_provider.dart';

class ChatPerson {
  const ChatPerson({required this.id, required this.name, this.status});

  final String id;
  final String name;

  /// Null when this phone has seen the person before but not on the mesh now.
  final PeerStatus? status;

  String get statusLabel => switch (status) {
    PeerStatus.direct => 'Nearby',
    PeerStatus.indirect => 'Reachable through the mesh',
    PeerStatus.disconnected => 'Out of range',
    null => 'Seen before',
  };
}

String chatDisplayName({
  required String nodeId,
  Map<String, String> profileNames = const {},
  Map<String, String> peerNames = const {},
}) {
  final profile = profileNames[nodeId]?.trim() ?? '';
  if (profile.isNotEmpty) return profile;
  final peer = peerNames[nodeId]?.trim() ?? '';
  if (peer.isNotEmpty) return peer;
  return nodeId.length <= 8 ? nodeId : nodeId.substring(0, 8);
}

Map<String, String> profileNameMap(List<NodeProfile> profiles) {
  final names = <String, String>{};
  for (final profile in profiles) {
    final name = profile.displayName.trim();
    if (profile.nodeId.isNotEmpty && name.isNotEmpty) {
      names[profile.nodeId] = name;
    }
  }
  return names;
}

Map<String, String> peerNameMap(List<MeshNodeState> peers) {
  return {
    for (final peer in peers)
      if (peer.id.isNotEmpty) peer.id: peer.name,
  };
}

/// Name shown for a conversation row or header.
String conversationTitle(
  String conversationId, {
  required String? myNodeId,
  Map<String, String> profileNames = const {},
  Map<String, String> peerNames = const {},
}) {
  if (conversationId.isEmpty) return 'Everyone';
  if (ConversationIds.isDirect(conversationId)) {
    final other = myNodeId == null
        ? null
        : ConversationIds.otherParty(conversationId, myNodeId);
    if (other == null || other.isEmpty) return 'Private chat';
    return chatDisplayName(
      nodeId: other,
      profileNames: profileNames,
      peerNames: peerNames,
    );
  }
  final names = [
    for (final memberId in ConversationIds.members(conversationId))
      if (memberId != myNodeId)
        chatDisplayName(
          nodeId: memberId,
          profileNames: profileNames,
          peerNames: peerNames,
        ),
  ];
  if (names.isEmpty) return 'Group chat';
  return names.join(', ');
}

/// Known profiles plus anyone currently on the mesh, excluding [myNodeId].
List<ChatPerson> chatPeople({
  required String? myNodeId,
  required List<NodeProfile> profiles,
  required List<MeshNodeState> peers,
}) {
  final names = peerNameMap(peers);
  names.addAll(profileNameMap(profiles));
  names.remove(myNodeId);
  final statuses = {for (final peer in peers) peer.id: peer.status};
  final people = [
    for (final entry in names.entries)
      if (entry.key.isNotEmpty)
        ChatPerson(
          id: entry.key,
          name: chatDisplayName(
            nodeId: entry.key,
            profileNames: names,
            peerNames: names,
          ),
          status: statuses[entry.key],
        ),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return people;
}
