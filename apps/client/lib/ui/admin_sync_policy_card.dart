// Admin console card for the instance sync policy: how many versions of each
// record the server keeps.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'app_theme.dart';

class InstanceAdminSyncPolicyCard extends StatefulWidget {
  const InstanceAdminSyncPolicyCard({required this.app, super.key});

  final AppController app;

  @override
  State<InstanceAdminSyncPolicyCard> createState() =>
      _InstanceAdminSyncPolicyCardState();
}

class _InstanceAdminSyncPolicyCardState
    extends State<InstanceAdminSyncPolicyCard> {
  late final TextEditingController _limitController;
  InstanceAdminSyncPolicy? _observedPolicy;
  String? _limitError;

  @override
  void initState() {
    super.initState();
    _limitController = TextEditingController();
    _observedPolicy = widget.app.instanceAdminSyncPolicy;
    _applyPolicy(_observedPolicy);
    widget.app.addListener(_syncPolicyDraft);
  }

  @override
  void didUpdateWidget(covariant InstanceAdminSyncPolicyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_syncPolicyDraft);
      _observedPolicy = widget.app.instanceAdminSyncPolicy;
      _applyPolicy(_observedPolicy);
      widget.app.addListener(_syncPolicyDraft);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_syncPolicyDraft);
    _limitController.dispose();
    super.dispose();
  }

  void _syncPolicyDraft() {
    final policy = widget.app.instanceAdminSyncPolicy;
    if (identical(policy, _observedPolicy)) return;
    _observedPolicy = policy;
    _applyPolicy(policy);
  }

  void _applyPolicy(InstanceAdminSyncPolicy? policy) {
    _limitController.text = policy?.recordHistoryLimit.toString() ?? '';
    _limitError = null;
  }

  Future<void> _save() async {
    final policy = widget.app.instanceAdminSyncPolicy;
    if (policy == null) return;
    final limit = int.tryParse(_limitController.text.trim());
    if (limit == null ||
        limit < policy.minRecordHistoryLimit ||
        limit > policy.maxRecordHistoryLimit) {
      setState(() {
        _limitError = context.l10n.syncPolicyLimitOutOfRange(
          policy.minRecordHistoryLimit,
          policy.maxRecordHistoryLimit,
        );
      });
      return;
    }
    setState(() => _limitError = null);
    await widget.app.saveInstanceAdminSyncPolicy(limit);
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final policy = app.instanceAdminSyncPolicy;
    final busy =
        app.instanceAdminSyncPolicyLoading || app.instanceAdminSyncPolicySaving;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(17),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.l10n.syncPolicyTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 5),
            Text(
              context.l10n.syncPolicyDescription,
              style: TextStyle(color: context.palette.muted, fontSize: 12),
            ),
            if (app.instanceAdminSyncPolicyLoading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 7),
              Text(context.l10n.syncPolicyLoading),
            ],
            if (app.instanceAdminSyncPolicyError case final error?) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: context.palette.red),
                ),
              ),
            ],
            if (policy case final value?) ...[
              const SizedBox(height: 10),
              TextField(
                key: const ValueKey('admin-sync-policy-history-limit'),
                controller: _limitController,
                enabled: !busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: context.l10n.syncPolicyLimitLabel,
                  hintText: context.l10n.syncPolicyLimitHint(
                    value.minRecordHistoryLimit,
                    value.maxRecordHistoryLimit,
                  ),
                  helperText: context.l10n.syncPolicyDefaultLine(
                    value.defaultRecordHistoryLimit,
                  ),
                  errorText: _limitError,
                ),
              ),
              if (app.instanceAdminSyncPolicySaveError case final error?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    error,
                    style: TextStyle(color: context.palette.red),
                  ),
                ),
              ],
              if (app.instanceAdminSyncPolicyNotice case final notice?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    notice,
                    style: TextStyle(color: context.palette.lime),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const ValueKey('admin-sync-policy-save'),
                onPressed: busy ? null : _save,
                icon: app.instanceAdminSyncPolicySaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(
                  app.instanceAdminSyncPolicySaving
                      ? context.l10n.saving
                      : context.l10n.syncPolicySave,
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('admin-sync-policy-load'),
              onPressed: busy
                  ? null
                  : () => unawaited(app.loadInstanceAdminSyncPolicy()),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                policy == null
                    ? context.l10n.syncPolicyLoad
                    : context.l10n.refresh,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
