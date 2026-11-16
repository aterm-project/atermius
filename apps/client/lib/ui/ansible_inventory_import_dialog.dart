import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart' show CupertinoTextField, OverlayVisibilityMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../import/ansible_inventory_import.dart';
import '../import/ansible_inventory_refresh.dart';
import 'app_motion.dart';
import 'ios_native/ios_native.dart';
import '../l10n/l10n.dart';

const _uuid = Uuid();
const _newSourceSelection = '__new_ansible_inventory_source__';
const _maxAnsibleInventoryBytes = 1024 * 1024;
String get _stalePreviewMessage => currentL10n.aHostChangedAfterThePreview;

/// Local seam between this review flow and the pure, non-executing parser.
/// Tests can inject a deterministic parser without coupling to file access.
typedef AnsibleInventoryParseAdapter = AnsibleInventoryParseResult Function(
  String source,
);

Future<int?> showAnsibleInventoryImportDialog(
  BuildContext context, {
  required AppController app,
}) => showAppDialog<int>(
  context: context,
  motion: isIosPhone(context)
      ? AppDialogMotion.sideSheet
      : AppDialogMotion.center,
  builder: (_) => AnsibleInventoryImportDialog(app: app),
);

/// Lets a user paste or choose a static inventory, review safe Host fields,
/// and explicitly confirm before any encrypted Host record is written.
class AnsibleInventoryImportDialog extends StatefulWidget {
  const AnsibleInventoryImportDialog({
    required this.app,
    this.parseForTesting,
    this.pickBytesForTesting,
    super.key,
  });

  final AppController app;

  @visibleForTesting
  final AnsibleInventoryParseAdapter? parseForTesting;

  @visibleForTesting
  final Future<Uint8List?> Function()? pickBytesForTesting;

  @override
  State<AnsibleInventoryImportDialog> createState() =>
      _AnsibleInventoryImportDialogState();
}

