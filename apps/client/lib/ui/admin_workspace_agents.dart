import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/workspace_agents.dart';
import '../app_controller.dart';
import '../domain/quick_connect.dart';
import '../l10n/l10n.dart';
import 'app_motion.dart';

class WorkspaceAgentsAdmin extends StatefulWidget {
  const WorkspaceAgentsAdmin({
    super.key,
    required this.app,
    required this.onConnect,
  });
  final AppController app;
  final ValueChanged<QuickConnectRequest> onConnect;
  @override
  State<WorkspaceAgentsAdmin> createState() => _WorkspaceAgentsAdminState();
}

class _WorkspaceAgentsAdminState extends State<WorkspaceAgentsAdmin>
    with WidgetsBindingObserver {
  WorkspaceAgentOverview? _data;
  String? _error;
  Timer? _timer;
  bool _loading = false, _editing = false;
  Route<dynamic>? _dialog;
  int _epoch = 0;
  late final _scope = (
    widget.app,
    widget.app.api,
    widget.app.session?.accountId,
    widget.app.session?.deviceId,
    widget.app.instance?.instanceId,
    widget.app.instance?.generation,
  );
  bool get _current =>
      mounted &&
      widget.app.isInstanceAdmin &&
      _scope ==
          (
            widget.app,
            widget.app.api,
            widget.app.session?.accountId,
            widget.app.session?.deviceId,
            widget.app.instance?.instanceId,
            widget.app.instance?.generation,
          );
  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) unawaited(_load());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed &&
        _current &&
        !_editing &&
        !_loading) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    final route = _dialog;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    super.dispose();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_current || !_foreground || _editing || _data?.configured == false) {
      return;
    }
    final moving =
        _data?.clusters.any((c) => c.phase != 'Running' || c.cleanup > 0) ??
        false;
    _timer = Timer(Duration(seconds: moving ? 3 : 10), () {
      if (_current && !_editing) unawaited(_load());
    });
  }

  String _message(Object e) {
    final l = context.l10n;
    return switch (e) {
      ApiException(code: 'WORKSPACE_CONFLICT') => l.waConflict,
      ApiException(code: 'INVALID_WORKSPACE_ACTION') => l.waInvalid,
      ApiException(statusCode: 401 || 403) =>
        l.theCurrentAccountDoesntHaveInstance,
      _ => l.waUnavailable,
    };
  }

  Future<void> _load({bool keepError = false}) async {
    final api = widget.app.api;
    if (!_current || api == null) return;
    _timer?.cancel();
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      if (!keepError) _error = null;
    });
    try {
      final next = await api.workspaceAgents();
      if (_current && _epoch == epoch) setState(() => _data = next);
    } catch (e) {
      if (_current && _epoch == epoch) {
        setState(() {
          _data = null;
          _error = _message(e);
        });
      }
    } finally {
      if (_current && _epoch == epoch) {
        setState(() => _loading = false);
        _schedule();
      }
    }
  }

  Future<void> _edit(Widget Function(BuildContext) form) async {
    final api = widget.app.api;
    if (!_current || _editing || _loading || api == null) return;
    _timer?.cancel();
    setState(() {
      _editing = true;
      _error = null;
    });
    try {
      final command = await showAppDialog<Map<String, Object?>>(
        context: context,
        builder: (ctx) {
          _dialog = ModalRoute.of(ctx);
          return form(ctx);
        },
      );
      _dialog = null;
      if (command == null || !_current) return;
      await api.manageWorkspaceAgent(command);
    } catch (e) {
      if (_current) setState(() => _error = _message(e));
    } finally {
      if (_current) {
        setState(() => _editing = false);
        await _load(keepError: _error != null);
      }
    }
  }

  Future<void> _confirm(
    String title,
    String message,
    Map<String, Object?> command,
  ) => _edit(
    (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(ctx.l10n.cancel),
        ),
        FilledButton(
          key: const ValueKey('workspace_confirm'),
          onPressed: () => Navigator.pop(ctx, command),
          child: Text(title),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final l = context.l10n, data = _data;
    final busy = _editing || _loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: IconButton(
            key: const ValueKey('workspace_agents_refresh'),
            tooltip: l.refresh,
            icon: const Icon(Icons.refresh),
            onPressed: busy ? null : () => _load(),
          ),
        ),
        if (_loading && data == null) const LinearProgressIndicator(),
        if (_error != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (data != null && !data.configured)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(l.waNotConfigured),
            ),
          ),
        if (data != null && data.configured) ...[
          _card(l.waNodes, [
            OutlinedButton.icon(
              key: const ValueKey('workspace_register_node'),
              onPressed: busy
                  ? null
                  : () => _edit((_) => const _RegisterNode()),
              icon: const Icon(Icons.add),
              label: Text(l.waRegister),
            ),
            if (data.nodes.isEmpty) Text(l.waNoNodes),
            for (final n in data.nodes)
              ExpansionTile(
                key: PageStorageKey('workspace_node_${n.name}'),
                tilePadding: EdgeInsets.zero,
                title: Text(n.name),
                subtitle: Text(
                  [
                    n.enabled ? l.enabled : l.disabled,
                    n.online ? l.waOnline : l.offline,
                    n.seen == null ? l.waNeverSeen : l.waLastSeen(n.seen!),
                  ].join(' · '),
                ),
                children: [
                  _detail(l.waFingerprint, n.fingerprint),
                  if (n.image.isNotEmpty) _detail(l.waImage, n.image),
                  _detail(l.waNetwork, n.network),
                  if (n.hostSsh) _detail(l.waHost, l.enabled),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: ValueKey('workspace_toggle_${n.name}'),
                      onPressed: busy
                          ? null
                          : () => _confirm(
                              n.enabled ? l.waDisable : l.waEnable,
                              n.enabled
                                  ? '${n.name}\n${l.waDisableInfo}'
                                  : n.name,
                              {
                                'action': 'set_node_enabled',
                                'node': n.name,
                                'enabled': !n.enabled,
                                'expected_revision': n.revision,
                              },
                            ),
                      child: Text(n.enabled ? l.waDisable : l.waEnable),
                    ),
                  ),
                ],
              ),
          ]),
          _card(l.waClusters, [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final host in [false, true])
                  OutlinedButton(
                    key: ValueKey(
                      host
                          ? 'workspace_publish_host'
                          : 'workspace_create_cluster',
                    ),
                    onPressed:
                        busy ||
                            !data.nodes.any(
                              (n) =>
                                  n.enabled &&
                                  (host ? n.hostSsh : n.image.isNotEmpty),
                            )
                        ? null
                        : () => _edit(
                            (_) => _CreateCluster(
                              nodes: data.nodes
                                  .where(
                                    (n) =>
                                        n.enabled &&
                                        (host ? n.hostSsh : n.image.isNotEmpty),
                                  )
                                  .toList(),
                              host: host,
                            ),
                          ),
                    child: Text(host ? l.waPublish : l.waCreate),
                  ),
              ],
            ),
            if (data.clusters.isEmpty) Text(l.waNoClusters),
            for (final c in data.clusters) _cluster(data, c, busy),
          ]),
        ],
      ],
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    ),
  );
  Widget _detail(String label, String value) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SelectableText('$label · $value', key: PageStorageKey(label)),
    ),
  );
  Widget _cluster(WorkspaceAgentOverview data, ManagedCluster c, bool busy) {
    final l = context.l10n;
    final targets = data.destinations(c);
    final address = data.sshHost;
    final hasAddress =
        address != null &&
        address.isNotEmpty &&
        address != '0.0.0.0' &&
        address != '::';
    final endpoint = hasAddress
        ? '${address.contains(':') ? '[$address]' : address}:${c.port}'
        : '${l.port} · ${c.port}';
    return ExpansionTile(
      key: PageStorageKey('workspace_cluster_${c.name}'),
      tilePadding: EdgeInsets.zero,
      title: Text(c.name),
      subtitle: Text(
        [
          l.waPhase(c.phase),
          c.target == null ? c.node : '${c.node} → ${c.target}',
        ].join(' · '),
      ),
      children: [
        _detail(c.kind == 'host' ? l.waHost : l.waWorkspace, endpoint),
        if (c.retryingOn != null)
          Text(
            l.waRetrying(c.retryingOn!),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (c.transferred != null && (c.total ?? 0) > 0) ...[
          LinearProgressIndicator(
            value: c.transferred! / c.total!,
            semanticsLabel: l.waPhase(c.phase),
          ),
          Text(
            '${l.waPhase(c.phase)} · ${(100 * c.transferred! / c.total!).floor()}%',
          ),
        ] else if (c.snapshotBytes != null)
          _detail(l.waPhase(c.phase), l.waSnapshot(c.snapshotBytes!)),
        if (c.cleanup > 0) _detail(l.waNodes, l.waCleanup(c.cleanup)),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (hasAddress)
              IconButton(
                tooltip: l.copy,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: endpoint)),
              ),
            if (hasAddress && c.phase == 'Running')
              TextButton(
                onPressed:
                    busy ||
                        !data.nodes.any(
                          (n) => n.name == c.node && n.online && n.enabled,
                        )
                    ? null
                    : () => widget.onConnect(
                        QuickConnectRequest(
                          QuickConnectKind.ssh,
                          address: address,
                          port: c.port,
                          username: c.kind == 'workspace' ? 'sandbox' : '',
                        ),
                      ),
                child: Text(l.connect),
              ),
            if (c.phase == 'Running' && c.kind == 'workspace')
              Tooltip(
                message: targets.isEmpty ? l.waNoTarget : l.waMigrate,
                child: OutlinedButton(
                  key: ValueKey('workspace_migrate_${c.name}'),
                  onPressed: busy || targets.isEmpty
                      ? null
                      : () =>
                            _edit((_) => _Migrate(cluster: c, nodes: targets)),
                  child: Text(l.waMigrate),
                ),
              ),
            if (c.canAbort)
              OutlinedButton(
                key: ValueKey('workspace_abort_${c.name}'),
                onPressed: busy
                    ? null
                    : () => _confirm(l.waAbort, '${c.name}\n${l.waAbortInfo}', {
                        'action': 'abort',
                        'cluster': c.name,
                        'expected_generation': c.generation,
                      }),
                child: Text(l.waAbort),
              ),
          ],
        ),
      ],
    );
  }
}

