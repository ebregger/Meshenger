import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart';
import '../../providers/ble_network_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/conversation_provider.dart';
import '../../providers/identity_provider.dart';
import '../../providers/node_profiles_provider.dart';
import 'chat_people.dart';
import 'person_avatar.dart';

Future<void> openNewChatPage(BuildContext context) {
  return Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const NewChatPage()));
}

/// Pick one person for a private chat or several for a group, laid out like
/// Google Messages: a "To:" field of chips, suggested chats, then everyone
/// grouped by first letter.
class NewChatPage extends ConsumerStatefulWidget {
  const NewChatPage({super.key});

  @override
  ConsumerState<NewChatPage> createState() => _NewChatPageState();
}

class _NewChatPageState extends ConsumerState<NewChatPage> {
  final List<String> _selected = <String>[];
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      _query.clear();
    });
  }

  bool _matches(ChatPerson person, String query) {
    if (query.isEmpty) return true;
    return person.name.toLowerCase().contains(query) ||
        person.id.toLowerCase().startsWith(query);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final myIdAsync = ref.watch(myNodeIdProvider);
    final myId = myIdAsync.asData?.value;
    final profilesAsync = ref.watch(nodeProfilesProvider);
    // The database and identity load a moment after the app opens. Don't say
    // nobody is known until both have answered.
    final loadingPeople =
        (myIdAsync.isLoading && !myIdAsync.hasValue) ||
        (profilesAsync.isLoading && !profilesAsync.hasValue);
    final profiles = profilesAsync.asData?.value ?? const [];
    final peers = ref.watch(activePeersProvider).asData?.value ?? const [];
    final people = chatPeople(myNodeId: myId, profiles: profiles, peers: peers);
    final byId = {for (final person in people) person.id: person};
    final profileNames = profileNameMap(profiles);
    final peerNames = peerNameMap(peers);

    final pinned = ref.watch(pinnedConversationIdsProvider);
    final stored =
        ref.watch(privateConversationIdsProvider).asData?.value ?? const [];
    final previews =
        ref.watch(conversationPreviewsProvider).asData?.value ?? const [];
    final previewById = {
      for (final preview in previews) preview.conversationId: preview,
    };
    final existingIds = <String>{...pinned, ...stored};
    final conversationId = myId == null
        ? ''
        : ConversationIds.forMembers(myNodeId: myId, otherIds: _selected);
    final alreadyExists =
        conversationId.isNotEmpty && existingIds.contains(conversationId);

    final query = _query.text.trim().toLowerCase();
    final visiblePeople = people
        .where((person) => _matches(person, query))
        .toList();

    // Existing chats that include everyone picked so far.
    final suggestions =
        existingIds.where((id) {
          final members = ConversationIds.members(id);
          return _selected.every(members.contains);
        }).toList()..sort(
          (a, b) => (previewById[b]?.timestampMs ?? 0).compareTo(
            previewById[a]?.timestampMs ?? 0,
          ),
        );

    final fabLabel = alreadyExists
        ? 'Open chat'
        : _selected.length > 1
        ? 'Start group'
        : 'Start chat';

    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.length > 1 ? 'New group' : 'New chat'),
      ),
      floatingActionButton: _selected.isEmpty
          ? null
          : FloatingActionButton.extended(
              key: const Key('start_chat_button'),
              onPressed: () => _start(myId, conversationId),
              icon: const Icon(Icons.arrow_forward),
              label: Text(fabLabel),
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _toField(context, byId, profileNames, peerNames),
          Divider(height: 1, color: scheme.outlineVariant),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                if (suggestions.isNotEmpty) ...[
                  _sectionLabel(context, 'Suggested'),
                  for (final id in suggestions)
                    _suggestionTile(
                      context,
                      id,
                      myId: myId,
                      preview: previewById[id]?.preview,
                      profileNames: profileNames,
                      peerNames: peerNames,
                    ),
                ],
                if (loadingPeople)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else
                  ..._peopleSection(context, visiblePeople, people.isEmpty),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _toField(
    BuildContext context,
    Map<String, ChatPerson> byId,
    Map<String, String> profileNames,
    Map<String, String> peerNames,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Text(
              'To:',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final id in _selected)
                  InputChip(
                    key: ValueKey('to_chip_$id'),
                    avatar: PersonAvatar(
                      id: id,
                      name: byId[id]?.name ?? id,
                      radius: 12,
                    ),
                    label: Text(
                      byId[id]?.name ??
                          chatDisplayName(
                            nodeId: id,
                            profileNames: profileNames,
                            peerNames: peerNames,
                          ),
                    ),
                    backgroundColor: scheme.secondaryContainer,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    onDeleted: () => _toggle(id),
                  ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    key: const Key('new_chat_query'),
                    controller: _query,
                    focusNode: _queryFocus,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _selected.isEmpty ? 'Type a name' : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _suggestionTile(
    BuildContext context,
    String conversationId, {
    required String? myId,
    required String? preview,
    required Map<String, String> profileNames,
    required Map<String, String> peerNames,
  }) {
    final title = conversationTitle(
      conversationId,
      myNodeId: myId,
      profileNames: profileNames,
      peerNames: peerNames,
    );
    final scheme = Theme.of(context).colorScheme;
    final other = myId == null
        ? null
        : ConversationIds.otherParty(conversationId, myId);
    return ListTile(
      key: ValueKey('suggested_$conversationId'),
      leading: other != null
          ? PersonAvatar(id: other, name: title)
          : CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
              child: const Icon(Icons.group_outlined),
            ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: preview == null || preview.isEmpty
          ? null
          : Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        openConversation(ref, conversationId);
        Navigator.of(context).pop();
      },
    );
  }

  List<Widget> _peopleSection(
    BuildContext context,
    List<ChatPerson> visiblePeople,
    bool nobodyKnown,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (visiblePeople.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            nobodyKnown
                ? 'People you have seen on the mesh show up here.'
                : 'No one matches that name.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ];
    }
    final widgets = <Widget>[];
    String? currentLetter;
    for (final person in visiblePeople) {
      final initial = PersonAvatar.initialOf(person.name);
      final letter = RegExp(r'[A-Z]').hasMatch(initial) ? initial : '#';
      if (letter != currentLetter) {
        currentLetter = letter;
        widgets.add(_sectionLabel(context, letter));
      }
      final selected = _selected.contains(person.id);
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: ListTile(
            key: ValueKey('chat_person_${person.id}'),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            tileColor: selected
                ? scheme.secondaryContainer.withValues(alpha: 0.6)
                : null,
            leading: PersonAvatar(
              id: person.id,
              name: person.name,
              selected: selected,
            ),
            title: Text(
              person.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              person.statusLabel,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            onTap: () => _toggle(person.id),
          ),
        ),
      );
    }
    return widgets;
  }

  void _start(String? myId, String conversationId) {
    if (myId == null || myId.isEmpty || conversationId.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Still starting up.')));
      return;
    }
    openConversation(ref, conversationId);
    Navigator.of(context).pop();
  }
}