class _AnsibleInventoryImportDialogState
    extends State<AnsibleInventoryImportDialog> {
  final _sourceController = TextEditingController();
  final _sourceLabelController = TextEditingController(
    text: currentL10n.pastedInventory,
  );
  AnsibleInventoryParseResult? _parsed;
  AnsibleInventoryRefreshPlan? _plan;
  AnsibleInventoryRefreshPlan? _basePlan;
  String? _previewVaultId;
  String? Function()? _sourceNameBuilder;
  String? get _sourceName => _sourceNameBuilder?.call();
  String _selectedSourceId = _newSourceSelection;
  String? _newSourceId;
  bool _sourceLabelEdited = false;
  final Map<String, Set<String>> _useInventoryFieldsByHostId = {};
  final Set<String> _markStaleHostIds = {};
  String? _error;
  bool _busy = false;

  AppController get app => widget.app;

  AnsibleInventoryParseResult _parse(String source) =>
      widget.parseForTesting?.call(source) ??
      AnsibleInventoryImporter.parse(source);

  Map<String, String> get _knownSources {
    final sources = <String, String>{};
    for (final host in app.hosts) {
      final metadata = host.ansibleInventoryImport;
      if (metadata == null) continue;
      sources.putIfAbsent(metadata.sourceId, () => metadata.sourceLabel);
    }
    return sources;
  }

  String get _sourceId => _selectedSourceId == _newSourceSelection
      ? (_newSourceId ??= _uuid.v4())
      : _selectedSourceId;

  Future<Uint8List?> _pickBytes() async {
    final injected = widget.pickBytesForTesting;
    if (injected != null) return injected();
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: true,
    );
    final file = result?.files.single;
    if (file == null) return null;
    final bytes = file.bytes;
    if (file.size > _maxAnsibleInventoryBytes) {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.inventoryFilesAreLimitedTo1);
    }
    if (bytes == null || bytes.length != file.size) {
      if (bytes != null) bytes.fillRange(0, bytes.length, 0);
      throw FormatException(currentL10n.theSelectedFileCouldNotBe);
    }
    final name = file.name;
    _sourceNameBuilder = () => name;
    return bytes;
  }

  Future<void> _chooseFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _parsed = null;
      _plan = null;
      _basePlan = null;
      _previewVaultId = null;
      _sourceNameBuilder = null;
    });
    Uint8List? bytes;
    try {
      bytes = await _pickBytes();
      if (!mounted || bytes == null) return;
      if (!_sourceLabelEdited) {
        _sourceLabelController.text = _sourceName ?? context.l10n.inventoryFile;
      }
      final source = utf8.decode(bytes, allowMalformed: false);
      _reviewSource(source);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() => _error = context.l10n.theSelectedFileCouldNotBe2);
      }
    } finally {
      bytes?.fillRange(0, bytes.length, 0);
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reviewPastedSource() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _parsed = null;
      _plan = null;
      _basePlan = null;
      _previewVaultId = null;
      _sourceNameBuilder = () => currentL10n.pastedInventory;
      if (!_sourceLabelEdited) {
        _sourceLabelController.text = context.l10n.pastedInventory;
      }
    });
    try {
      _reviewSource(_sourceController.text);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on Object {
      if (mounted) {
        setState(() => _error = context.l10n.theInventoryCouldNotBeReviewed);
      }
    } finally {
      // Inventory may contain credentials that are deliberately not imported.
      // Clear the editor after parsing so its source values do not remain in
      // the widget while the user reviews the safe projection.
      _sourceController.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reviewSource(String source) {
    final byteLength = utf8.encode(source).length;
    if (source.length > _maxAnsibleInventoryBytes ||
        byteLength > _maxAnsibleInventoryBytes) {
      throw FormatException(context.l10n.inventorySourcesAreLimitedTo1);
    }
    final result = _parse(source);
    if (!mounted) return;
    final plan = _buildPlan(result);
    setState(() {
      _parsed = result;
      _basePlan = plan;
      _plan = plan;
      _useInventoryFieldsByHostId.clear();
      _markStaleHostIds.clear();
      _previewVaultId = app.activeVault?.id;
    });
  }

  AnsibleInventoryRefreshPlan _buildPlan(AnsibleInventoryParseResult parsed) =>
      planAnsibleInventoryRefresh(
        parsed: parsed,
        savedHosts: app.hosts,
        sourceId: _sourceId,
        sourceLabel: _sourceLabelController.text.trim(),
      );

  void _rebuildPlan() {
    final parsed = _parsed;
    if (parsed == null) return;
    try {
      final base = _buildPlan(parsed);
      setState(() {
        _basePlan = base;
        _plan = base.resolveConflicts(
          useInventoryFieldsByHostId: _useInventoryFieldsByHostId,
        );
        _markStaleHostIds.clear();
        _error = null;
      });
    } on FormatException catch (error) {
      setState(() {
        _basePlan = null;
        _plan = null;
        _error = error.message;
      });
    }
  }

  void _chooseSource(String? sourceId) {
    if (sourceId == null || sourceId == _selectedSourceId) return;
    setState(() {
      _selectedSourceId = sourceId;
      if (sourceId == _newSourceSelection) {
        _newSourceId = _uuid.v4();
        _sourceLabelEdited = false;
        _sourceLabelController.text =
            _sourceName ?? context.l10n.pastedInventory;
      } else {
        _sourceLabelEdited = false;
        _sourceLabelController.text =
            _knownSources[sourceId] ?? context.l10n.inventory;
      }
      _useInventoryFieldsByHostId.clear();
    });
    _rebuildPlan();
  }

  void _chooseConflictValue(String hostId, String fieldKey, String? choice) {
    if (choice == null) return;
    final choices = _useInventoryFieldsByHostId.putIfAbsent(
      hostId,
      () => <String>{},
    );
    if (choice == 'inventory') {
      choices.add(fieldKey);
    } else {
      choices.remove(fieldKey);
    }
    setState(() {
      _plan = _basePlan?.resolveConflicts(
        useInventoryFieldsByHostId: _useInventoryFieldsByHostId,
      );
    });
  }

  Future<void> _confirmAndImport() async {
    final parsed = _parsed;
    final plan = _plan;
    if (_busy || parsed == null || plan == null || parsed.blocksWholeFile) {
      return;
    }
    final startingVaultId = _previewVaultId;
    if (startingVaultId == null ||
        app.activeVault?.id != startingVaultId ||
        app.activeVault?.canWrite != true ||
        app.activeVault?.status != 'active') {
      setState(() => _error = context.l10n.theActiveVaultChangedOrIs);
      return;
    }
    final toSave = plan.rows.where((row) {
      if (!row.needsSave) return false;
      if (row.status == AnsibleInventoryRefreshStatus.missing) {
        return row.existing != null &&
            _markStaleHostIds.contains(row.existing!.id);
      }
      return true;
    }).toList();
    if (toSave.isEmpty) return;
    final approved = await showAppDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('ansible_inventory_confirm_dialog'),
        title: Text(
          toSave.every(
                (row) => row.status == AnsibleInventoryRefreshStatus.create,
              )
              ? context.l10n.importTheseHosts
              : context.l10n.applyTheseInventoryChanges,
        ),
        content: Text(context.l10n.applyCountReviewedChangeSTo(toSave.length)),
        actions: [
          TextButton(
            key: const ValueKey('ansible_inventory_confirm_cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel2),
          ),
          FilledButton(
            key: const ValueKey('ansible_inventory_confirm_accept'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              toSave.every(
                    (row) => row.status == AnsibleInventoryRefreshStatus.create,
                  )
                  ? context.l10n.confirmImport
                  : context.l10n.confirmChanges,
            ),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    var savedCount = 0;
    try {
      for (final row in toSave) {
        if (app.activeVault?.id != startingVaultId ||
            app.activeVault?.canWrite != true ||
            app.activeVault?.status != 'active') {
          throw FormatException(currentL10n.theActiveVaultChangedOrBecame);
        }
        final host = row.plannedHost!;
        if (row.status == AnsibleInventoryRefreshStatus.create) {
          if (app.hosts.any(
            (existing) =>
                _normalizeName(existing.name) == _normalizeName(host.name),
          )) {
            throw FormatException(context.l10n.aHostWithThisNameWas);
          }
          await app.saveHost(host);
        } else {
          final expectedRevision = row.expectedRevisionId;
          if (expectedRevision == null ||
              !app.hosts.any(
                (existing) =>
                    existing.id == host.id &&
                    existing.revisionId == expectedRevision,
              )) {
            throw FormatException(_stalePreviewMessage);
          }
          await app.saveHostAtRevision(
            host,
            expectedRevisionId: expectedRevision,
          );
        }
        savedCount++;
        if (app.activeVault?.id != startingVaultId ||
            app.activeVault?.canWrite != true ||
            app.activeVault?.status != 'active') {
          throw FormatException(currentL10n.theActiveVaultChangedOrBecame);
        }
      }
      if (mounted) Navigator.pop(context, savedCount);
    } on FormatException catch (error) {
      final revisionChanged =
          error.message == _stalePreviewMessage ||
          error.message == currentL10n.thisHostChangedAfterThePreview;
      if (mounted) {
        setState(() {
          _error = revisionChanged && savedCount == 0
              ? _stalePreviewMessage
              : savedCount == 0
              ? context.l10n.noHostsWereImportedTheVault
              : '$savedCount Host(s) were saved before an error. Review the Hosts page before retrying.';
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _error = savedCount == 0
              ? context.l10n.noHostsWereImportedTheVault
              : '$savedCount Host(s) were saved before an error. Review the Hosts page before retrying.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _sourceController.clear();
    _sourceController.dispose();
    _sourceLabelController.clear();
    _sourceLabelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isIosPhone(context)) return _buildIosSheet(context);
    final parsed = _parsed;
    final plan = _plan;
    final count =
        plan?.rows.where((row) {
          if (!row.needsSave) return false;
          if (row.status == AnsibleInventoryRefreshStatus.missing) {
            return row.existing != null &&
                _markStaleHostIds.contains(row.existing!.id);
          }
          return true;
        }).length ??
        0;
    final sourceOptions = _knownSources;
    final width = MediaQuery.sizeOf(context).width - 48;
    return AlertDialog(
      scrollable: true,
      title: Text(context.l10n.importAnsibleInventory),
      content: SizedBox(
        width: width < 680 ? width : 680,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.pasteOrChooseAStaticIni),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const ValueKey('ansible_inventory_source_selector'),
              initialValue: _selectedSourceId,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: context.l10n.inventorySource,
              ),
              items: [
                DropdownMenuItem(
                  value: _newSourceSelection,
                  child: Text(context.l10n.createANewSource),
                ),
                for (final entry in sourceOptions.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(
                      '${entry.value} · ${entry.key.substring(0, 8)}',
                    ),
                  ),
              ],
              onChanged: _busy ? null : _chooseSource,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ansible_inventory_source_label'),
              controller: _sourceLabelController,
              enabled: !_busy,
              maxLength: 128,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: context.l10n.sourceLabel,
                helperText: context.l10n.savedInEncryptedHostMetadataFile,
              ),
              onChanged: (_) {
                _sourceLabelEdited = true;
                _rebuildPlan();
              },
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('ansible_inventory_source'),
              controller: _sourceController,
              minLines: 4,
              maxLines: 9,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) {
                if (_parsed != null) {
                  setState(() {
                    _parsed = null;
                    _plan = null;
                    _basePlan = null;
                    _previewVaultId = null;
                    _sourceNameBuilder = null;
                  });
                }
              },
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText:
                    '[web]\nweb-01 ansible_host=192.0.2.10 ansible_user=deploy',
                labelText: context.l10n.staticInventoryText,
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('ansible_inventory_pick_file'),
                  onPressed: _busy ? null : _chooseFile,
                  icon: const Icon(Icons.file_open_outlined),
                  label: Text(_sourceName ?? context.l10n.chooseInventoryFile),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('ansible_inventory_review'),
                  onPressed: _busy ? null : _reviewPastedSource,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: Text(context.l10n.reviewPastedInventory),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('ansible_inventory_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (parsed != null) ...[
              const SizedBox(height: 12),
              Text(
                parsed.blocksWholeFile
                    ? context.l10n.reviewBlockedThisInventoryCannotBe
                    : context.l10n.inventoryPreviewCounts(
                        plan?.createCount ?? 0,
                        plan?.updateCount ?? 0,
                        plan?.unchangedCount ?? 0,
                        plan?.staleCount ?? 0,
                      ),
                key: const ValueKey('ansible_inventory_preview_summary'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(context.l10n.reviewEachFieldConflictManualEdits),
              if (plan?.staleMarkingAllowed == false &&
                  plan?.staleMarkingReason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    plan!.staleMarkingReason!,
                    key: const ValueKey('ansible_inventory_stale_blocked'),
                  ),
                ),
              if (parsed.issues.isNotEmpty) ...[
                const SizedBox(height: 8),
                _AnsibleIssuesPanel(
                  issues: parsed.issues,
                  key: const ValueKey('ansible_inventory_issues'),
                ),
              ],
              if (plan != null && plan.rows.isNotEmpty)
                Column(
                  key: const ValueKey('ansible_inventory_preview'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < plan.rows.length; index++) ...[
                      if (index > 0) const Divider(height: 1),
                      _AnsibleRefreshPreviewTile(
                        row: plan.rows[index],
                        staleSelected:
                            plan.rows[index].existing != null &&
                            _markStaleHostIds.contains(
                              plan.rows[index].existing!.id,
                            ),
                        onStaleChanged: (selected) {
                          final id = plan.rows[index].existing?.id;
                          if (id == null) return;
                          setState(() {
                            if (selected == true) {
                              _markStaleHostIds.add(id);
                            } else {
                              _markStaleHostIds.remove(id);
                            }
                          });
                        },
                        inventoryFieldChoice: (hostId, fieldKey, choice) =>
                            _chooseConflictValue(hostId, fieldKey, choice),
                        useInventoryFieldsByHostId: _useInventoryFieldsByHostId,
                      ),
                    ],
                  ],
                ),
              if (plan != null && plan.rows.isEmpty)
                Text(context.l10n.noConcreteHostCandidatesWereFound),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('ansible_inventory_close'),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(context.l10n.close),
        ),
        FilledButton.icon(
          key: const ValueKey('ansible_inventory_import'),
          onPressed: _busy || count == 0 || parsed?.blocksWholeFile != false
              ? null
              : _confirmAndImport,
          icon: const Icon(Icons.download_done_outlined),
          label: Text(
            count == 0
                ? context.l10n.importHosts
                : plan != null &&
                      plan.rows
                          .where((row) => row.needsSave)
                          .every(
                            (row) =>
                                row.status ==
                                AnsibleInventoryRefreshStatus.create,
                          )
                ? context.l10n.importCountHosts(count)
                : context.l10n.applyCountChanges(count),
          ),
        ),
      ],
    );
  }

  String _normalizeName(String value) => value.trim().toLowerCase();

  Widget _buildIosSheet(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final parsed = _parsed;
    final plan = _plan;
    final count =
        plan?.rows.where((row) {
          if (!row.needsSave) return false;
          if (row.status == AnsibleInventoryRefreshStatus.missing) {
            return row.existing != null &&
                _markStaleHostIds.contains(row.existing!.id);
          }
          return true;
        }).length ??
        0;
    final sourceOptions = _knownSources;
    final actionLabel = count == 0
        ? l10n.importHosts
        : plan != null &&
              plan.rows
                  .where((row) => row.needsSave)
                  .every(
                    (row) => row.status == AnsibleInventoryRefreshStatus.create,
                  )
        ? l10n.importCountHosts(count)
        : l10n.applyCountChanges(count);

    return PopScope(
      canPop: !_busy,
      child: IosSheetScaffold(
        title: l10n.importAnsibleInventory,
        cancelKey: const ValueKey('ansible_inventory_close'),
        cancelLabel: l10n.close,
        onCancel: _busy ? () {} : () => Navigator.pop(context),
        actionKey: const ValueKey('ansible_inventory_import'),
        actionLabel: actionLabel,
        actionBusy: _busy,
        actionEnabled: !_busy && count > 0 && parsed?.blocksWholeFile == false,
        onAction: _confirmAndImport,
        scrollController: PrimaryScrollController.maybeOf(context),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                IosMetrics.sectionMargin,
                0,
                IosMetrics.sectionMargin,
                16,
              ),
              child: ClipRSuperellipse(
                borderRadius: BorderRadius.circular(14),
                child: ColoredBox(
                  color: c.destructive.withValues(alpha: c.isDark ? 0.18 : 0.12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Text(
                      _error!,
                      key: const ValueKey('ansible_inventory_error'),
                      style: IosType.subheadline.copyWith(color: c.destructive),
                    ),
                  ),
                ),
              ),
            ),
          IosListSection(
            header: l10n.pasteOrChooseAStaticIni,
            footer: l10n.savedInEncryptedHostMetadataFile,
            children: [
              IosPickerRow<String>(
                rowKey: const ValueKey('ansible_inventory_source_selector'),
                label: l10n.inventorySource,
                value: _selectedSourceId,
                enabled: !_busy,
                options: [
                  IosPickerOption<String>(
                    value: _newSourceSelection,
                    label: l10n.createANewSource,
                  ),
                  for (final entry in sourceOptions.entries)
                    IosPickerOption<String>(
                      value: entry.key,
                      label: entry.value,
                      subtitle: entry.key.substring(0, 8),
                    ),
                ],
                onChanged: _chooseSource,
              ),
              IosTextFieldRow(
                fieldKey: const ValueKey('ansible_inventory_source_label'),
                label: l10n.sourceLabel,
                placeholder: l10n.pastedInventory,
                controller: _sourceLabelController,
                enabled: !_busy,
                inputFormatters: [LengthLimitingTextInputFormatter(128)],
                onChanged: (_) {
                  _sourceLabelEdited = true;
                  _rebuildPlan();
                },
              ),
            ],
          ),
          IosListSection(
            header: l10n.staticInventoryText,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IosMetrics.rowPaddingH,
                  vertical: 12,
                ),
                child: CupertinoTextField(
                  key: const ValueKey('ansible_inventory_source'),
                  controller: _sourceController,
                  minLines: 4,
                  maxLines: 9,
                  enabled: !_busy,
                  autocorrect: false,
                  enableSuggestions: false,
                  clearButtonMode: OverlayVisibilityMode.never,
                  decoration: null,
                  padding: EdgeInsets.zero,
                  style: IosType.mono.copyWith(fontSize: 13, color: c.label),
                  placeholder:
                      '[web]\nweb-01 ansible_host=192.0.2.10 ansible_user=deploy',
                  placeholderStyle: IosType.mono.copyWith(
                    fontSize: 13,
                    color: c.tertiaryLabel,
                  ),
                  cursorColor: c.tint,
                  onChanged: (_) {
                    if (_parsed != null) {
                      setState(() {
                        _parsed = null;
                        _plan = null;
                        _basePlan = null;
                        _previewVaultId = null;
                        _sourceNameBuilder = null;
                      });
                    }
                  },
                ),
              ),
              IosListActionRow(
                key: const ValueKey('ansible_inventory_pick_file'),
                icon: Icons.file_open_rounded,
                label: _sourceName ?? l10n.chooseInventoryFile,
                onTap: _busy ? null : _chooseFile,
              ),
              IosListActionRow(
                key: const ValueKey('ansible_inventory_review'),
                icon: Icons.fact_check_rounded,
                label: l10n.reviewPastedInventory,
                onTap: _busy ? null : _reviewPastedSource,
              ),
            ],
          ),
          if (parsed != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                IosMetrics.sectionHeaderInset,
                0,
                IosMetrics.sectionHeaderInset,
                6,
              ),
              child: Text(
                parsed.blocksWholeFile
                    ? l10n.reviewBlockedThisInventoryCannotBe
                    : l10n.inventoryPreviewCounts(
                        plan?.createCount ?? 0,
                        plan?.updateCount ?? 0,
                        plan?.unchangedCount ?? 0,
                        plan?.staleCount ?? 0,
                      ),
                key: const ValueKey('ansible_inventory_preview_summary'),
                style: IosType.footnote.copyWith(
                  color: parsed.blocksWholeFile
                      ? c.destructive
                      : c.secondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                IosMetrics.sectionHeaderInset,
                0,
                IosMetrics.sectionHeaderInset,
                10,
              ),
              child: Text(
                l10n.reviewEachFieldConflictManualEdits,
                style: IosType.footnote.copyWith(color: c.secondaryLabel),
              ),
            ),
            if (plan?.staleMarkingAllowed == false &&
                plan?.staleMarkingReason != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IosMetrics.sectionHeaderInset,
                  0,
                  IosMetrics.sectionHeaderInset,
                  12,
                ),
                child: Text(
                  plan!.staleMarkingReason!,
                  key: const ValueKey('ansible_inventory_stale_blocked'),
                  style: IosType.footnote.copyWith(color: c.warning),
                ),
              ),
            if (parsed.issues.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IosMetrics.sectionMargin,
                  0,
                  IosMetrics.sectionMargin,
                  16,
                ),
                child: _AnsibleIssuesPanel(
                  issues: parsed.issues,
                  key: const ValueKey('ansible_inventory_issues'),
                ),
              ),
            if (plan != null && plan.rows.isNotEmpty)
              IosListSection(
                key: const ValueKey('ansible_inventory_preview'),
                children: [
                  for (var index = 0; index < plan.rows.length; index++)
                    _AnsibleRefreshPreviewTile(
                      row: plan.rows[index],
                      staleSelected:
                          plan.rows[index].existing != null &&
                          _markStaleHostIds.contains(
                            plan.rows[index].existing!.id,
                          ),
                      onStaleChanged: (selected) {
                        final id = plan.rows[index].existing?.id;
                        if (id == null) return;
                        setState(() {
                          if (selected == true) {
                            _markStaleHostIds.add(id);
                          } else {
                            _markStaleHostIds.remove(id);
                          }
                        });
                      },
                      inventoryFieldChoice: (hostId, fieldKey, choice) =>
                          _chooseConflictValue(hostId, fieldKey, choice),
                      useInventoryFieldsByHostId: _useInventoryFieldsByHostId,
                    ),
                ],
              ),
            if (plan != null && plan.rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IosMetrics.sectionHeaderInset,
                ),
                child: Text(
                  l10n.noConcreteHostCandidatesWereFound,
                  style: IosType.subheadline.copyWith(color: c.secondaryLabel),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _AnsibleRefreshPreviewTile extends StatelessWidget {
  const _AnsibleRefreshPreviewTile({
    required this.row,
    required this.staleSelected,
    required this.onStaleChanged,
    required this.inventoryFieldChoice,
    required this.useInventoryFieldsByHostId,
  });

  final AnsibleInventoryRefreshRow row;
  final bool staleSelected;
  final ValueChanged<bool?> onStaleChanged;
  final void Function(String hostId, String fieldKey, String choice)
  inventoryFieldChoice;
  final Map<String, Set<String>> useInventoryFieldsByHostId;

  @override
  Widget build(BuildContext context) {
    final host = row.plannedHost ?? row.existing;
    final hostId = row.existing?.id;
    final isMissing = row.status == AnsibleInventoryRefreshStatus.missing;
    final fields = row.fields;
    if (isIosPhone(context)) {
      final c = IosColors.of(context);
      final blocked =
          isMissing || row.status == AnsibleInventoryRefreshStatus.blocked;
      final subtitleLines = <String>[
        if (host != null)
          context.l10n.importPlannedEndpoint(
            '${host.username}@${host.address}:${host.port}',
          ),
        if (host?.tags.isNotEmpty == true)
          context.l10n.importHostTags(host!.tags.join(', ')),
        if (row.existing != null)
          context.l10n.importSavedEndpoint(
            '${row.existing!.username}@${row.existing!.address}:${row.existing!.port}',
          ),
        if (row.note != null) row.note!,
      ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            key: ValueKey('ansible_inventory_host_${row.name}'),
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.rowPaddingH,
              vertical: 10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IosIconTile(
                  icon: blocked ? IosIcons.warning : IosIcons.hosts,
                  color: blocked ? c.destructive : c.green,
                ),
                const SizedBox(width: IosMetrics.iconTextGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row.name} · ${_statusLabel(row.status)}',
                        style: IosType.body.copyWith(color: c.label),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitleLines.join('\n'),
                        style: IosType.footnote.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (row.hasConflict && hostId != null)
            for (final field in fields.where((item) => item.conflict))
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  IosMetrics.rowPaddingH,
                  0,
                  IosMetrics.rowPaddingH,
                  8,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${field.label}: ${field.current} → ${field.incoming}',
                      key: ValueKey(
                        'ansible_refresh_conflict_${hostId}_${field.key}',
                      ),
                      style: IosType.footnote.copyWith(color: c.secondaryLabel),
                    ),
                    const SizedBox(height: 4),
                    IosSegmentedRow<String>(
                      controlKey: ValueKey(
                        'ansible_refresh_field_choice_${hostId}_${field.key}',
                      ),
                      value:
                          (useInventoryFieldsByHostId[hostId] ?? const {})
                              .contains(field.key)
                          ? 'inventory'
                          : 'manual',
                      segments: {
                        'manual': context.l10n.keepManual,
                        'inventory': context.l10n.useInventory,
                      },
                      onChanged: (choice) =>
                          inventoryFieldChoice(hostId, field.key, choice),
                    ),
                  ],
                ),
              ),
          if (isMissing && row.existing != null)
            IosSwitchRow(
              switchKey: ValueKey(
                'ansible_inventory_mark_stale_${row.existing!.id}',
              ),
              label: context.l10n.markStaleKeepThisHostSaved,
              value: staleSelected,
              onChanged: row.needsSave
                  ? (val) => onStaleChanged(val)
                  : null,
            ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            key: ValueKey('ansible_inventory_host_${row.name}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              isMissing
                  ? Icons.warning_amber_outlined
                  : row.status == AnsibleInventoryRefreshStatus.blocked ||
                        row.status == AnsibleInventoryRefreshStatus.skipped
                  ? Icons.info_outline
                  : Icons.dns_outlined,
              color:
                  isMissing ||
                      row.status == AnsibleInventoryRefreshStatus.blocked
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
            title: Text('${row.name} · ${_statusLabel(row.status)}'),
            subtitle: Text(
              [
                if (host != null)
                  context.l10n.importPlannedEndpoint(
                    '${host.username}@${host.address}:${host.port}',
                  ),
                if (host?.tags.isNotEmpty == true)
                  context.l10n.importHostTags(host!.tags.join(', ')),
                if (row.existing != null)
                  context.l10n.importSavedEndpoint(
                    '${row.existing!.username}@${row.existing!.address}:${row.existing!.port}',
                  ),
                if (row.note != null) row.note!,
              ].join('\n'),
            ),
            isThreeLine: true,
            dense: true,
          ),
          if (row.hasConflict && hostId != null)
            for (final field in fields.where((item) => item.conflict))
              Padding(
                padding: const EdgeInsets.only(left: 54, bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${field.label}: ${field.current} → ${field.incoming}',
                        key: ValueKey(
                          'ansible_refresh_conflict_${hostId}_${field.key}',
                        ),
                      ),
                    ),
                    DropdownButton<String>(
                      key: ValueKey(
                        'ansible_refresh_field_choice_${hostId}_${field.key}',
                      ),
                      value:
                          (useInventoryFieldsByHostId[hostId] ?? const {})
                              .contains(field.key)
                          ? 'inventory'
                          : 'manual',
                      items: [
                        DropdownMenuItem(
                          value: 'manual',
                          child: Text(context.l10n.keepManual),
                        ),
                        DropdownMenuItem(
                          value: 'inventory',
                          child: Text(context.l10n.useInventory),
                        ),
                      ],
                      onChanged: (choice) {
                        if (choice != null) {
                          inventoryFieldChoice(hostId, field.key, choice);
                        }
                      },
                    ),
                  ],
                ),
              ),
          if (isMissing && row.existing != null)
            CheckboxListTile(
              key: ValueKey('ansible_inventory_mark_stale_${row.existing!.id}'),
              contentPadding: const EdgeInsets.only(left: 44),
              value: staleSelected,
              onChanged: row.needsSave ? onStaleChanged : null,
              title: Text(context.l10n.markStaleKeepThisHostSaved),
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
            ),
        ],
      ),
    );
  }

  String _statusLabel(AnsibleInventoryRefreshStatus status) => switch (status) {
    AnsibleInventoryRefreshStatus.create => currentL10n.importStatusCreate,
    AnsibleInventoryRefreshStatus.update => currentL10n.importStatusUpdate,
    AnsibleInventoryRefreshStatus.unchanged =>
      currentL10n.importStatusUnchanged,
    AnsibleInventoryRefreshStatus.missing => currentL10n.importStatusMissing,
    AnsibleInventoryRefreshStatus.skipped => currentL10n.importStatusSkipped,
    AnsibleInventoryRefreshStatus.blocked => currentL10n.importStatusBlocked,
  };
}

class _AnsibleIssuesPanel extends StatelessWidget {
  const _AnsibleIssuesPanel({required this.issues, super.key});

  final List<AnsibleInventoryIssue> issues;

  @override
  Widget build(BuildContext context) => Container(
    key: key,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.all(8),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final issue in issues.take(12))
          Text(context.l10n.lineLineMessage(issue.line, issue.message)),
        if (issues.length > 12)
          Text(
            context.l10n.valuevalueAdditionalFindingsAreHidden(
              issues.length - 12,
            ),
          ),
      ],
    ),
  );
}
