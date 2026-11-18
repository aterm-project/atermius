class WorkspaceAgentNode {
  WorkspaceAgentNode.fromJson(Map<String, dynamic> json)
    : name = json['name'] as String,
      fingerprint = json['fingerprint'] as String,
      enabled = json['enabled'] as bool,
      revision = json['revision'] as int,
      online = json['online'] as bool,
      seen = json['last_seen_seconds_ago'] as int?,
      network = json['network'] as String,
      hostSsh = json['host_ssh'] as bool,
      image = json['image'] as String;

  final String name, fingerprint, network, image;
  final bool enabled, online, hostSsh;
  final int revision;
  final int? seen;
}

class ManagedCluster {
  ManagedCluster.fromJson(Map<String, dynamic> json)
    : name = json['cluster'] as String,
      node = json['node'] as String,
      target = json['target'] as String?,
      retryingOn = json['retrying_on'] as String?,
      phase = json['phase'] as String,
      generation = json['generation'] as int,
      port = json['port'] as int,
      cleanup = json['pending_cleanup'] as int,
      kind = json['type'] as String,
      snapshotBytes = json['snapshot_bytes'] as int?,
      transferred = (json['transfer'] as Map?)?['bytes'] as int?,
      total = (json['transfer'] as Map?)?['total'] as int?;

  final String name, node, phase, kind;
  final String? target, retryingOn;
  final int generation, port, cleanup;
  final int? snapshotBytes, transferred, total;
  bool get canAbort => phase == 'Snapshot' || phase == 'Restore';
}

class WorkspaceAgentOverview {
  WorkspaceAgentOverview.fromJson(Map<String, dynamic> json)
    : configured = json['configured'] as bool,
      sshHost = json['ssh_host'] as String?,
      nodes = (json['nodes'] as List)
          .cast<Map<String, dynamic>>()
          .map(WorkspaceAgentNode.fromJson)
          .toList(),
      clusters = (json['clusters'] as List)
          .cast<Map<String, dynamic>>()
          .map(ManagedCluster.fromJson)
          .toList();
  final bool configured;
  final String? sshHost;
  final List<WorkspaceAgentNode> nodes;
  final List<ManagedCluster> clusters;

  List<WorkspaceAgentNode> destinations(ManagedCluster cluster) {
    final owner = nodes.where((n) => n.name == cluster.node).firstOrNull;
    if (owner == null ||
        cluster.kind != 'workspace' ||
        cluster.phase != 'Running')
      return [];
    return nodes
        .where(
          (n) =>
              n.name != owner.name &&
              n.enabled &&
              n.image == owner.image &&
              n.network == owner.network,
        )
        .toList();
  }
}
