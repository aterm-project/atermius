// Team Vaults: a Vault attached to an organization and granted to its teams
// or members. This file holds the three entry points built on the existing
// cloud access service:
//   * "Put in Vault…" on a Host (copy or move it into another Vault),
//   * "New team Vault" (create + attach + desired grants, then key delivery),
//   * the team Vault list on an organization page.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart' show ApiException, VaultDescriptor;
import '../../app_controller.dart';
import '../../cloud/cloud_access_service.dart';
import '../../cloud/host_share_plan.dart';
import '../../domain/models.dart';
import '../../l10n/l10n.dart';
import '../app_theme.dart';
import '../credential_visibility/credential_visibility_widgets.dart';
import 'cloud_access_common.dart';
import 'share_host_dialog.dart' show VaultGrantsPanel;

/// "Team · Org / Name" for a team Vault, the plain name otherwise.
String teamVaultDisplayName(AppController app, String vaultId) {
  final name = app.vaultNameFor(vaultId);
  final org = app.vaultOrganization(vaultId);
  if (org == null) return name;
  return currentL10n.teamVaultNameWithOrg(org.name, name);
}

IconData teamVaultIcon(AppController app, String vaultId) =>
    app.vaultOrganization(vaultId) == null
    ? Icons.folder_outlined
    : Icons.groups_outlined;

String teamVaultErrorText(
  BuildContext context,
  AppController app,
  Object error,
) {
  final l10n = context.l10n;
  final code = error is CloudAccessException ? error.code : '';
  return switch (code) {
    'transfer_copied_not_removed' => l10n.teamVaultErrorCopiedNotRemoved,
    'transfer_target_read_only' ||
    'transfer_same_vault' => l10n.teamVaultErrorTargetReadOnly,
    'transfer_source_read_only' => l10n.teamVaultErrorSourceReadOnly,
    'transfer_move_blocked' => l10n.teamVaultErrorMoveBlocked,
    'sharing_vault_not_synced' => l10n.teamVaultErrorNotSynced,
    'organizations_unavailable' =>
      l10n.cloudAccessErrorOrganizationsUnavailable,
    _
        when error is ApiException &&
            error.code == 'VAULT_IN_OTHER_ORGANIZATION' =>
      l10n.teamVaultErrorOtherOrganization,
    _ =>
      error is CloudAccessException ||
              error is ApiException ||
              error is OperationScopeEndedException
          ? cloudAccessErrorText(context, error)
          : app.friendlyError(error),
  };
}

String _vaultRole(BuildContext context, String role) => switch (role) {
  'owner' => context.l10n.cloudAccessOrgRoleOwner,
  'viewer' => context.l10n.cloudAccessRoleViewer,
  _ => context.l10n.cloudAccessRoleEditor,
};

// ---------------------------------------------------------------------------
// Put Hosts in another Vault
// ---------------------------------------------------------------------------

/// Lets the user copy or move [hosts] of the selected Vault into another
/// Vault they can write (typically a team Vault). Returns true when the
/// transfer finished.
Future<bool> showPutHostsInVaultDialog(
  BuildContext context, {
  required AppController app,
  required List<HostRecord> hosts,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (context) => CloudDialogSurface(
      child: Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 680),
          child: _PutInVaultPanel(app: app, hosts: hosts),
        ),
      ),
    ),
  );
  return done == true;
}

class _PutInVaultPanel extends StatefulWidget {
  const _PutInVaultPanel({required this.app, required this.hosts});
  final AppController app;
  final List<HostRecord> hosts;

  @override
  State<_PutInVaultPanel> createState() => _PutInVaultPanelState();
}