Widget _dialogBody(List<Widget> children) => SingleChildScrollView(
  child: SizedBox(
    width: 440,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(bottom: 10), child: child),
      ],
    ),
  ),
);
final _slug = RegExp(r'^[a-z][a-z0-9-]{0,39}$');
bool _keysValid(String raw) {
  final lines = raw.trim().split('\n');
  final key = RegExp(
    r'^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|sk-ssh-ed25519@openssh.com) +[a-zA-Z0-9+/=]{32,}( +[^\x00-\x1f\x7f]*)?$',
  );
  return utf8.encode(raw).length <= 16384 &&
      lines.length <= 32 &&
      lines.every((s) => key.hasMatch(s.trimRight()));
}

Widget _nodePicker(
  BuildContext ctx,
  List<WorkspaceAgentNode> nodes,
  String label,
  String selected,
  ValueChanged<String> changed,
) => DropdownButtonFormField<String>(
  initialValue: selected,
  isExpanded: true,
  decoration: InputDecoration(labelText: label),
  items: [
    for (final n in nodes)
      DropdownMenuItem(
        value: n.name,
        child: Text(
          '${n.name} · ${n.online ? ctx.l10n.waOnline : ctx.l10n.offline}',
        ),
      ),
  ],
  onChanged: (s) {
    if (s != null) changed(s);
  },
);

