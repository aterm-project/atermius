part of '../host_editor_panel.dart';

const _kIosNoneSelection = '__ios_none_selection__';

extension _HostEditorPanelIos on _HostEditorPanelState {
  bool _hasIosUnsavedChanges() {
    if (!widget.canEdit) return false;
    return _name.text != _initialName ||
        _address.text != _initialAddress ||
        _username.text != _initialUsername ||
        _port.text != _initialPort ||
        _tags.text != _initialTags ||
        _password.text != _initialPassword ||
        _privateKey.text != _initialPrivateKey ||
        _passphrase.text != _initialPassphrase ||
        _rdpFingerprint.text != _initialRdpFingerprint ||
        _protocol != _initialProtocolValue ||
        _source != _initialSource ||
        _kind != _initialKindValue ||
        _groupId != _initialGroupId ||
        _jumpHostId != _initialJumpHostId ||
        _rdpSettings != _initialRdpSettings ||
        _vncSettings != _initialVncSettings;
  }

  List<IosPickerOption<String>> _iosSourceOptions(BuildContext context) {
    final l10n = context.l10n;
    final map = <String, String>{
      _sourceOwn: l10n.r7NavSignInOwn,
      if (_initialSource == _sourceInherit)
        _sourceInherit: l10n.r7NavSignInInherited,
      for (final choice in widget.keychain)
        _sourceKeychain(choice.id): l10n.r7NavSignInKeychainItem(choice.label),
    };
    if (_initialSource.startsWith('k:') && !map.containsKey(_initialSource)) {
      map[_initialSource] = l10n.r7NavSignInKeychainItem(
        widget.initialCredential?.name ?? l10n.r7NavKeychain,
      );
    }
    return [
      for (final entry in map.entries)
        IosPickerOption<String>(value: entry.key, label: entry.value),
    ];
  }

  Widget _buildIos(BuildContext context) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    final canEdit = widget.canEdit;
    final prefix = widget.keyPrefix;
    final lang = Localizations.localeOf(context).languageCode;

    final hostsById = {for (final host in widget.hosts) host.id: host};
    final eligibleJumpHosts = widget.hosts
        .where((host) => _isEligibleJumpHost(host, hostsById))
        .toList(growable: false);
    final hasEligibleJumpHost = eligibleJumpHosts.any(
      (host) => host.id == _jumpHostId,
    );
    final unavailableJumpHost = _jumpHostId != null && !hasEligibleJumpHost;
    final unavailableGroup =
        _groupId != null &&
        !widget.groups.any((group) => group.id == _groupId);

    final showSourcePicker =
        _protocol == HostProtocol.ssh &&
        (widget.keychain.isNotEmpty || _initialSource != _sourceOwn);
    final showInlineAuth =
        _protocol != HostProtocol.telnet &&
        !(_protocol == HostProtocol.ssh && _source != _sourceOwn);

    final authFooter = _protocol == HostProtocol.ssh
        ? l10n.loginDetailsBelongToThisHost
        : _protocol == HostProtocol.telnet
        ? l10n.telnetLoginInteractiveHint
        : DesktopSession.supportsDirect(_protocol)
        ? l10n.directDesktopSignInHint
        : l10n.signInDetailsAreStoredEncrypted;

    final advancedSummaryParts = <String>[
      if (_protocol == HostProtocol.ssh && _jumpHostId != null)
        eligibleJumpHosts
                .where((h) => h.id == _jumpHostId)
                .firstOrNull
                ?.name ??
            l10n.unavailableJumpHost,
      if (_tags.text.trim().isNotEmpty) _tags.text.trim(),
    ];