class _PutInVaultPanelState extends State<_PutInVaultPanel> {
  AppController get _app => widget.app;
  late final CloudAccessService service = CloudAccessService(widget.app);
  late final HostSharePlan plan = service.planShare(widget.hosts);
  late final List<HostRecord> pinned = service.movePinnedBy(widget.hosts);
  late final String sourceName = widget.app.currentVaultName;
  late final bool sourceWritable = widget.app.activeVault?.canWrite == true;
  String? targetId;
  late bool move = sourceWritable && pinned.isEmpty;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final targets = service.transferTargets;
    // Prefer a team Vault: that is what this dialog is mostly used for.
    targetId =
        targets
            .where((v) => widget.app.vaultOrganization(v.id) != null)
            .firstOrNull
            ?.id ??
        targets.firstOrNull?.id;
    unawaited(widget.app.refreshVaultOrganizations());
  }

  Future<void> _createTeamVault() async {
    final id = await showCreateTeamVaultDialog(context, service: service);
    if (id != null && mounted) setState(() => targetId = id);
  }

  Future<void> _submit() async {
    final target = targetId;
    if (target == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await service.transferHostsToVault(plan, target, move: move);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      final text = context.l10n.teamVaultTransferDone(
        '${widget.hosts.length}',
        teamVaultDisplayName(widget.app, target),
      );
      Navigator.pop(context, true);
      messenger?.showSnackBar(SnackBar(content: Text(text)));
    } catch (e) {
      if (mounted) setState(() => error = teamVaultErrorText(context, _app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String _dependency(BuildContext context, HostShareDependency d) =>
      switch (d.kind) {
        HostShareDependencyKind.jumpHost =>
          context.l10n.cloudAccessDependencyJumpHost(d.label),
        HostShareDependencyKind.credential =>
          context.l10n.cloudAccessDependencyCredential(d.label),
        HostShareDependencyKind.knownHost =>
          context.l10n.cloudAccessDependencyKnownHost(d.label),
        HostShareDependencyKind.group => d.label,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final app = widget.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final targets = service.transferTargets;
        if (targetId != null && !targets.any((v) => v.id == targetId)) {
          targetId = targets.firstOrNull?.id;
        }
        final dependencies = plan.dependencies
            .where((d) => d.kind != HostShareDependencyKind.group)
            .toList();
        final canMove = sourceWritable && pinned.isEmpty;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.drive_file_move_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.hosts.length == 1
                          ? l10n.teamVaultPutTitle(widget.hosts.first.name)
                          : l10n.teamVaultPutTitleMany(
                              '${widget.hosts.length}',
                            ),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.cloudAccessClose,
                    onPressed: busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    CloudAccessSection(
                      title: l10n.teamVaultTarget,
                      trailing: service.organizationsAvailable
                          ? TextButton.icon(
                              key: const ValueKey('team-vault-new'),
                              onPressed: busy ? null : _createTeamVault,
                              icon: const Icon(Icons.add, size: 18),
                              label: Text(l10n.teamVaultNew),
                            )
                          : null,
                      children: [
                        if (targets.isEmpty)
                          Text(
                            l10n.teamVaultNoTargets,
                            style: TextStyle(
                              color: context.palette.muted,
                              fontSize: 12.5,
                            ),
                          ),
                        RadioGroup<String>(
                          groupValue: targetId,
                          onChanged: (value) {
                            if (!busy) setState(() => targetId = value);
                          },
                          child: Column(
                            children: [
                              for (final vault in targets)
                                RadioListTile<String>(
                                  key: ValueKey(
                                    'team-vault-target-${vault.id}',
                                  ),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: vault.id,
                                  secondary: Icon(
                                    teamVaultIcon(app, vault.id),
                                    size: 18,
                                  ),
                                  title: Text(app.vaultNameFor(vault.id)),
                                  subtitle: Text(
                                    app.vaultOrganization(vault.id) == null
                                        ? l10n.teamVaultPersonal
                                        : l10n.teamVaultTeamOf(
                                            app
                                                .vaultOrganization(vault.id)!
                                                .name,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (targets.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(
                            value: true,
                            enabled: canMove,
                            icon: const Icon(
                              Icons.drive_file_move_outlined,
                              size: 16,
                            ),
                            label: Text(l10n.teamVaultModeMove),
                          ),
                          ButtonSegment(
                            value: false,
                            icon: const Icon(Icons.copy_outlined, size: 16),
                            label: Text(l10n.teamVaultModeCopy),
                          ),
                        ],
                        selected: {move && canMove},
                        onSelectionChanged: busy
                            ? null
                            : (value) => setState(() => move = value.first),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        move && canMove
                            ? l10n.teamVaultModeMoveHelp(sourceName)
                            : l10n.teamVaultModeCopyHelp(sourceName),
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12.5,
                        ),
                      ),
                      if (pinned.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            l10n.teamVaultMovePinned(
                              pinned.map((h) => h.name).join(', '),
                            ),
                            style: TextStyle(
                              color: context.palette.orange,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      for (final blocker in plan.blockers)
                        Text(switch (blocker.kind) {
                          HostShareBlockerKind.missingJumpHost =>
                            l10n.cloudAccessBlockerMissingJump(
                              blocker.hostName,
                            ),
                          HostShareBlockerKind.missingCredential =>
                            l10n.cloudAccessBlockerMissingCredential(
                              blocker.hostName,
                            ),
                          HostShareBlockerKind.jumpLoop =>
                            l10n.cloudAccessBlockerJumpLoop(blocker.hostName),
                        }, style: TextStyle(color: context.palette.red)),
                      if (dependencies.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          l10n.teamVaultAlsoCopied,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        for (final d in dependencies)
                          Text('• ${_dependency(context, d)}'),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        l10n.teamVaultVisibleNotice,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      // credential-visibility: the target may be readable by
                      // an instance administrator.
                      CredentialVisibilitySharedVaultNotice(
                        app: app,
                        vaultId: targetId,
                      ),
                    ],
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          error!,
                          style: TextStyle(color: context.palette.red),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (busy) const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: busy ? null : () => Navigator.pop(context),
                    child: Text(l10n.cloudAccessCancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('team-vault-put-confirm'),
                    onPressed: busy || targetId == null || !plan.canProceed
                        ? null
                        : _submit,
                    child: Text(
                      move && canMove
                          ? l10n.teamVaultModeMove
                          : l10n.teamVaultModeCopy,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// New team Vault
// ---------------------------------------------------------------------------

/// Creates a team Vault and, once it exists, shows its access panel so the
/// owner can confirm member devices and deliver the key. Returns the new
/// Vault ID, or null when nothing was created.
Future<String?> showCreateTeamVaultDialog(
  BuildContext context, {
  required CloudAccessService service,
  String? orgId,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (context) => CloudDialogSurface(
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 700),
        child: _CreateTeamVaultPanel(service: service, orgId: orgId),
      ),
    ),
  ),
);

class _CreateTeamVaultPanel extends StatefulWidget {
  const _CreateTeamVaultPanel({required this.service, this.orgId});
  final CloudAccessService service;
  final String? orgId;

  @override
  State<_CreateTeamVaultPanel> createState() => _CreateTeamVaultPanelState();
}

class _CreateTeamVaultPanelState extends State<_CreateTeamVaultPanel> {
  final name = TextEditingController();
  List<Map<String, dynamic>>? managed;
  Map<String, dynamic>? org;
  String? orgId;

  /// Desired role per principal (`team:ID` or `user:ID`).
  final Map<String, String> roles = {};
  bool busy = false;
  String? error;
  String? createdId;

  CloudAccessService get service => widget.service;
  AppController get _app => widget.service.app;

  @override
  void initState() {
    super.initState();
    name.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = ((await service.api.orgs())['organizations'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((o) => o['role'] == 'owner' || o['role'] == 'admin')
          .toList();
      if (!mounted) return;
      setState(() {
        managed = list;
        orgId = list.any((o) => o['org_id'] == widget.orgId)
            ? widget.orgId
            : list.firstOrNull?['org_id'] as String?;
      });
      await _loadOrg();
    } catch (e) {
      if (mounted) {
        setState(() {
          managed = const [];
          error = teamVaultErrorText(context, _app, e);
        });
      }
    }
  }

  Future<void> _loadOrg() async {
    final id = orgId;
    if (id == null) return;
    try {
      final detail = await service.api.org(id);
      if (mounted && orgId == id) {
        setState(() {
          org = detail;
          roles.clear();
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = teamVaultErrorText(context, _app, e));
    }
  }

  Future<void> _create() async {
    final id = orgId;
    if (id == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final vaultId = await service.createTeamVault(
        name: name.text,
        orgId: id,
        grants: [
          for (final entry in roles.entries)
            (
              type: entry.key.split(':').first,
              id: entry.key.substring(entry.key.indexOf(':') + 1),
              role: entry.value,
            ),
        ],
      );
      if (mounted) setState(() => createdId = vaultId);
    } catch (e) {
      if (mounted) setState(() => error = teamVaultErrorText(context, _app, e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _principal(String key, IconData icon, String label) {
    final role = roles[key];
    return ListTile(
      key: ValueKey('team-vault-grant-$key'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, size: 18),
      title: Text(label),
      trailing: DropdownButton<String>(
        value: role ?? '',
        underline: const SizedBox.shrink(),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text(context.l10n.teamVaultNoAccess),
          ),
          DropdownMenuItem(
            value: 'viewer',
            child: Text(context.l10n.cloudAccessRoleViewer),
          ),
          DropdownMenuItem(
            value: 'editor',
            child: Text(context.l10n.cloudAccessRoleEditor),
          ),
        ],
        onChanged: busy
            ? null
            : (value) => setState(() {
                if (value == null || value.isEmpty) {
                  roles.remove(key);
                } else {
                  roles[key] = value;
                }
              }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final created = createdId;
    final orgs = managed;
    final myId = service.app.account?.accountId;
    final teams = (org?['teams'] as List? ?? const []).cast<Map>();
    final members = (org?['members'] as List? ?? const [])
        .cast<Map>()
        .where((m) => m['user_id'] != myId)
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.groups_outlined, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  created == null
                      ? l10n.teamVaultNewTitle
                      : l10n.teamVaultAccessTitle(
                          service.app.vaultNameFor(created),
                        ),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Flexible(
            child: created != null
                ? ListView(
                    shrinkWrap: true,
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        l10n.teamVaultCreatedHelp,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      VaultGrantsPanel(service: service, vaultId: created),
                    ],
                  )
                : orgs == null
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: LinearProgressIndicator(),
                  )
                : ListView(
                    shrinkWrap: true,
                    children: [
                      const SizedBox(height: 8),
                      Text(
                        l10n.teamVaultNewHelp,
                        style: TextStyle(
                          color: context.palette.muted,
                          fontSize: 12.5,
                        ),
                      ),
                      if (orgs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(l10n.teamVaultNoManagedOrg),
                        )
                      else ...[
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('team-vault-name'),
                          controller: name,
                          autofocus: true,
                          enabled: !busy,
                          decoration: InputDecoration(
                            labelText: l10n.teamVaultName,
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          key: const ValueKey('team-vault-org'),
                          initialValue: orgId,
                          decoration: InputDecoration(
                            labelText: l10n.teamVaultOrganization,
                          ),
                          items: [
                            for (final o in orgs)
                              DropdownMenuItem(
                                value: o['org_id'] as String,
                                child: Text('${o['name']}'),
                              ),
                          ],
                          onChanged: busy
                              ? null
                              : (value) {
                                  setState(() {
                                    orgId = value;
                                    org = null;
                                  });
                                  unawaited(_loadOrg());
                                },
                        ),
                        CloudAccessSection(
                          title: l10n.teamVaultAccessHeading,
                          children: [
                            Text(
                              l10n.teamVaultAccessHelp,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                            if (org == null)
                              const LinearProgressIndicator()
                            else ...[
                              for (final team in teams)
                                _principal(
                                  'team:${team['team_id']}',
                                  Icons.groups_outlined,
                                  l10n.cloudAccessTeamLabel('${team['name']}'),
                                ),
                              for (final member in members)
                                _principal(
                                  'user:${member['user_id']}',
                                  Icons.person_outline,
                                  '${member['username']}',
                                ),
                              if (teams.isEmpty && members.isEmpty)
                                Text(
                                  l10n.teamVaultNobodyYet,
                                  style: TextStyle(
                                    color: context.palette.muted,
                                    fontSize: 12.5,
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ],
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            error!,
                            style: TextStyle(color: context.palette.red),
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 10),
          if (busy) const LinearProgressIndicator(),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (created == null) ...[
                TextButton(
                  onPressed: busy ? null : () => Navigator.pop(context),
                  child: Text(l10n.cloudAccessCancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('team-vault-create'),
                  onPressed:
                      busy ||
                          orgId == null ||
                          org == null ||
                          name.text.trim().isEmpty
                      ? null
                      : _create,
                  child: Text(l10n.teamVaultCreate),
                ),
              ] else
                FilledButton(
                  key: const ValueKey('team-vault-created-done'),
                  onPressed: () => Navigator.pop(context, created),
                  child: Text(l10n.cloudAccessDone),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Access (grants and key delivery) of one Vault in a dialog.
Future<void> showVaultAccessDialog(
  BuildContext context, {
  required CloudAccessService service,
  required String vaultId,
}) => showDialog<void>(
  context: context,
  builder: (context) => CloudDialogSurface(
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 700),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.groups_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      context.l10n.teamVaultAccessTitle(
                        service.app.vaultNameFor(vaultId),
                      ),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: context.l10n.cloudAccessClose,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    CredentialVisibilitySharedVaultNotice(
                      app: service.app,
                      vaultId: vaultId,
                    ),
                    VaultGrantsPanel(service: service, vaultId: vaultId),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

// ---------------------------------------------------------------------------
// Organization page section
// ---------------------------------------------------------------------------

/// The team Vaults of one organization that this account is a member of,
/// with Open / Access and (for organization managers) New team Vault.
class OrganizationTeamVaultsSection extends StatelessWidget {
  const OrganizationTeamVaultsSection({
    required this.service,
    required this.orgId,
    required this.manager,
    this.onOpened,
    super.key,
  });
  final CloudAccessService service;
  final String orgId;
  final bool manager;

  /// Called after a Vault was opened from this list (e.g. to close the page).
  final VoidCallback? onOpened;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final app = service.app;
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        final vaults = <VaultDescriptor>[
          for (final vault in app.vaults)
            if (app.vaultOrganization(vault.id)?.id == orgId) vault,
        ];
        return CloudAccessSection(
          title: l10n.teamVaultsHeading,
          trailing: manager
              ? TextButton.icon(
                  key: const ValueKey('org-team-vault-new'),
                  onPressed: () => showCreateTeamVaultDialog(
                    context,
                    service: service,
                    orgId: orgId,
                  ),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(l10n.teamVaultNew),
                )
              : null,
          children: [
            if (vaults.isEmpty)
              Text(
                manager ? l10n.teamVaultsEmptyManager : l10n.teamVaultsEmpty,
                style: TextStyle(color: context.palette.muted, fontSize: 12.5),
              ),
            for (final vault in vaults)
              ListTile(
                key: ValueKey('org-team-vault-${vault.id}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.groups_outlined, size: 18),
                title: Text(app.vaultNameFor(vault.id)),
                subtitle: Text(
                  vault.id == app.currentVaultId
                      ? '${_vaultRole(context, vault.role)} · ${l10n.teamVaultCurrent}'
                      : _vaultRole(context, vault.role),
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    if (vault.role == 'owner')
                      TextButton(
                        onPressed: () => showVaultAccessDialog(
                          context,
                          service: service,
                          vaultId: vault.id,
                        ),
                        child: Text(l10n.teamVaultAccess),
                      ),
                    if (vault.id != app.currentVaultId)
                      TextButton(
                        onPressed: () async {
                          await app.selectVault(vault.id);
                          onOpened?.call();
                        },
                        child: Text(l10n.teamVaultOpen),
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