class _CreateCluster extends StatefulWidget {
  const _CreateCluster({required this.nodes, required this.host});
  final List<WorkspaceAgentNode> nodes;
  final bool host;
  @override
  State<_CreateCluster> createState() => _CreateClusterState();
}

class _CreateClusterState extends State<_CreateCluster> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController(),
      _port = TextEditingController(),
      _keys = TextEditingController();
  late String node = widget.nodes.first.name;
  @override
  void dispose() {
    _id.dispose();
    _port.dispose();
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return AlertDialog(
      title: Text(widget.host ? l.waPublish : l.waCreate),
      content: Form(
        key: _form,
        child: _dialogBody([
          _nodePicker(
            context,
            widget.nodes,
            l.waNode,
            node,
            (s) => setState(() => node = s),
          ),
          TextFormField(
            key: const ValueKey('workspace_id'),
            controller: _id,
            decoration: InputDecoration(
              labelText: l.name,
              helperText: l.waNameHint,
              helperMaxLines: 3,
            ),
            validator: (s) =>
                _slug.hasMatch(s?.trim() ?? '') ? null : l.waNameHint,
          ),
          TextFormField(
            key: const ValueKey('workspace_port'),
            controller: _port,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: l.port),
            validator: (s) {
              final n = int.tryParse(s ?? '');
              return n != null && n >= 1024 && n <= 65535 ? null : l.waPortHint;
            },
          ),
          if (!widget.host)
            TextFormField(
              key: const ValueKey('workspace_keys'),
              controller: _keys,
              minLines: 2,
              maxLines: 5,
              decoration: InputDecoration(labelText: l.waKeys),
              validator: (s) => _keysValid(s ?? '') ? null : l.waKeys,
            ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('workspace_confirm'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, <String, Object?>{
              'action': widget.host ? 'publish_host' : 'create_workspace',
              'cluster': _id.text.trim(),
              'node': node,
              'port': int.parse(_port.text.trim()),
              if (!widget.host) 'authorized_keys': _keys.text.trim(),
            });
          },
          child: Text(widget.host ? l.waPublish : l.create),
        ),
      ],
    );
  }
}

class _Migrate extends StatefulWidget {
  const _Migrate({required this.cluster, required this.nodes});
  final ManagedCluster cluster;
  final List<WorkspaceAgentNode> nodes;
  @override
  State<_Migrate> createState() => _MigrateState();
}

