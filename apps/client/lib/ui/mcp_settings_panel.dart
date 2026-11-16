import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../l10n/l10n.dart';
import '../mcp/mcp_listener_lifecycle.dart';
import '../mcp/mcp_service.dart';
import '../mcp/mcp_tools.dart';
import 'app_theme.dart';
import 'apple_hig.dart';
import 'ios_native/ios_native.dart';
import 'responsive_layout.dart';
import 'settings_scaffold.dart';

/// Localized name of an MCP access level, shared by every MCP surface.
String mcpAccessModeLabel(AppLocalizations l10n, McpAccessMode mode) =>
    switch (mode) {
      McpAccessMode.denied => l10n.mcpAccessModeDenied,
      McpAccessMode.readOnly => l10n.mcpAccessModeReadOnly,
      McpAccessMode.readWrite => l10n.mcpAccessModeReadWrite,
    };

String mcpAccessModeDescription(AppLocalizations l10n, McpAccessMode mode) =>
    switch (mode) {
      McpAccessMode.denied => l10n.mcpAccessModeDeniedDescription,
      McpAccessMode.readOnly => l10n.mcpAccessModeReadOnlyDescription,
      McpAccessMode.readWrite => l10n.mcpAccessModeReadWriteDescription,
    };

IconData mcpAccessModeIcon(McpAccessMode mode) => switch (mode) {
  McpAccessMode.denied => Icons.block_outlined,
  McpAccessMode.readOnly => Icons.visibility_outlined,
  McpAccessMode.readWrite => Icons.edit_outlined,
};

IconData _iosMcpAccessModeIcon(McpAccessMode mode) => switch (mode) {
  McpAccessMode.denied => Icons.block_rounded,
  McpAccessMode.readOnly => Icons.visibility_rounded,
  McpAccessMode.readWrite => Icons.edit_rounded,
};

/// The per-machine choice: inherit the default, or one explicit level.
enum _HostChoice {
  inherit(null),
  denied(McpAccessMode.denied),
  readOnly(McpAccessMode.readOnly),
  readWrite(McpAccessMode.readWrite);

  const _HostChoice(this.mode);
  final McpAccessMode? mode;

  static _HostChoice of(McpAccessMode? mode) =>
      values.firstWhere((choice) => choice.mode == mode);
}

/// Settings › AI / MCP. The same panel is used by the Windows, Linux, macOS
/// and Android clients; only the arrangement adapts to the available width.
class McpSettingsPanel extends StatefulWidget {
  const McpSettingsPanel({this.service, super.key});
  final McpService? service;

  /// Machines rendered before "Show more"; keeps huge inventories responsive.
  static const machinePageSize = 50;

  @override
  State<McpSettingsPanel> createState() => _McpSettingsPanelState();
}

class _McpSettingsPanelState extends State<McpSettingsPanel> {
  final _port = TextEditingController(text: '8765');
  final _query = TextEditingController();
  McpService get service => widget.service ?? McpService.instance;
  String? _error;
  String? _accessError;
  bool _copied = false;
  bool _defaultPending = false;
  final _pendingHosts = <String>{};

  /// Bumped when a save fails so every choice field is rebuilt from the
  /// value the policy actually holds instead of the rejected selection.
  int _resetEpoch = 0;
  int _visibleMachines = McpSettingsPanel.machinePageSize;

  @override
  void initState() {
    super.initState();
    service.addListener(_syncListeningPort);
    _syncListeningPort();
  }

  void _syncListeningPort() {
    final endpoint = service.endpoint;
    if (endpoint != null && _port.text != '${endpoint.port}') {
      _port.text = '${endpoint.port}';
    }
  }

  @override
  void didUpdateWidget(McpSettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.service ?? McpService.instance;
    if (!identical(previous, service)) {
      previous.removeListener(_syncListeningPort);
      service.addListener(_syncListeningPort);
      _syncListeningPort();
    }
  }