    return IosSheetScaffold(
      title: widget.existing == null ? l10n.addAHost : l10n.editHost,
      cancelLabel: l10n.cancel2,
      actionLabel: widget.submitLabel ?? l10n.save2,
      actionKey: ValueKey('${prefix}_save'),
      actionEnabled: canEdit,
      onAction: canEdit ? _save : null,
      isDirty: _hasIosUnsavedChanges,
      scrollController: PrimaryScrollController.maybeOf(context),
      children: [
        if (_formError != null)
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
                  child: Row(
                    children: [
                      Icon(IosIcons.warning, size: 18, color: c.destructive),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _formError!,
                          style: IosType.subheadline.copyWith(
                            color: c.destructive,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // 1. 基本连接信息
        IosListSection(
          children: [
            IosPickerRow<HostProtocol>(
              rowKey: ValueKey('${prefix}_protocol'),
              label: l10n.protocol,
              value: _protocol,
              enabled: canEdit,
              options: [
                for (final p in HostProtocol.values)
                  IosPickerOption<HostProtocol>(value: p, label: p.label),
              ],
              onChanged: (value) => _iosSetState(() {
                if (_port.text == '${_protocol.defaultPort}') {
                  _port.text = '${value.defaultPort}';
                }
                _protocol = value;
                if (value != HostProtocol.ssh) {
                  _kind = AuthKind.password;
                  _jumpHostId = null;
                }
                _lastKnownIosDirty = _hasIosUnsavedChanges();
              }),
            ),
            IosTextFieldRow(
              fieldKey: ValueKey('${prefix}_name'),
              label: l10n.displayName,
              placeholder: l10n.displayName,
              controller: _name,
              enabled: canEdit,
              textInputAction: TextInputAction.next,
            ),
            IosTextFieldRow(
              fieldKey: ValueKey('${prefix}_address'),
              label: l10n.hostnameOrIp,
              placeholder: 'example.com',
              controller: _address,
              enabled: canEdit,
              mono: true,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
            ),
            IosTextFieldRow(
              fieldKey: ValueKey('${prefix}_port'),
              label: l10n.port2,
              placeholder: '${_protocol.defaultPort}',
              controller: _port,
              enabled: canEdit,
              mono: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
            ),
            if (_protocol != HostProtocol.telnet)
              IosTextFieldRow(
                fieldKey: ValueKey('${prefix}_username'),
                label: _protocol == HostProtocol.ssh
                    ? l10n.sshUsername
                    : l10n.usernameOptional,
                placeholder: _protocol == HostProtocol.ssh
                    ? 'root'
                    : l10n.usernameOptional,
                controller: _username,
                enabled: canEdit,
                mono: true,
                textInputAction: TextInputAction.next,
              ),
          ],
        ),

        // 2. 认证方式与凭据选择
        IosListSection(
          header: l10n.authentication,
          footer: authFooter,
          children: [
            if (_protocol == HostProtocol.telnet)
              const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: IosMetrics.rowPaddingH,
                  vertical: 10,
                ),
                child: TelnetPlaintextNotice(),
              ),
            if (showSourcePicker)
              IosPickerRow<String>(
                rowKey: ValueKey('${prefix}_sign_in_source'),
                label: l10n.r7NavSignInSource,
                value: _source,
                enabled: canEdit,
                options: _iosSourceOptions(context),
                onChanged: (value) => _iosSetState(() {
                  _selectSource(value);
                  _lastKnownIosDirty = _hasIosUnsavedChanges();
                }),
              ),
            if (showSourcePicker && _source != _sourceOwn)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IosMetrics.rowPaddingH,
                  vertical: 10,
                ),
                child: Text(
                  _source == _sourceInherit
                      ? l10n.r7NavSignInInheritedNote
                      : l10n.r7NavSignInKeychainNote,
                  key: ValueKey('${prefix}_sign_in_note'),
                  style: IosType.footnote.copyWith(color: c.secondaryLabel),
                ),
              ),
            if (_protocol == HostProtocol.ssh && _source == _sourceOwn)
              IosSegmentedRow<AuthKind>(
                controlKey: ValueKey('${prefix}_kind'),
                label: l10n.authentication,
                value: _kind,
                segments: {
                  AuthKind.password: l10n.password,
                  AuthKind.privateKey: l10n.privateKey,
                },
                onChanged: canEdit
                    ? (value) => _iosSetState(() {
                        _kind = value;
                        _lastKnownIosDirty = _hasIosUnsavedChanges();
                      })
                    : null,
              ),
            if (showInlineAuth && _kind == AuthKind.password)
              IosTextFieldRow(
                fieldKey: ValueKey('${prefix}_password'),
                label: _protocol == HostProtocol.ssh
                    ? l10n.sshPasswordLabel
                    : l10n.passwordOptionalLabel,
                placeholder: '••••••••',
                controller: _password,
                obscureText: true,
                enabled: canEdit,
              ),
            if (showInlineAuth && _kind == AuthKind.privateKey) ...[
              _buildIosPrivateKeyRow(context, prefix: prefix, canEdit: canEdit),
              IosTextFieldRow(
                fieldKey: ValueKey('${prefix}_passphrase'),
                label: l10n.keyPassphraseOptional,
                placeholder: l10n.keyPassphraseOptional,
                controller: _passphrase,
                obscureText: true,
                enabled: canEdit,
              ),
            ],
          ],
        ),

        // 3. 分组选择
        if (_groupId != null || widget.groups.isNotEmpty)
          IosListSection(
            footer: unavailableGroup
                ? l10n.thisSavedGroupIsUnavailableChoose
                : null,
            children: [
              IosPickerRow<String>(
                rowKey: ValueKey('${prefix}_group'),
                label: l10n.group,
                value: unavailableGroup
                    ? '__unavailable_group__'
                    : (_groupId ?? _kIosNoneSelection),
                placeholder: unavailableGroup
                    ? l10n.unavailableGroup
                    : l10n.noGroup,
                enabled: canEdit,
                options: [
                  IosPickerOption<String>(
                    value: _kIosNoneSelection,
                    label: l10n.noGroup,
                  ),
                  for (final group in widget.groups)
                    IosPickerOption<String>(
                      value: group.id,
                      label: group.name,
                    ),
                ],
                onChanged: (value) => _iosSetState(() {
                  _groupId = value == _kIosNoneSelection ? null : value;
                  _lastKnownIosDirty = _hasIosUnsavedChanges();
                }),
              ),
            ],
          ),

        // 4. 高级折叠区（跳板机、标签、桌面协议扩展）
        IosListSection(
          footer: _iosAdvancedExpanded && _protocol == HostProtocol.ssh
              ? (unavailableJumpHost
                    ? l10n.thisSavedJumpHostIsUnavailable
                    : l10n.routeThroughUpTo8Hosts)
              : null,
          children: [
            IosListRow(
              key: ValueKey('${prefix}_ios_advanced_toggle'),
              title: Text(lang == 'zh' ? '高级选项' : 'Advanced'),
              value: _iosAdvancedExpanded || advancedSummaryParts.isEmpty
                  ? null
                  : advancedSummaryParts.join(' · '),
              trailing: AnimatedRotation(
                turns: _iosAdvancedExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: IosChevron(
                  direction: IosChevronDirection.down,
                  size: 12,
                  color: c.secondaryLabel,
                ),
              ),
              onTap: () => _iosSetState(
                () => _iosAdvancedExpanded = !_iosAdvancedExpanded,
              ),
            ),
            if (_iosAdvancedExpanded) ...[
              if (_protocol == HostProtocol.ssh)
                IosPickerRow<String>(
                  rowKey: ValueKey('${prefix}_jump_host'),
                  label: l10n.jumpHost,
                  value: unavailableJumpHost
                      ? '__unavailable_jump_host__'
                      : (_jumpHostId ?? _kIosNoneSelection),
                  placeholder: unavailableJumpHost
                      ? l10n.unavailableJumpHost
                      : l10n.directConnection,
                  enabled: canEdit,
                  options: [
                    IosPickerOption<String>(
                      value: _kIosNoneSelection,
                      label: l10n.directConnection,
                    ),
                    for (final host in eligibleJumpHosts)
                      IosPickerOption<String>(
                        value: host.id,
                        label: host.name,
                        subtitle: host.endpoint,
                      ),
                  ],
                  onChanged: (value) => _iosSetState(() {
                    _jumpHostId = value == _kIosNoneSelection ? null : value;
                    _lastKnownIosDirty = _hasIosUnsavedChanges();
                  }),
                ),
              IosTextFieldRow(
                fieldKey: ValueKey('${prefix}_tags'),
                label: l10n.tags,
                placeholder: l10n.separateTagsWithCommas,
                controller: _tags,
                enabled: canEdit,
              ),
              if (_protocol == HostProtocol.rdp) ...[
                IosTextFieldRow(
                  fieldKey: ValueKey('${prefix}_rdp_fingerprint'),
                  label: l10n.rdpCertificateSha256Optional,
                  placeholder: l10n.pinTheCertificateFingerprintSuppliedBy,
                  controller: _rdpFingerprint,
                  enabled: canEdit,
                  mono: true,
                ),
                Padding(
                  padding: const EdgeInsets.all(IosMetrics.rowPaddingH),
                  child: RdpSettingsEditor(
                    keyPrefix: prefix,
                    initial: _rdpSettings,
                    unreadable:
                        widget.existing != null &&
                        RdpSettings.unreadable(widget.existing!),
                    features: rdpEngineFeatures(),
                    pickFolder: pickRdpRedirectFolder,
                    pickDisk: rdpDiskPickerAvailable
                        ? pickRdpRedirectDisk
                        : null,
                    onChanged: (value) => _iosSetState(() {
                      _rdpSettings = value;
                      _lastKnownIosDirty = _hasIosUnsavedChanges();
                    }),
                  ),
                ),
              ],
              if (_protocol == HostProtocol.vnc)
                Padding(
                  padding: const EdgeInsets.all(IosMetrics.rowPaddingH),
                  child: VncSettingsEditor(
                    keyPrefix: prefix,
                    initial: _vncSettings,
                    onChanged: (value) => _iosSetState(() {
                      _vncSettings = value;
                      _lastKnownIosDirty = _hasIosUnsavedChanges();
                    }),
                  ),
                ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildIosPrivateKeyRow(
    BuildContext context, {
    required String prefix,
    required bool canEdit,
  }) {
    final c = IosColors.of(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        IosListRow(
          title: Text(l10n.sshPrivateKey),
          value: _editingPrivateKey
              ? null
              : (_privateKey.text.isEmpty ? l10n.noKeyEntered : '••••••••'),
          trailing: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canEdit
                ? () => _iosSetState(
                    () => _editingPrivateKey = !_editingPrivateKey,
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                _editingPrivateKey ? l10n.hidePrivateKey : l10n.editPrivateKey,
                style: IosType.subheadline.copyWith(
                  color: canEdit ? c.tint : c.tertiaryLabel,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          onTap: canEdit
              ? () => _iosSetState(
                  () => _editingPrivateKey = !_editingPrivateKey,
                )
              : null,
        ),
        if (_editingPrivateKey)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.rowPaddingH,
              0,
              IosMetrics.rowPaddingH,
              12,
            ),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: c.fill,
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: CupertinoTextField(
                  key: ValueKey('${prefix}_private_key'),
                  controller: _privateKey,
                  enabled: canEdit,
                  maxLines: 6,
                  minLines: 4,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  clearButtonMode: OverlayVisibilityMode.never,
                  decoration: null,
                  style: IosType.mono.copyWith(fontSize: 13, color: c.label),
                  placeholder: '-----BEGIN OPENSSH PRIVATE KEY-----',
                  placeholderStyle: IosType.mono.copyWith(
                    fontSize: 13,
                    color: c.tertiaryLabel,
                  ),
                  cursorColor: c.tint,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
