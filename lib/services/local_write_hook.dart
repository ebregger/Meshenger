/// Fired after a local CRDT write so the mesh layer can push without waiting
/// for advertisement / scan. Set by [BleNetworkNotifier]; called from chat.
void Function()? onLocalCrdtWrite;