  @override
  void dispose() {
    service.removeListener(_syncListeningPort);
    _port.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = context.l10n.portMustBe102465535);
      return;
    }
    setState(() {
      _error = null;
      _copied = false;
    });
    try {
      await service.start(port: port);
    } catch (_) {
      if (mounted) {
        setState(() => _error = context.l10n.couldntStartMcpMakeSureThe);
      }
    }
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(
        ClipboardData(text: service.connectionConfiguration()),
      );
      if (mounted) setState(() => _copied = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = context.l10n.couldntCopyTheConfigurationCheckClipboard,
        );
      }
    }
  }

  Future<bool> _confirmReadWriteDefault() async {
    final l10n = context.l10n;
    if (isIosPhone(context)) {
      final confirmed = await showCupertinoDialog<bool>(
        context: context,
        builder: (dialogContext) => CupertinoAlertDialog(
          key: const ValueKey('mcp_confirm_read_write_default'),
          title: Text(l10n.mcpConfirmReadWriteDefaultTitle),
          content: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(l10n.mcpConfirmReadWriteDefaultBody),
          ),
          actions: [
            CupertinoDialogAction(
              key: const ValueKey('mcp_confirm_read_write_cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancel),
            ),
            CupertinoDialogAction(
              key: const ValueKey('mcp_confirm_read_write_accept'),
              isDestructiveAction: true,
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.mcpConfirmReadWriteDefaultConfirm),
            ),
          ],
        ),
      );
      return confirmed == true;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('mcp_confirm_read_write_default'),
        title: Text(l10n.mcpConfirmReadWriteDefaultTitle),
        content: Text(l10n.mcpConfirmReadWriteDefaultBody),
        actions: [
          TextButton(
            key: const ValueKey('mcp_confirm_read_write_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('mcp_confirm_read_write_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.mcpConfirmReadWriteDefaultConfirm),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _setDefault(McpAccessMode mode) async {
    if (_defaultPending || mode == service.defaultAccess) return;
    // Widening every machine (including future ones) to read & write is the
    // one choice that deserves an explicit confirmation.
    if (mode == McpAccessMode.readWrite && !await _confirmReadWriteDefault()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _defaultPending = true;
      _accessError = null;
    });
    try {
      await service.setDefaultAccess(mode);
    } catch (_) {
      if (mounted) {
        setState(() => _accessError = context.l10n.mcpAccessSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _defaultPending = false);
    }
  }

  Future<void> _setHost(String hostId, McpAccessMode? mode) async {
    if (_pendingHosts.contains(hostId)) return;
    if (service.accessOverrideForHost(hostId) == mode) return;
    setState(() {
      _pendingHosts.add(hostId);
      _accessError = null;
    });
    try {
      await service.setHostAccess(hostId, mode);
    } catch (_) {
      if (mounted) {
        setState(() {
          _accessError = context.l10n.mcpAccessSaveFailed;
          _resetEpoch++;
        });
      }
    } finally {
      if (mounted) setState(() => _pendingHosts.remove(hostId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final lifecycle = McpListenerLifecycle.installed;
    return ListenableBuilder(
      listenable: Listenable.merge([service, ?lifecycle]),
      builder: (context, _) {
        if (isIosPhone(context)) {
          return SettingsCards(
            children: [
              _iosServiceCard(context),
              if (service.supported) _iosMachineAccessCard(context),
              _iosToolsCard(context),
              _iosAuditCard(context),
            ],
          );
        }
        return SettingsCards(
          children: [
            _serviceCard(context),
            if (service.supported) _machineAccessCard(context),
            _toolsCard(context),
            _auditCard(context),
          ],
        );
      },
    );
  }

  Widget _iosServiceCard(BuildContext context) {
    final l10n = context.l10n;
    final colors = IosColors.of(context);
    final hairline = IosMetrics.hairline(context);
    final ready = service.permissionsReady && !service.permissionsLoading;
    final defaultMode = ready ? service.defaultAccess : McpAccessMode.denied;
    final endpoint = service.endpoint;
    final canToggle =
        !service.starting && (service.running || service.workspaceReady);

    Widget separator([double start = IosMetrics.rowPaddingH]) => Padding(
      padding: EdgeInsetsDirectional.only(start: start),
      child: SizedBox(height: hairline, child: ColoredBox(color: colors.separator)),
    );

    if (!service.supported) {
      return SettingsCard(
        semanticContainer: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IosIconTile(
                  icon: Icons.hub_rounded,
                  color: colors.purple,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.externalAiAccess,
                    style: IosType.headline.copyWith(color: colors.label),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.letExternalAiUseTheHosts,
              style: IosType.footnote.copyWith(color: colors.secondaryLabel),
            ),
            const SizedBox(height: 10),
            Text(
              l10n.theBrowserAndMobileAppsDont,
              key: const ValueKey('mcp_platform_unavailable'),
              style: IosType.subheadline.copyWith(color: colors.secondaryLabel),
            ),
          ],
        ),
      );
    }

    return SettingsCard(
      semanticContainer: false,
      iosPadding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IosListRow(
            leading: IosIconTile(
              icon: Icons.hub_rounded,
              color: colors.purple,
              size: 28,
            ),
            title: Text(l10n.externalAiAccess),
            subtitle: Text(
              service.starting
                  ? l10n.starting
                  : service.running
                  ? l10n.mcpRunningDefaultAccess(
                      mcpAccessModeLabel(l10n, defaultMode),
                    )
                  : l10n.off,
              key: const ValueKey('mcp_status'),
              style: IosType.footnote.copyWith(
                color: service.running ? colors.online : colors.secondaryLabel,
              ),
            ),
            minHeight: 56,
            trailing: CupertinoSwitch(
              key: const ValueKey('mcp_toggle'),
              value: service.running,
              activeTrackColor: colors.tint,
              onChanged: !canToggle
                  ? null
                  : (next) {
                      if (next) {
                        _start();
                      } else {
                        service.stop();
                      }
                    },
            ),
          ),
          separator(),
          IosTextFieldRow(
            fieldKey: const ValueKey('mcp_port'),
            label: l10n.localListeningPort,
            labelWidth: 132,
            controller: _port,
            enabled: !service.running && !service.starting,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textInputAction: TextInputAction.done,
          ),
          if (endpoint != null) ...[
            separator(),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IosMetrics.rowPaddingH,
                vertical: 10,
              ),
              child: SelectableText(
                endpoint.toString(),
                key: const ValueKey('mcp_endpoint'),
                style: IosType.mono.copyWith(color: colors.label),
              ),
            ),
          ],
          if (service.running) ...[
            separator(),
            IosListActionRow(
              key: const ValueKey('mcp_copy_configuration'),
              label: _copied
                  ? l10n.copiedIncludesAccessToken
                  : l10n.copyConnectionConfigIncludesToken,
              icon: IosIcons.copy,
              onTap: _copy,
            ),
          ],
          separator(0),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              10,
              IosMetrics.rowPaddingH,
              12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.letExternalAiUseTheHosts,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.readOnlyModeCanStillRead,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.listensOn127001,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    key: const ValueKey('mcp_error'),
                    style: IosType.footnote.copyWith(color: colors.destructive),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iosMachineAccessCard(BuildContext context) {
    final l10n = context.l10n;
    final colors = IosColors.of(context);
    final hairline = IosMetrics.hairline(context);
    final loading = service.permissionsLoading;
    final ready = service.permissionsReady && !loading;
    final defaultMode = service.defaultAccess;
    final hosts = ready ? service.permissionHosts : const <HostRecord>[];
    final localDevice = ready && service.localDeviceAccessApplicable;
    final customized =
        (localDevice &&
                service.accessOverrideForHost(mcpLocalDeviceHostId) != null
            ? 1
            : 0) +
        hosts.where((h) => service.accessOverrideForHost(h.id) != null).length;
    final query = _query.text.trim().toLowerCase();
    final matching = query.isEmpty
        ? hosts
        : hosts
              .where(
                (h) =>
                    h.name.toLowerCase().contains(query) ||
                    h.address.toLowerCase().contains(query) ||
                    h.username.toLowerCase().contains(query),
              )
              .toList();
    final shown = matching.take(_visibleMachines).toList();
    final hidden = matching.length - shown.length;

    Widget separator([double start = IosMetrics.rowPaddingH]) => Padding(
      padding: EdgeInsetsDirectional.only(start: start),
      child: SizedBox(height: hairline, child: ColoredBox(color: colors.separator)),
    );

    return SettingsCard(
      key: const ValueKey('mcp_machine_access'),
      semanticContainer: false,
      iosPadding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              14,
              IosMetrics.rowPaddingH,
              10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.mcpMachineAccessTitle,
                  style: IosType.headline.copyWith(color: colors.label),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.mcpMachineAccessDescription,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
                if (loading)
                  Padding(
                    key: const ValueKey('mcp_access_loading'),
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      children: [
                        const CupertinoActivityIndicator(radius: 8),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.mcpAccessLoading,
                            style: IosType.footnote.copyWith(
                              color: colors.secondaryLabel,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (!ready)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _Notice(
                      key: const ValueKey('mcp_access_unavailable'),
                      icon: Icons.lock_rounded,
                      color: colors.warning,
                      text: l10n.mcpAccessUnavailable,
                    ),
                  ),
                if (_accessError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _Notice(
                      key: const ValueKey('mcp_access_error'),
                      icon: IosIcons.warning,
                      color: colors.destructive,
                      text: _accessError!,
                    ),
                  ),
                const SizedBox(height: 12),
                Text(
                  l10n.mcpDefaultAccessTitle,
                  style: IosType.subheadline.copyWith(
                    color: colors.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.mcpDefaultAccessDescription,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
              ],
            ),
          ),
          separator(0),
          for (var i = 0; i < McpAccessMode.values.length; i++) ...[
            if (i > 0) separator(),
            Builder(
              builder: (context) {
                final mode = McpAccessMode.values[i];
                final selected = ready && mode == defaultMode;
                final enabled = ready && !_defaultPending;
                return Semantics(
                  inMutuallyExclusiveGroup: true,
                  checked: selected,
                  child: IosListRow(
                    key: ValueKey('mcp_default_access_${mode.name}'),
                    enabled: enabled,
                    leading: Icon(
                      _iosMcpAccessModeIcon(mode),
                      size: 20,
                      color: selected ? colors.tint : colors.secondaryLabel,
                    ),
                    title: Text(mcpAccessModeLabel(l10n, mode)),
                    subtitle: Text(mcpAccessModeDescription(l10n, mode)),
                    minHeight: 56,
                    accessory: selected
                        ? IosRowAccessory.checkmark
                        : IosRowAccessory.none,
                    onTap: enabled
                        ? () {
                            AppleHaptics.selection(context);
                            _setDefault(mode);
                          }
                        : null,
                  ),
                );
              },
            ),
          ],
          if (ready) ...[
            separator(0),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                IosMetrics.rowPaddingH,
                14,
                IosMetrics.rowPaddingH,
                8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.mcpPerMachineTitle,
                    style: IosType.subheadline.copyWith(
                      color: colors.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.mcpCustomizedCount(customized),
                    key: const ValueKey('mcp_customized_count'),
                    style: IosType.footnote.copyWith(
                      color: colors.secondaryLabel,
                    ),
                  ),
                  if (hosts.length > 6) ...[
                    const SizedBox(height: 10),
                    IosSearchField(
                      fieldKey: const ValueKey('mcp_machine_search'),
                      controller: _query,
                      placeholder: l10n.mcpSearchMachines,
                      onChanged: (_) => setState(
                        () =>
                            _visibleMachines = McpSettingsPanel.machinePageSize,
                      ),
                      onSuffixTap: () => setState(
                        () =>
                            _visibleMachines = McpSettingsPanel.machinePageSize,
                      ),
                    ),
                  ],
                  if (hosts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l10n.mcpNoSavedMachines,
                        style: IosType.footnote.copyWith(
                          color: colors.secondaryLabel,
                        ),
                      ),
                    )
                  else if (matching.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        l10n.mcpNoMachinesMatch(_query.text.trim()),
                        key: const ValueKey('mcp_machine_no_match'),
                        style: IosType.footnote.copyWith(
                          color: colors.secondaryLabel,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (localDevice) ...[
              separator(0),
              _iosMachineRow(
                context,
                id: mcpLocalDeviceHostId,
                name: l10n.mcpLocalDeviceName,
                detail: l10n.mcpLocalDeviceDetail,
                icon: Icons.phone_iphone_rounded,
              ),
            ],
            for (var i = 0; i < shown.length; i++) ...[
              separator(i == 0 && !localDevice ? 0 : IosMetrics.rowPaddingH),
              _iosMachineRow(
                context,
                id: shown[i].id,
                name: shown[i].name.isEmpty ? shown[i].address : shown[i].name,
                detail: _hostDetail(shown[i]),
                icon: Icons.dns_rounded,
              ),
            ],
            if (hidden > 0) ...[
              separator(),
              IosListActionRow(
                key: const ValueKey('mcp_machine_show_more'),
                label: l10n.mcpShowMoreMachines(hidden),
                icon: Icons.expand_more_rounded,
                onTap: () => setState(
                  () => _visibleMachines += McpSettingsPanel.machinePageSize,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _iosMachineRow(
    BuildContext context, {
    required String id,
    required String name,
    required String detail,
    required IconData icon,
  }) {
    final l10n = context.l10n;
    final colors = IosColors.of(context);
    final override = service.accessOverrideForHost(id);
    final pending = _pendingHosts.contains(id);
    final defaultLabel = mcpAccessModeLabel(l10n, service.defaultAccess);
    String choiceLabel(_HostChoice choice) => choice.mode == null
        ? l10n.mcpHostUseDefault(defaultLabel)
        : mcpAccessModeLabel(l10n, choice.mode!);

    return Padding(
      key: ValueKey('mcp_host_row_$id'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              10,
              IosMetrics.rowPaddingH,
              0,
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: colors.secondaryLabel),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IosType.body.copyWith(
                      color: colors.label,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (override != null) ...[
                  const SizedBox(width: 6),
                  _Tag(
                    key: ValueKey('mcp_host_custom_$id'),
                    text: l10n.mcpHostCustom,
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              IosMetrics.rowPaddingH + 26,
              2,
              IosMetrics.rowPaddingH,
              0,
            ),
            child: Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: IosType.mono.copyWith(
                fontSize: 12,
                color: colors.secondaryLabel,
              ),
            ),
          ),
          KeyedSubtree(
            key: ValueKey('mcp_host_choice_${id}_${override?.name}_$_resetEpoch'),
            child: Semantics(
              label: l10n.mcpHostAccessFor(name),
              child: IosPickerRow<_HostChoice>(
                rowKey: ValueKey('mcp_host_access_$id'),
                label: l10n.mcpMachineAccessTitle,
                enabled: !pending,
                value: _HostChoice.of(override),
                options: [
                  for (final choice in _HostChoice.values)
                    IosPickerOption(
                      value: choice,
                      label: choiceLabel(choice),
                      icon: choice.mode == null
                          ? null
                          : _iosMcpAccessModeIcon(choice.mode!),
                    ),
                ],
                onChanged: pending
                    ? null
                    : (choice) => _setHost(id, choice.mode),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _iosToolsCard(BuildContext context) {
    final colors = IosColors.of(context);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.l10n.availableTools,
            style: IosType.headline.copyWith(color: colors.label),
          ),
          const SizedBox(height: 6),
          Text(
            context.l10n.sshConsoleSupportReadingTextAnd,
            style: IosType.footnote.copyWith(color: colors.secondaryLabel),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tool in mcpTools)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.fill,
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    child: Text(
                      tool.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: IosType.mono.copyWith(
                        fontSize: 11.5,
                        color: colors.label,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iosAuditCard(BuildContext context) {
    final colors = IosColors.of(context);
    final hairline = IosMetrics.hairline(context);
    final entries = service.audit.take(10).toList(growable: false);
    return SettingsCard(
      iosPadding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              14,
              IosMetrics.rowPaddingH,
              10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.l10n.recentCalls,
                  style: IosType.headline.copyWith(color: colors.label),
                ),
                const SizedBox(height: 4),
                Text(
                  context.l10n.onlyTheLast50ToolNames,
                  style: IosType.footnote.copyWith(color: colors.secondaryLabel),
                ),
                if (entries.isEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    context.l10n.noCallsYet,
                    style: IosType.subheadline.copyWith(
                      color: colors.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (var i = 0; i < entries.length; i++) ...[
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: i == 0 ? 0 : IosMetrics.rowPaddingH,
              ),
              child: SizedBox(
                height: hairline,
                child: ColoredBox(color: colors.separator),
              ),
            ),
            IosListRow(
              leading: Icon(
                entries[i].success ? IosIcons.success : IosIcons.warning,
                size: 20,
                color: entries[i].success ? colors.online : colors.warning,
              ),
              title: Text(entries[i].tool),
              subtitle: Text(
                entries[i].at.toLocal().toString().split('.').first,
              ),
              monoSubtitle: true,
              value: entries[i].success
                  ? context.l10n.done
                  : context.l10n.failed,
            ),
          ],
        ],
      ),
    );
  }

  Widget _serviceCard(BuildContext context) {
    final l10n = context.l10n;
    final ready = service.permissionsReady && !service.permissionsLoading;
    final defaultMode = ready ? service.defaultAccess : McpAccessMode.denied;
    final endpoint = service.endpoint;
    return SettingsCard(
      // Holds fields and buttons: keep each control its own a11y node.
      semanticContainer: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.externalAiAccess,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.letExternalAiUseTheHosts,
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          const SizedBox(height: 12),
          if (!service.supported)
            Text(
              l10n.theBrowserAndMobileAppsDont,
              key: const ValueKey('mcp_platform_unavailable'),
            )
          else ...[
            Text(
              service.running
                  ? l10n.mcpRunningDefaultAccess(
                      mcpAccessModeLabel(l10n, defaultMode),
                    )
                  : l10n.off,
              key: const ValueKey('mcp_status'),
              style: TextStyle(
                color: service.running
                    ? context.palette.lime
                    : context.palette.muted,
              ),
            ),
            if (McpListenerLifecycle.installed case final lifecycle?
                when service.running && identical(service, McpService.instance))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  switch (lifecycle.mode) {
                    McpBackgroundMode.protected => l10n.mcpAndroidProtected,
                    McpBackgroundMode.foregroundOnly =>
                      l10n.mcpAndroidForegroundOnly,
                    _ => l10n.mcpAndroidStarting,
                  },
                  key: const ValueKey('mcp_android_lifecycle_status'),
                  style: TextStyle(color: context.palette.muted),
                ),
              ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('mcp_port'),
              controller: _port,
              enabled: !service.running && !service.starting,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(labelText: l10n.localListeningPort),
            ),
            const SizedBox(height: 12),
            Text(
              l10n.readOnlyModeCanStillRead,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  key: const ValueKey('mcp_toggle'),
                  onPressed:
                      service.starting ||
                          (!service.running && !service.workspaceReady)
                      ? null
                      : service.running
                      ? () => service.stop()
                      : _start,
                  icon: Icon(
                    service.running
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                  label: Text(
                    service.starting
                        ? l10n.starting
                        : service.running
                        ? l10n.stopAndRevokeToken
                        : l10n.enableMcp,
                  ),
                ),
                if (service.running)
                  OutlinedButton.icon(
                    key: const ValueKey('mcp_copy_configuration'),
                    onPressed: _copy,
                    icon: const Icon(Icons.copy),
                    label: Text(
                      _copied
                          ? l10n.copiedIncludesAccessToken
                          : l10n.copyConnectionConfigIncludesToken,
                    ),
                  ),
              ],
            ),
            if (endpoint != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: SelectableText(
                  endpoint.toString(),
                  key: const ValueKey('mcp_endpoint'),
                ),
              ),
              if (Theme.of(context).platform == TargetPlatform.android)
                _AndroidForwardingHint(port: endpoint.port),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.listensOn127001,
              style: TextStyle(
                color: context.palette.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            if (Theme.of(context).platform == TargetPlatform.android) ...[
              const SizedBox(height: 8),
              Text(
                l10n.mcpAndroidBackgroundHint,
                key: const ValueKey('mcp_android_background_hint'),
                style: TextStyle(
                  color: context.palette.muted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                key: const ValueKey('mcp_error'),
                style: TextStyle(color: context.palette.red),
              ),
            ),
        ],
      ),
    );
  }

  Widget _machineAccessCard(BuildContext context) {
    final l10n = context.l10n;
    final loading = service.permissionsLoading;
    final ready = service.permissionsReady && !loading;
    final defaultMode = service.defaultAccess;
    final hosts = ready ? service.permissionHosts : const <HostRecord>[];
    // Only offered where hostless local console sessions can exist.
    final localDevice = ready && service.localDeviceAccessApplicable;
    final customized =
        (localDevice &&
                service.accessOverrideForHost(mcpLocalDeviceHostId) != null
            ? 1
            : 0) +
        hosts.where((h) => service.accessOverrideForHost(h.id) != null).length;
    final query = _query.text.trim().toLowerCase();
    final matching = query.isEmpty
        ? hosts
        : hosts
              .where(
                (h) =>
                    h.name.toLowerCase().contains(query) ||
                    h.address.toLowerCase().contains(query) ||
                    h.username.toLowerCase().contains(query),
              )
              .toList();
    final shown = matching.take(_visibleMachines).toList();
    final hidden = matching.length - shown.length;
    final muted = TextStyle(
      color: context.palette.muted,
      fontSize: 12,
      height: 1.5,
    );

    return SettingsCard(
      key: const ValueKey('mcp_machine_access'),
      // Holds fields and buttons: keep each control its own a11y node.
      semanticContainer: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.mcpMachineAccessTitle,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.mcpMachineAccessDescription,
            style: TextStyle(color: context.palette.muted, height: 1.5),
          ),
          if (loading)
            Padding(
              key: const ValueKey('mcp_access_loading'),
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(l10n.mcpAccessLoading)),
                ],
              ),
            )
          else if (!ready)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Notice(
                key: const ValueKey('mcp_access_unavailable'),
                icon: Icons.lock_outline,
                color: context.palette.orange,
                text: l10n.mcpAccessUnavailable,
              ),
            ),
          if (_accessError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _Notice(
                key: const ValueKey('mcp_access_error'),
                icon: Icons.error_outline,
                color: context.palette.red,
                text: _accessError!,
              ),
            ),
          const SizedBox(height: 16),
          Text(
            l10n.mcpDefaultAccessTitle,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(l10n.mcpDefaultAccessDescription, style: muted),
          const SizedBox(height: 4),
          RadioGroup<McpAccessMode>(
            groupValue: ready ? defaultMode : null,
            onChanged: (mode) {
              if (mode != null && ready && !_defaultPending) _setDefault(mode);
            },
            child: Column(
              children: [
                for (final mode in McpAccessMode.values)
                  RadioListTile<McpAccessMode>(
                    key: ValueKey('mcp_default_access_${mode.name}'),
                    value: mode,
                    enabled: ready && !_defaultPending,
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(mcpAccessModeIcon(mode)),
                    title: Text(mcpAccessModeLabel(l10n, mode)),
                    subtitle: Text(
                      mcpAccessModeDescription(l10n, mode),
                      style: muted,
                    ),
                  ),
              ],
            ),
          ),
          if (ready) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: context.palette.line),
            const SizedBox(height: 16),
            Text(
              l10n.mcpPerMachineTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              l10n.mcpCustomizedCount(customized),
              key: const ValueKey('mcp_customized_count'),
              style: muted,
            ),
            const SizedBox(height: 12),
            if (localDevice)
              _machineRow(
                context,
                id: mcpLocalDeviceHostId,
                name: l10n.mcpLocalDeviceName,
                detail: l10n.mcpLocalDeviceDetail,
                icon: switch (Theme.of(context).platform) {
                  TargetPlatform.android => Icons.phone_android_outlined,
                  TargetPlatform.iOS => Icons.phone_iphone_outlined,
                  _ => Icons.computer_outlined,
                },
              ),
            if (hosts.length > 6) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('mcp_machine_search'),
                controller: _query,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: l10n.mcpSearchMachines,
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                ),
                onChanged: (_) => setState(
                  () => _visibleMachines = McpSettingsPanel.machinePageSize,
                ),
              ),
            ],
            if (hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(l10n.mcpNoSavedMachines, style: muted),
              )
            else if (matching.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  l10n.mcpNoMachinesMatch(_query.text.trim()),
                  key: const ValueKey('mcp_machine_no_match'),
                  style: muted,
                ),
              ),
            for (final host in shown)
              _machineRow(
                context,
                id: host.id,
                name: host.name.isEmpty ? host.address : host.name,
                detail: _hostDetail(host),
                icon: Icons.dns_outlined,
              ),
            if (hidden > 0)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('mcp_machine_show_more'),
                  onPressed: () => setState(
                    () => _visibleMachines += McpSettingsPanel.machinePageSize,
                  ),
                  icon: const Icon(Icons.expand_more),
                  label: Text(l10n.mcpShowMoreMachines(hidden)),
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _hostDetail(HostRecord host) {
    final user = host.username.isEmpty ? '' : '${host.username}@';
    return '${host.protocol.name.toUpperCase()} · $user${host.address}:${host.port}';
  }

  Widget _machineRow(
    BuildContext context, {
    required String id,
    required String name,
    required String detail,
    required IconData icon,
  }) {
    final l10n = context.l10n;
    final override = service.accessOverrideForHost(id);
    final effective = service.effectiveAccessForHost(id);
    final pending = _pendingHosts.contains(id);
    final defaultLabel = mcpAccessModeLabel(l10n, service.defaultAccess);
    String choiceLabel(_HostChoice choice) => choice.mode == null
        ? l10n.mcpHostUseDefault(defaultLabel)
        : mcpAccessModeLabel(l10n, choice.mode!);

    final dropdown = Semantics(
      label: l10n.mcpHostAccessFor(name),
      child: DropdownButtonFormField<_HostChoice>(
        key: ValueKey('mcp_host_access_$id'),
        initialValue: _HostChoice.of(override),
        isExpanded: true,
        isDense: true,
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: Icon(mcpAccessModeIcon(effective), size: 18),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 36,
          ),
        ),
        items: [
          for (final choice in _HostChoice.values)
            DropdownMenuItem(
              value: choice,
              child: Text(
                choiceLabel(choice),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: pending
            ? null
            : (choice) {
                if (choice != null) _setHost(id, choice.mode);
              },
      ),
    );

    return Padding(
      key: ValueKey('mcp_host_row_$id'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ResponsiveControlRow(
        leading: Icon(icon, size: 20, color: context.palette.muted),
        label: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
                if (override != null) ...[
                  const SizedBox(width: 6),
                  _Tag(
                    key: ValueKey('mcp_host_custom_$id'),
                    text: l10n.mcpHostCustom,
                  ),
                ],
              ],
            ),
            Text(
              detail,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
          ],
        ),
        // Keyed by the stored override (and failed-save epoch) so an
        // external change or a rejected save resets the field to the value
        // actually in effect.
        control: KeyedSubtree(
          key: ValueKey('mcp_host_choice_${id}_${override?.name}_$_resetEpoch'),
          child: dropdown,
        ),
      ),
    );
  }

  Widget _toolsCard(BuildContext context) => SettingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.availableTools,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.sshConsoleSupportReadingTextAnd,
          style: TextStyle(color: context.palette.muted, height: 1.5),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tool in mcpTools)
              Chip(
                label: Text(
                  tool.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
      ],
    ),
  );

  Widget _auditCard(BuildContext context) => SettingsCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.recentCalls,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          context.l10n.onlyTheLast50ToolNames,
          style: TextStyle(color: context.palette.muted, fontSize: 12),
        ),
        if (service.audit.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(context.l10n.noCallsYet),
          ),
        for (final entry in service.audit.take(10))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              entry.success ? Icons.check_circle_outline : Icons.error_outline,
              color: entry.success
                  ? context.palette.lime
                  : context.palette.orange,
            ),
            title: Text(entry.tool),
            subtitle: Text(entry.at.toLocal().toString().split('.').first),
            trailing: Text(
              entry.success ? context.l10n.done : context.l10n.failed,
            ),
          ),
      ],
    ),
  );
}

class _AndroidForwardingHint extends StatelessWidget {
  const _AndroidForwardingHint({required this.port});
  final int port;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.mcpAndroidForwardingHint,
          style: TextStyle(
            color: context.palette.muted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: context.palette.codeBackground,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            'adb forward tcp:$port tcp:$port',
            key: const ValueKey('mcp_android_forward_command'),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: context.palette.codeText,
            ),
          ),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.color,
    required this.text,
    super.key,
  });
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 8),
      Expanded(
        child: Text(text, style: TextStyle(color: color, height: 1.4)),
      ),
    ],
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (isIosPhone(context)) {
      final colors = IosColors.of(context);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: colors.tint.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          text,
          style: IosType.caption1.copyWith(
            fontSize: 11,
            color: colors.tint,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: context.palette.accentText.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: context.palette.accentText),
      ),
    );
  }
}