class _MigrateState extends State<_Migrate> {
  late String target = widget.nodes.first.name;
  @override
  Widget build(BuildContext context) {
    final l = context.l10n, c = widget.cluster;
    return AlertDialog(
      title: Text('${l.waMigrate} · ${c.name}'),
      content: _dialogBody([
        Text(l.waMigrationHelp),
        _nodePicker(
          context,
          widget.nodes,
          l.waTarget,
          target,
          (s) => setState(() => target = s),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('workspace_confirm'),
          onPressed: () => Navigator.pop(context, <String, Object?>{
            'action': 'migrate',
            'cluster': c.name,
            'destination': target,
            'expected_generation': c.generation,
          }),
          child: Text(l.waMigrate),
        ),
      ],
    );
  }
}

class _RegisterNode extends StatefulWidget {
  const _RegisterNode();
  @override
  State<_RegisterNode> createState() => _RegisterNodeState();
}

class _RegisterNodeState extends State<_RegisterNode> {
  static const limit = 32768;
  final _json = TextEditingController();
  Map<String, dynamic>? _public;
  bool _error = false;
  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _parse(String raw) {
    Map<String, dynamic>? descriptor;
    if (raw.length <= limit && utf8.encode(raw).length <= limit) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        const fields = {
          'node',
          'fingerprint',
          'image',
          'network',
          'host_ssh',
          'initial_workspace',
        };
        final image = m['image'] as String, network = m['network'] as String;
        final hash = RegExp(r'^[0-9a-f]{64}$');
        final initial = m['initial_workspace'] as Map<String, dynamic>?;
        if (m.keys.every(fields.contains) &&
            _slug.hasMatch(m['node'] as String) &&
            hash.hasMatch(m['fingerprint'] as String) &&
            (image.isEmpty ||
                (image.startsWith('sha256:') &&
                    hash.hasMatch(image.substring(7)))) &&
            m['host_ssh'] is bool &&
            (image.isNotEmpty || m['host_ssh'] == true) &&
            _slug.hasMatch(network) &&
            !{'host', 'bridge', 'default'}.contains(network) &&
            (initial == null ||
                (image.isNotEmpty &&
                    initial.keys.every(
                      {'cluster', 'port', 'authorized_keys'}.contains,
                    ) &&
                    _slug.hasMatch(initial['cluster'] as String) &&
                    initial['port'] is int &&
                    initial['port'] >= 1024 &&
                    initial['port'] <= 65535 &&
                    _keysValid(initial['authorized_keys'] as String)))) {
          descriptor = m;
        }
      } on Object {
        descriptor = null;
      }
    }
    setState(() {
      _public = descriptor;
      _error = raw.isNotEmpty && descriptor == null;
    });
  }

  Future<void> _pick() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: false,
        withReadStream: true,
      );
      if (!mounted || picked == null) return;
      final f = picked.files.single;
      if (f.size > limit) throw const FormatException();
      final b = BytesBuilder();
      if (f.readStream case final stream?) {
        await for (final part in stream) {
          if (b.length + part.length > limit) throw const FormatException();
          b.add(part);
        }
      } else if (f.bytes case final bytes?) {
        if (bytes.length > limit) throw const FormatException();
        b.add(bytes);
      } else {
        throw const FormatException();
      }
      final raw = utf8.decode(b.takeBytes());
      if (!mounted) return;
      _json.text = raw;
      _parse(raw);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _public = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n, m = _public;
    return AlertDialog(
      title: Text(l.waRegister),
      content: _dialogBody([
        Text(l.waDescriptorHelp),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            onPressed: _pick,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(l.waChooseFile),
          ),
        ),
        TextField(
          key: const ValueKey('workspace_descriptor'),
          controller: _json,
          onChanged: _parse,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: l.waDescriptor,
            errorText: _error ? l.waBadDescriptor : null,
            errorMaxLines: 2,
          ),
        ),
        if (m != null) ...[
          Text('${l.waNode} · ${m['node']}'),
          SelectableText('${l.waFingerprint} · ${m['fingerprint']}'),
          if (m['image'] != '') SelectableText('${l.waImage} · ${m['image']}'),
          Text('${l.waNetwork} · ${m['network']}'),
          if (m['host_ssh'] == true) Text(l.waHost),
          if (m['initial_workspace'] case final initial?)
            Text('${l.waInitial} · ${initial['cluster']} · ${initial['port']}'),
        ],
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('workspace_confirm'),
          onPressed: m == null
              ? null
              : () => Navigator.pop(context, <String, Object?>{
                  'action': 'register_node',
                  'registration': m,
                }),
          child: Text(l.waRegister),
        ),
      ],
    );
  }
}
