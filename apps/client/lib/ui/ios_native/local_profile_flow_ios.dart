part of '../local_profile_flow.dart';

// ============================================================================
// ⑥ ios-flow-wiring：LocalProfileFlow 的纯正 iOS Phone 适配层（part 文件）
// ============================================================================

extension _LocalProfileFlowIos on _LocalProfileFlowState {
  /// 当存在未处于解锁屏的页面级错误时，在 iOS Phone 下转为顶部胶囊 Toast 提示。
  void _scheduleIosPageErrorToast(BuildContext context) {
    final error = _pageError;
    if (error == null) {
      _lastIosToastedPageError = null;
      return;
    }
    if (_activeProfile == null || _lastIosToastedPageError == error) {
      return;
    }
    _lastIosToastedPageError = error;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _disposing) return;
      if (_pageError == error && isIosPhone(this.context)) {
        IosToast.show(this.context, error, kind: IosToastKind.warning);
      }
    });
  }

  /// 当前实时会话列表（不含 Home，按 _tabOrder 排列），读取最新连接态。
  List<WorkspaceTab> _buildIosLiveWorkspaceTabs(BuildContext context) =>
      _tabOrder.arrange<WorkspaceTab>([
        for (final session in _visibleSessions)
          WorkspaceTab(
            id: session.id,
            title: session.host.name,
            isConnected: session.connected.value,
            canDisconnect:
                session.console == null &&
                session.desktop == null &&
                (session.connected.value ||
                    session.telnetState == 'connecting' ||
                    session.recovery?.automaticEnabled == true),
            canOpenFiles: session.connection != null,
            canDetach: false,
          ),
        for (final entry in _files.entries)
          WorkspaceTab(
            id: entry.id,
            title: entry.title,
            isConnected: true,
            isFile: true,
            canDetach: false,
          ),
      ], (tab) => tab.id);

  Map<String, String> _iosSessionSubtitles(BuildContext context) => {
    for (final session in _visibleSessions)
      session.id: session.console != null
          ? context.l10n.console
          : formatIosHostEndpoint(session.host),
    for (final entry in _files.entries) entry.id: context.l10n.fileManager,
  };

  Set<String> _iosConnectingSessionIds() => {
    for (final session in _visibleSessions)
      if (!session.connected.value &&
          (session.progress.isLoading || session.telnetState == 'connecting'))
        session.id,
  };

  Listenable _iosSessionListenable() => Listenable.merge([
    sshTransferActivity,
    for (final session in _visibleSessions) ...[
      session.connected,
      session.progress,
    ],
  ]);

  Future<void> _iosRefreshWorkspace() async {
    if (_busy || _repository == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      await _reloadHosts(generation);
      await _reloadCredentials(generation);
      await _reloadGroups(generation);
      await _reloadSnippets(generation);
    } finally {
      _finishOperation(generation);
    }
  }

  IosWorkspaceData _buildIosWorkspaceData(
    BuildContext context,
    UnlockedLocalProfile active,
  ) {
    final l10n = context.l10n;
    final isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');
    final termiusOneClick = _termiusOneClickSidebarAction();

    return IosWorkspaceData(
      hosts: _hosts,
      groups: [for (final entry in _groups) entry.group],
      liveHostIds: {
        for (final session in _visibleSessions)
          if (session.console == null &&
              (session.connected.value || session.progress.isLoading))
            session.host.id,
      },
      snippets: [
        for (final snippet in _snippets)
          IosSnippetItem(
            id: snippet.id,
            title: snippet.title,
            preview: snippet.executionMode == SnippetExecutionMode.script
                ? l10n.scriptShell(snippet.shell)
                : l10n.structuredBashCommand,
            tags: snippet.tags,
          ),
      ],
      busy: _busy,
      groupConnecting: false,
      hostListError: _hostListError,
      search: _homeSearch,
      connect: _connectLocalHost,
      edit: _editHost,
      delete: _deleteHost,
      openFiles: (host) {
        if (host.protocol == HostProtocol.ssh) {
          unawaited(_openHostFiles(host));
        }
      },
      copyAddress: (host) {
        final endpoint = formatIosHostEndpoint(host);
        unawaited(Clipboard.setData(ClipboardData(text: endpoint)));
        _showMessage(isZh ? '已复制主机地址' : 'Copied host address');
      },
      hostActions: _hostActions,
      addMenu: [
        [
          for (final protocol in HostProtocol.values)
            WorkspaceAction(
              protocol == HostProtocol.ssh
                  ? 'local_host_add'
                  : 'local_new_${protocol.name}',
              l10n.newTouppercaseHost(protocol.name.toUpperCase()),
              hostProtocolIcon(protocol),
              () => _addHost(protocol),
              enabled: !_busy,
            ),
          ...localShellWorkspaceActions(
            context,
            idPrefix: 'local',
            onLaunch: (launch) => _openConsole(shell: launch),
            enabled: !_busy,
          ),
        ],
        [
          WorkspaceAction(
            'local_host_add_group',
            l10n.newGroup,
            Icons.create_new_folder_rounded,
            _addGroup,
            enabled: !_busy,
          ),
        ],
        [
          if (termiusOneClick != null)
            WorkspaceAction(
              termiusOneClick.id,
              termiusOneClick.label,
              termiusOneClick.icon,
              termiusOneClick.onSelected,
              enabled: termiusOneClick.enabled,
            ),
          WorkspaceAction(
            'local_termius_transfer',
            l10n.r7ImportMenuAction,
            Icons.swap_horiz_rounded,
            _openTermiusTransfer,
            enabled: !_busy && _repository != null,
          ),
          WorkspaceAction(
            'local_profile_archive_import',
            l10n.importLocalEncryptedArchive,
            Icons.upload_file_rounded,
            _importLocalArchive,
            enabled: !_busy,
          ),
          WorkspaceAction(
            'local_profile_archive_export',
            l10n.exportLocalEncryptedArchive,
            Icons.download_rounded,
            _exportLocalArchive,
            enabled: !_busy,
          ),
        ],
      ],
      moreMenu: [
        [
          WorkspaceAction(
            'local_known_hosts_manage',
            l10n.manageSshHostKeyTrust,
            IosIcons.verified,
            _manageLocalKnownHosts,
            enabled: !_busy,
          ),
        ],
        [
          WorkspaceAction(
            'local_profile_lock',
            l10n.lockProfile,
            IosIcons.lock,
            _lockProfile,
            enabled: !_busy,
            destructive: true,
          ),
        ],
      ],
      connectGroup: (group) {
        final localGroup = _groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (localGroup != null) _connectGroup(localGroup);
      },
      editGroup: (group) {
        final localGroup = _groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (localGroup != null) unawaited(_editGroup(localGroup));
      },
      deleteGroup: (group) {
        final localGroup = _groups
            .where((item) => item.id == group.id)
            .firstOrNull;
        if (localGroup != null) unawaited(_deleteGroup(localGroup));
      },
      addGroup: _busy ? null : _addGroup,
      quickConnect: (request) => unawaited(_quickConnect(request)),
      refresh: _iosRefreshWorkspace,
      retryHosts: _busy ? null : _retryHostList,
      addSnippet: _busy ? null : _addSnippet,
      editSnippet: (id) {
        final summary = _snippets.where((item) => item.id == id).firstOrNull;
        if (summary != null) unawaited(_editSnippet(summary));
      },
      deleteSnippet: (id) {
        final summary = _snippets.where((item) => item.id == id).firstOrNull;
        if (summary != null) unawaited(_deleteSnippet(summary));
      },
    );
  }

  /// iPhone 解锁后的一级导航壳：5 Tab + 实时会话胶囊 + Scope 数据下发。
  Widget _iosHomeShell(BuildContext context, UnlockedLocalProfile active) {
    final destinations = <HomeDestination>[
      HomeDestination.hosts,
      HomeDestination.snippets,
      if (_forwardingPageBuilder != null) HomeDestination.forwarding,
      HomeDestination.keychain,
      HomeDestination.settings,
    ];
    final hasAnyLiveTab =
        _visibleSessions.isNotEmpty || _files.entries.isNotEmpty;

    return ListenableBuilder(
      listenable: _iosSessionListenable(),
      builder: (context, _) {
        final liveTabs = _buildIosLiveWorkspaceTabs(context);
        final preferredId = _layout.selectedId;
        final currentId = liveTabs.any((t) => t.id == preferredId)
            ? preferredId
            : liveTabs.firstOrNull?.id;
        final subtitles = _iosSessionSubtitles(context);

        return IosWorkspaceScope(
          data: _buildIosWorkspaceData(context, active),
          child: IosHomeShell(
            key: _iosShellKey,
            destinations: destinations,
            selected: _homeDestinationFor(_workspace),
            onSelect: _selectHomeDestination,
            accessory: !hasAnyLiveTab || liveTabs.isEmpty
                ? null
                : IosLiveSessionPill(
                    sessions: liveTabs,
                    currentId: currentId,
                    subtitles: subtitles,
                    connectingIds: _iosConnectingSessionIds(),
                    onResume: _selectTerminalTab,
                    onShowSwitcher: () => showIosSessionSwitcher(
                      context,
                      sessions: liveTabs,
                      selectedId: currentId,
                      onSelect: _selectTerminalTab,
                      onClose: _closeTerminalTab,
                      subtitles: subtitles,
                      onNewConnection: () =>
                          _selectHomeDestination(HomeDestination.hosts),
                    ),
                  ),
            tabBuilder: (tabContext, destination) => switch (destination) {
              HomeDestination.hosts ||
              HomeDestination.groups => const IosHostsTab(),
              HomeDestination.snippets => const IosSnippetsTab(),
              HomeDestination.forwarding =>
                _forwardingPageBuilder?.call() ?? const IosHostsTab(),
              HomeDestination.keychain => _buildCredentialsIos(
                tabContext,
                active,
              ),
              HomeDestination.settings => _buildPreferences(),
              HomeDestination.logs => _buildSessionLogs(),
            },
          ),
        );
      },
    );
  }

  Widget _buildCredentialsIos(
    BuildContext context,
    UnlockedLocalProfile profile,
  ) {
    List<String> usedBy(String id) => [
      for (final host in _hosts)
        if (host.credentialId == id) context.l10n.quotedHostName(host.name),
      for (final group in _groups)
        if (group.defaultCredentialId == id) context.l10n.groupName(group.name),
    ];
    return KeychainPage(
      entries: [
        for (final credential in _credentials)
          KeychainEntry(
            id: credential.id,
            name: credential.name,
            username: credential.username,
            kind: credential.kind,
            keyFingerprint: credential.fingerprint,
            certificate: credential.certificate,
            usedBy: usedBy(credential.id),
          ),
      ],
      canWrite: true,
      busy: _busy,
      error: _credentialListError,
      onRetry: _busy ? null : _retryCredentialList,
      addButtonKey: const ValueKey('local_credential_add'),
      rowKeyPrefix: 'local_credential_',
      emptyText: context.l10n.noCredentialsYet,
      scopeLabel:
          '${context.l10n.r7NavKeychainSubtitle} · ${context.l10n.profileSubstring(profile.record.profileId.substring(0, 8))}',
      onOpenKnownHosts: _busy ? null : _manageLocalKnownHosts,
      onAdd: _addCredential,
      onEdit: (entry) {
        final summary = _credentials
            .where((item) => item.id == entry.id)
            .firstOrNull;
        if (summary != null) unawaited(_editCredential(summary));
      },
      onDelete: (entry) {
        final summary = _credentials
            .where((item) => item.id == entry.id)
            .firstOrNull;
        if (summary != null) unawaited(_deleteCredential(summary));
      },
    );
  }

  bool _hasSharedTerminalKeybar(_LocalTerminalSession? session) {
    final view = session?.viewKey.currentState;
    return _selectedTabId != 'hosts' &&
        session != null &&
        !session._closed &&
        session.connection != null &&
        !session.isTelnet &&
        session.console == null &&
        session.desktop == null &&
        view != null;
  }

  /// iPhone 双层常驻 Push 容器：Home 与终端/SFTP detail 层丝滑切换且永不卸载终端。
  Widget _iosPushStack(
    BuildContext context, {
    required List<WorkspaceAction> homeActions,
    required _LocalTerminalSession? activeSession,
    required double workspaceHeight,
    required Widget home,
    required Widget terminalChild,
  }) {
    final terminalPalette = terminalColorThemeOf(
      context,
      _savedTerminalThemeChoice,
    );
    final isFileTab = _files.find(_selectedTabId) != null;
    final detailBrightness = isFileTab
        ? Theme.of(context).brightness
        : ThemeData.estimateBrightnessForColor(terminalPalette.background);
    final detailStatusBar = detailBrightness == Brightness.dark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    return IosPushStack(
      showDetail: _selectedTabId != 'hosts',
      detailStatusBarStyle: detailStatusBar,
      onPopGesture: () => _selectTerminalTab('hosts'),
      onShown: () {
        if (!terminalTouchKeyboardOnDemand) {
          activeSession?.viewKey.currentState?.terminalFocus.requestFocus();
        }
      },
      home: home,
      detail: _iosDetailLayer(
        context,
        homeActions: homeActions,
        activeSession: activeSession,
        workspaceHeight: workspaceHeight,
        terminalPalette: terminalPalette,
        isFileTab: isFileTab,
        terminalChild: terminalChild,
      ),
    );
  }

  Widget _iosDetailLayer(
    BuildContext context, {
    required List<WorkspaceAction> homeActions,
    required _LocalTerminalSession? activeSession,
    required double workspaceHeight,
    required TerminalTheme terminalPalette,
    required bool isFileTab,
    required Widget terminalChild,
  }) {
    final media = MediaQuery.of(context);
    final keyboardBottom = media.viewInsets.bottom;
    final hasKeybar = _hasSharedTerminalKeybar(activeSession);
    final sshActions = homeActions
        .where((action) => action.id.startsWith('local_ssh_'))
        .toList(growable: false);

    // 外层 Scaffold 设为 resizeToAvoidBottomInset: false 以保证 Home 浮层不被软键盘顶起；
    // 终端 detail 层显式消费 viewInsets.bottom，并在键盘升起时移除底部安全区留白，使快捷按键栏紧贴软键盘。
    final adjustedMedia = media.copyWith(
      viewInsets: media.viewInsets.copyWith(bottom: 0),
      padding: keyboardBottom > 0
          ? media.padding.copyWith(bottom: 0)
          : media.padding,
    );

    return ColoredBox(
      color: isFileTab
          ? IosColors.of(context).groupedBackground
          : terminalPalette.background,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.only(bottom: keyboardBottom),
        child: MediaQuery(
          data: adjustedMedia,
          child: Column(
            children: [
              ListenableBuilder(
                listenable: _iosSessionListenable(),
                builder: (barContext, _) => IosSessionBar(
                  sessions: _buildIosLiveWorkspaceTabs(barContext),
                  selectedId: _selectedTabId,
                  onBack: () => _selectTerminalTab('hosts'),
                  onSelect: _selectTerminalTab,
                  onClose: _closeTerminalTab,
                  onDisconnect: (id) =>
                      unawaited(_disconnectTerminalSession(id)),
                  onSftp: (id) => unawaited(_openSessionFilesById(id)),
                  onToggleTools: activeSession?.connection != null
                      ? () => activeSession!.viewKey.currentState?.toggleTools()
                      : null,
                  actions: sshActions,
                  activeHealth:
                      activeSession != null && activeSession.connected.value
                      ? sshConnectionHealthOf(activeSession.connection)
                      : null,
                  onProbeHealth:
                      activeSession != null &&
                          activeSession.connected.value &&
                          activeSession.connection != null
                      ? () => unawaited(
                          probeSshConnectionLiveness(activeSession.connection),
                        )
                      : null,
                  transferActive: sshTransferActivity.activeCount > 0,
                  backgroundColor: isFileTab
                      ? null
                      : terminalPalette.background,
                  foregroundColor: isFileTab
                      ? null
                      : terminalPalette.foreground,
                  sessionSubtitles: _iosSessionSubtitles(barContext),
                  onNewConnection: () {
                    _selectTerminalTab('hosts');
                    _selectHomeDestination(HomeDestination.hosts);
                  },
                ),
              ),
              Expanded(
                child: SafeArea(
                  top: false,
                  bottom: !hasKeybar && keyboardBottom == 0,
                  child: terminalChild,
                ),
              ),
              _sharedTerminalKeybar(
                activeSession,
                (workspaceHeight - keyboardBottom).clamp(120.0, workspaceHeight),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- iOS 解锁屏 / 存储恢复屏 -----------------------------------------------

  Widget _buildStorageRecoveryPageIos(BuildContext context) {
    final c = IosColors.of(context);
    return ColoredBox(
      color: c.groupedBackground,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IosIconTile(
                  icon: Icons.storage_rounded,
                  color: c.warning,
                  size: 64,
                  radius: 18,
                  glyphSize: 30,
                ),
                const SizedBox(height: 20),
                Text(
                  context.l10n.aLocalStorageWriteWasInterrupted,
                  key: const ValueKey('local_storage_recovery_message'),
                  textAlign: TextAlign.center,
                  style: IosType.body.copyWith(color: c.label),
                ),
                const SizedBox(height: 24),
                CupertinoButton(
                  key: const ValueKey('local_profile_reload'),
                  color: c.tint,
                  borderRadius: BorderRadius.circular(14),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  onPressed: reloadApplication,
                  child: Text(
                    context.l10n.reloadPage,
                    style: IosType.headline.copyWith(color: c.onTint),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfilesIos(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    final isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');

    if (_profileListError != null) {
      return IosUnlockView(
        title: l10n.localProfile2,
        subtitle: l10n.profileHostAndCredentialRecordsAre,
        requiresPassword: false,
        errorText: _profileListError,
        unlockLabel: l10n.retry,
        onUnlock: _catalogLoading
            ? null
            : () => unawaited(_refreshProfiles(initial: true)),
      );
    }

    // 尚无本地配置库（如首次进入且未启用自动创建，或单测创建流程）：直接展示创建态。
    if (!_catalogLoading && _profiles.isEmpty) {
      return IosUnlockView(
        title: l10n.createNewProfile,
        subtitle: l10n.afterCreatingALocalProfileYou,
        passwordController: _createPassword,
        passwordPlaceholder: l10n.masterPasswordAtLeast12Characters,
        passwordFieldKey: const ValueKey('local_profile_create_password'),
        autofillHints: const [AutofillHints.newPassword],
        unlockLabel: l10n.createAndUnlock,
        unlockButtonKey: const ValueKey('local_profile_create_button'),
        onUnlock: _busy ? null : _createProfile,
        busy: _busy,
        errorText: _pageError,
        secondaryActions: [
          if (!widget.persistentMode)
            IosUnlockAction(
              key: const ValueKey('local_profile_exit'),
              label: l10n.exitLocalProfile,
              icon: Icons.swap_horiz_rounded,
              onPressed: _busy ? null : () => unawaited(_exit()),
            ),
        ],
      );
    }

    final selected = _selectedProfile ?? _profiles.firstOrNull;
    final deviceManaged =
        selected != null && _deviceManagedProfiles.contains(selected.profileId);

    return IosUnlockView(
      loading: _catalogLoading,
      title: l10n.localProfile2,
      subtitle: l10n.profileHostAndCredentialRecordsAre,
      vaultName: selected == null
          ? null
          : l10n.localProfileSubstring2(selected.profileId.substring(0, 8)),
      vaultBadgeKey: selected == null
          ? null
          : ValueKey('local_profile_${selected.profileId}'),
      onTapVaultBadge: selected == null
          ? null
          : () {
              if (_profiles.length <= 1) {
                _iosSetState(() {
                  _selectedProfile = selected;
                  _pageError = null;
                });
                return;
              }
              unawaited(_showIosProfilePickerSheet(context));
            },
      passwordController: _unlockPassword,
      passwordPlaceholder: l10n.localProfileMasterPassword,
      passwordFieldKey: const ValueKey('local_profile_unlock_password'),
      requiresPassword: !deviceManaged,
      passwordlessHint: l10n.thisWorkspaceIsProtectedByThe,
      unlockLabel: deviceManaged
          ? l10n.openLocalWorkspace
          : l10n.unlockLocalProfile,
      unlockButtonKey: const ValueKey('local_profile_unlock_button'),
      onUnlock: _busy || selected == null
          ? null
          : () {
              if (_selectedProfile == null) {
                _iosSetState(() => _selectedProfile = selected);
              }
              unawaited(_unlockSelectedProfile());
            },
      busy: _busy,
      errorText: _pageError,
      bottomChild: _profiles.length <= 1
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 16),
              child: IosListSection(
                margin: EdgeInsets.zero,
                header: l10n.chooseAProfileToUnlock,
                separatorIndent: IosListSection.indentForIcon(),
                children: [
                  for (final profile in _profiles)
                    IosListRow(
                      key: ValueKey('local_profile_${profile.profileId}'),
                      leading: IosIconTile(
                        icon: IosIcons.lock,
                        color: selected?.profileId == profile.profileId
                            ? c.tint
                            : c.gray,
                      ),
                      title: Text(
                        l10n.localProfileSubstring2(
                          profile.profileId.substring(0, 8),
                        ),
                      ),
                      subtitle: Text(
                        l10n.createdFormatdate(_formatDate(profile.createdAt)),
                      ),
                      accessory: selected?.profileId == profile.profileId
                          ? IosRowAccessory.checkmark
                          : IosRowAccessory.none,
                      onTap: _busy
                          ? null
                          : () => _iosSetState(() {
                              _selectedProfile = profile;
                              _unlockPassword.clear();
                              _pageError = null;
                            }),
                    ),
                ],
              ),
            ),
      secondaryActions: [
        IosUnlockAction(
          label: isZh ? '新建配置库' : l10n.createNewProfile,
          icon: IosIcons.add,
          onPressed: _busy ? null : () => _showIosCreateProfileSheet(context),
        ),
        if (!widget.persistentMode)
          IosUnlockAction(
            key: const ValueKey('local_profile_exit'),
            label: l10n.exitLocalProfile,
            icon: Icons.swap_horiz_rounded,
            onPressed: _busy ? null : () => unawaited(_exit()),
          ),
      ],
    );
  }

  Future<void> _showIosProfilePickerSheet(BuildContext context) async {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    await showIosFormSheet<void>(
      context,
      builder: (sheetContext) => IosSheetScaffold(
        title: l10n.chooseAProfileToUnlock,
        children: [
          IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final profile in _profiles)
                IosListRow(
                  leading: IosIconTile(
                    icon: IosIcons.lock,
                    color: _selectedProfile?.profileId == profile.profileId
                        ? c.tint
                        : c.gray,
                  ),
                  title: Text(
                    l10n.localProfileSubstring2(
                      profile.profileId.substring(0, 8),
                    ),
                  ),
                  subtitle: Text(
                    l10n.createdFormatdate(_formatDate(profile.createdAt)),
                  ),
                  accessory: _selectedProfile?.profileId == profile.profileId
                      ? IosRowAccessory.checkmark
                      : IosRowAccessory.none,
                  onTap: () {
                    _iosSetState(() {
                      _selectedProfile = profile;
                      _unlockPassword.clear();
                      _pageError = null;
                    });
                    Navigator.of(sheetContext).pop();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showIosCreateProfileSheet(BuildContext context) async {
    final l10n = context.l10n;
    await showIosFormSheet<void>(
      context,
      builder: (sheetContext) => IosSheetScaffold(
        title: l10n.createNewProfile,
        actionLabel: l10n.createAndUnlock,
        actionKey: const ValueKey('local_profile_create_button'),
        actionBusy: _busy,
        onAction: () async {
          Navigator.of(sheetContext).pop();
          await _createProfile();
        },
        children: [
          IosListSection(
            footer: l10n.afterCreatingALocalProfileYou,
            children: [
              IosTextFieldRow(
                fieldKey: const ValueKey('local_profile_create_password'),
                controller: _createPassword,
                placeholder: l10n.masterPasswordAtLeast12Characters,
                obscureText: true,
                autofocus: true,
                autofillHints: const [AutofillHints.newPassword],
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---- iOS 设置页二级面板与额外分组 -----------------------------------------

  Widget _iosWorkspaceSectionBody(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    return SettingsCards(
      children: [
        const SettingsCard(child: AppLanguageSettings()),
        ScopedWorkspaceModeSettings(onSwitch: _exit),
        IosListSection(
          margin: EdgeInsets.zero,
          children: [
            IosPickerRow<_LocalWorkspace>(
              rowKey: const ValueKey('local_default_section_dropdown'),
              label: l10n.defaultWorkspace,
              value: _defaultSectionChoice,
              enabled: !_busy && _preferenceLoadError == null,
              options: [
                IosPickerOption(
                  value: _LocalWorkspace.hosts,
                  label: l10n.hosts,
                ),
                IosPickerOption(
                  value: _LocalWorkspace.credentials,
                  label: l10n.credentials,
                ),
                IosPickerOption(
                  value: _LocalWorkspace.groups,
                  label: l10n.groups,
                ),
                IosPickerOption(
                  value: _LocalWorkspace.snippets,
                  label: l10n.snippet,
                ),
              ],
              onChanged: (value) {
                _iosSetState(() => _defaultSectionChoice = value);
                unawaited(_saveDefaultSectionPreference());
              },
            ),
          ],
        ),
        if (_preferenceLoadError != null) _iosPreferenceErrorSection(context),
        IosListSection(
          margin: EdgeInsets.zero,
          separatorIndent: IosListSection.indentForIcon(),
          children: [
            IosListRow(
              key: const ValueKey('local_profile_credentials_toggle'),
              leading: IosIconTile(
                icon: IosIcons.keychain,
                color: c.yellow,
                glyphColor: Colors.black,
              ),
              title: Text(l10n.legacySharedCredentials),
              subtitle: Text(l10n.passwordsAndKeysForNewHosts),
              accessory: IosRowAccessory.chevron,
              onTap: () => _iosSetState(
                () => _workspace = _LocalWorkspace.credentials,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _iosAppearanceSectionBody(BuildContext context) {
    final l10n = context.l10n;
    final sizes = VaultPreferenceRecord.supportedTerminalFontSizes.toList()
      ..sort();
    return SettingsCards(
      children: [
        const SettingsCard(child: AppThemeSettings()),
        const SettingsCard(child: WallpaperSettings()),
        if (_preferenceLoadError != null) _iosPreferenceErrorSection(context),
        IosListSection(
          margin: EdgeInsets.zero,
          children: [
            IosPickerRow<int>(
              rowKey: const ValueKey('local_terminal_font_size_dropdown'),
              label: l10n.terminalFontSize,
              value: _terminalFontSizeChoice,
              enabled: !_busy && _preferenceLoadError == null,
              options: [
                for (final size in sizes)
                  IosPickerOption<int>(value: size, label: '$size pt'),
              ],
              onChanged: (size) {
                _iosSetState(() => _terminalFontSizeChoice = size);
                unawaited(_saveTerminalFontSizePreference());
              },
            ),
          ],
        ),
        SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.terminalTheme,
                style: IosType.headline.copyWith(
                  color: IosColors.of(context).label,
                ),
              ),
              const SizedBox(height: 10),
              TerminalSyncedThemeSelector(
                key: const ValueKey('local_terminal_theme_dropdown'),
                selected: _terminalThemeChoice,
                persisted: _savedTerminalThemeChoice,
                onSelected: _busy || _preferenceLoadError != null
                    ? null
                    : (value) {
                        _iosSetState(() => _terminalThemeChoice = value);
                        unawaited(_saveTerminalThemePreference());
                      },
              ),
            ],
          ),
        ),
        SettingsCard(
          child: TerminalPaletteGallery(synced: _savedTerminalThemeChoice),
        ),
      ],
    );
  }

  Widget _iosPreferenceErrorSection(BuildContext context) {
    final c = IosColors.of(context);
    return IosListSection(
      margin: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(IosMetrics.rowPaddingH),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _preferenceLoadError!,
              key: const ValueKey('local_preference_load_error'),
              style: IosType.footnote.copyWith(color: c.warning),
            ),
          ),
        ),
        IosListActionRow(
          key: const ValueKey('local_preference_retry'),
          label: context.l10n.retryReading,
          icon: Icons.refresh_rounded,
          onTap: _busy ? null : _retryDefaultSectionPreference,
        ),
      ],
    );
  }

  List<SettingsSection> _iosExtraSettingsSections(BuildContext context) {
    if (!isIosPhone(context)) return const [];
    final l10n = context.l10n;
    final c = IosColors.of(context);
    final isZh = Localizations.localeOf(
      context,
    ).languageCode.toLowerCase().startsWith('zh');

    return [
      SettingsSection(
        id: 'logs',
        title: l10n.r7NavLogs,
        icon: Icons.receipt_long_rounded,
        description: '',
        iosTint: c.orange,
        iosFullPage: true,
        iosValue: (_) {
          final count = _sessionLogs?.entries.length ?? 0;
          return count > 0 ? '$count' : '';
        },
        builder: (sectionContext) {
          final book = _sessionLogs;
          if (book == null) {
            return IosLargeTitlePage(
              title: l10n.r7NavLogs,
              largeTitle: false,
              showBackButton: true,
              backLabel: l10n.settings,
              slivers: const [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: CupertinoActivityIndicator(radius: 14)),
                ),
              ],
            );
          }
          return SessionLogsPage(book: book, backLabel: l10n.settings);
        },
      ),
      SettingsSection(
        id: 'data',
        title: isZh ? '数据与导入导出' : 'Data & Transfer',
        icon: Icons.import_export_rounded,
        description: isZh
            ? '导入或导出加密本地配置库，或从 Termius 迁移主机与凭据。'
            : 'Import or export encrypted local archives, or migrate from Termius.',
        iosTint: c.indigo,
        builder: _iosDataTransferSectionBody,
      ),
      SettingsSection(
        id: 'lock-profile',
        title: l10n.lockProfile,
        icon: IosIcons.lock,
        description: '',
        iosTint: c.red,
        iosDestructive: true,
        iosOnTap: _busy ? null : () => unawaited(_lockProfile()),
        builder: (_) => const SizedBox.shrink(),
      ),
    ];
  }

  Widget _iosDataTransferSectionBody(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    final termiusOneClick = _termiusOneClickSidebarAction();
    return SettingsCards(
      children: [
        IosListSection(
          margin: EdgeInsets.zero,
          separatorIndent: IosListSection.indentForIcon(),
          children: [
            if (termiusOneClick != null)
              IosListRow(
                leading: IosIconTile(icon: IosIcons.bolt, color: c.orange),
                title: Text(termiusOneClick.label),
                enabled: termiusOneClick.enabled,
                accessory: IosRowAccessory.chevron,
                onTap: termiusOneClick.enabled
                    ? termiusOneClick.onSelected
                    : null,
              ),
            IosListRow(
              leading: IosIconTile(icon: IosIcons.forwarding, color: c.indigo),
              title: Text(l10n.r7ImportMenuAction),
              enabled: !_busy && _repository != null,
              accessory: IosRowAccessory.chevron,
              onTap: !_busy && _repository != null
                  ? _openTermiusTransfer
                  : null,
            ),
            IosListRow(
              leading: IosIconTile(
                icon: Icons.upload_file_rounded,
                color: c.blue,
              ),
              title: Text(l10n.importLocalEncryptedArchive),
              enabled: !_busy,
              accessory: IosRowAccessory.chevron,
              onTap: _busy ? null : _importLocalArchive,
            ),
            IosListRow(
              leading: IosIconTile(
                icon: Icons.download_rounded,
                color: c.teal,
              ),
              title: Text(l10n.exportLocalEncryptedArchive),
              enabled: !_busy,
              accessory: IosRowAccessory.chevron,
              onTap: _busy ? null : _exportLocalArchive,
            ),
          ],
        ),
        IosListSection(
          margin: EdgeInsets.zero,
          separatorIndent: IosListSection.indentForIcon(),
          children: [
            IosListRow(
              leading: IosIconTile(icon: IosIcons.verified, color: c.green),
              title: Text(l10n.manageSshHostKeyTrust),
              enabled: !_busy,
              accessory: IosRowAccessory.chevron,
              onTap: _busy ? null : _manageLocalKnownHosts,
            ),
          ],
        ),
      ],
    );
  }

  // ---- iOS 已知主机管理 Sheet ------------------------------------------------

  Future<void> _manageLocalKnownHostsIos() async {
    final repository = _repository;
    if (repository == null) return;
    final generation = _beginOperation();
    if (generation < 0) return;
    try {
      final records = await repository.listKnownHosts();
      final candidates = await repository.listImportedKnownHostCandidates();
      if (!_isCurrentOperation(generation) || !mounted) return;
      await showIosFormSheet<void>(
        context,
        builder: (_) => _IosLocalKnownHostsSheet(
          repository: repository,
          initialRecords: records,
          initialCandidates: candidates,
        ),
      );
    } finally {
      _finishOperation(generation);
    }
  }
}

// ============================================================================
// 本地加密归档口令 Sheet（iOS Phone）
// ============================================================================

class _IosLocalArchivePasswordSheet extends StatefulWidget {
  const _IosLocalArchivePasswordSheet({
    required this.confirm,
    required this.creating,
  });

  final bool confirm;
  final bool creating;

  @override
  State<_IosLocalArchivePasswordSheet> createState() =>
      _IosLocalArchivePasswordSheetState();
}

class _IosLocalArchivePasswordSheetState
    extends State<_IosLocalArchivePasswordSheet> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _continue() {
    final value = _password.text;
    if (value.length > LocalProfileArchiveCodec.maxPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseCanBe);
      return;
    }
    final passwordBytes = utf8.encode(value);
    final passwordLength = passwordBytes.length;
    passwordBytes.fillRange(0, passwordBytes.length, 0);
    if (passwordLength > LocalProfileArchiveCodec.maxPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseCanBe);
      return;
    }
    if (passwordLength < LocalProfileArchiveCodec.minPasswordUtf8Bytes) {
      setState(() => _error = context.l10n.theLocalArchivePassphraseMustBe);
      return;
    }
    if (widget.confirm && value != _confirmation.text) {
      setState(() => _error = context.l10n.theLocalArchivePassphrasesDontMatch);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return IosSheetScaffold(
      title: widget.creating
          ? l10n.setLocalArchivePassphrase
          : l10n.enterLocalArchivePassphrase,
      actionLabel: l10n.continueLabel2,
      actionKey: const ValueKey('local_archive_password_continue'),
      onAction: _continue,
      isDirty: () =>
          _password.text.isNotEmpty || _confirmation.text.isNotEmpty,
      children: [
        IosListSection(
          footer: l10n.thisPassphraseIsSeparateFromThe,
          children: [
            IosTextFieldRow(
              fieldKey: const ValueKey('local_archive_password'),
              controller: _password,
              placeholder: l10n.localArchivePassphrase,
              obscureText: true,
              autofocus: true,
              errorText: !widget.confirm ? _error : null,
            ),
            if (widget.confirm)
              IosTextFieldRow(
                fieldKey: const ValueKey('local_archive_password_confirm'),
                controller: _confirmation,
                placeholder: l10n.confirmLocalArchivePassphrase,
                obscureText: true,
                errorText: _error,
              ),
          ],
        ),
      ],
    );
  }
}

// ============================================================================
// 本地分组新建/编辑 Sheet（iOS Phone）
// ============================================================================

class _IosLocalGroupEditorSheet extends StatefulWidget {
  const _IosLocalGroupEditorSheet({
    required this.groups,
    required this.credentials,
    this.existing,
  });

  final List<LocalGroupRecord> groups;
  final List<LocalCredentialSummary> credentials;
  final GroupRecord? existing;

  @override
  State<_IosLocalGroupEditorSheet> createState() =>
      _IosLocalGroupEditorSheetState();
}

class _IosLocalGroupEditorSheetState extends State<_IosLocalGroupEditorSheet> {
  static const _palette = <int>[
    0,
    0x4FC3F7,
    0x4DB6AC,
    0x81C784,
    0xFFD54F,
    0xFF8A65,
    0xBA68C8,
  ];

  final _uuid = const Uuid();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _parentId = widget.existing?.parentId ?? '';
  late String _defaultCredentialId = widget.existing?.defaultCredentialId ?? '';
  late int _color = widget.existing?.color ?? 0;
  String? _error;

  bool get _isDirty =>
      _name.text != (widget.existing?.name ?? '') ||
      _parentId != (widget.existing?.parentId ?? '') ||
      _defaultCredentialId != (widget.existing?.defaultCredentialId ?? '') ||
      _color != (widget.existing?.color ?? 0);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool _wouldCreateCycle(String candidateParentId) {
    final existingId = widget.existing?.id;
    if (existingId == null) return false;
    if (candidateParentId == existingId) return true;
    final byId = {for (final group in widget.groups) group.id: group};
    var cursor = byId[candidateParentId]?.parentId;
    final visited = <String>{candidateParentId};
    while (cursor != null && visited.add(cursor)) {
      if (cursor == existingId) return true;
      cursor = byId[cursor]?.parentId;
    }
    return false;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = context.l10n.enterAGroupName);
      return;
    }
    if (_parentId.isNotEmpty && _wouldCreateCycle(_parentId)) {
      setState(() => _error = context.l10n.aGroupCantBeMovedInto);
      return;
    }
    Navigator.pop(
      context,
      GroupRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        name: name,
        color: _color,
        parentId: _parentId.isEmpty ? null : _parentId,
        defaultCredentialId: _defaultCredentialId.isEmpty
            ? null
            : _defaultCredentialId,
        manifest: widget.existing?.manifest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    final colors = {..._palette, _color}.toList()..sort();
    final parents =
        widget.groups.where((group) => !_wouldCreateCycle(group.id)).toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    return IosSheetScaffold(
      title: widget.existing == null
          ? l10n.addLocalGroup
          : l10n.editLocalGroup,
      cancelKey: const ValueKey('local_group_cancel'),
      actionLabel: l10n.saveGroup,
      actionKey: const ValueKey('local_group_save'),
      onAction: _save,
      isDirty: () => _isDirty,
      children: [
        IosListSection(
          footer: l10n.whenAHostDoesntSelectA,
          children: [
            IosTextFieldRow(
              label: l10n.groupName2,
              fieldKey: const ValueKey('local_group_name'),
              controller: _name,
              placeholder: l10n.groupName2,
              autofocus: widget.existing == null,
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            IosPickerRow<String>(
              rowKey: const ValueKey('local_group_parent'),
              label: l10n.parentGroup,
              value: _parentId,
              options: [
                IosPickerOption(value: '', label: l10n.topLevelGroup),
                for (final group in parents)
                  IosPickerOption(value: group.id, label: group.name),
                if (_parentId.isNotEmpty &&
                    !parents.any((group) => group.id == _parentId))
                  IosPickerOption(
                    value: _parentId,
                    label: l10n.previousParentUnavailable,
                  ),
              ],
              onChanged: (value) => setState(() => _parentId = value),
            ),
            IosPickerRow<String>(
              rowKey: const ValueKey('local_group_default_credential'),
              label: l10n.defaultCredential,
              value: _defaultCredentialId,
              options: [
                IosPickerOption(value: '', label: l10n.noDefaultCredential),
                for (final credential in widget.credentials)
                  IosPickerOption(
                    value: credential.id,
                    label: credential.name,
                    subtitle:
                        '${credential.username} · ${credential.kind == AuthKind.password ? l10n.password2 : l10n.sshPrivateKey}',
                  ),
                if (_defaultCredentialId.isNotEmpty &&
                    !widget.credentials.any(
                      (c) => c.id == _defaultCredentialId,
                    ))
                  IosPickerOption(
                    value: _defaultCredentialId,
                    label: l10n.previousDefaultCredentialUnavailable,
                  ),
              ],
              onChanged: (value) =>
                  setState(() => _defaultCredentialId = value),
            ),
            IosPickerRow<int>(
              rowKey: const ValueKey('local_group_color'),
              label: l10n.color,
              value: _color,
              options: [
                for (final color in colors)
                  IosPickerOption(
                    value: color,
                    label: color == 0
                        ? l10n.defaultLabel
                        : '#${color.toRadixString(16).toUpperCase()}',
                  ),
              ],
              onChanged: (value) => setState(() => _color = value),
            ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.sectionHeaderInset,
            ),
            child: Text(
              _error!,
              key: const ValueKey('local_group_editor_error'),
              style: IosType.footnote.copyWith(color: c.destructive),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// 本地片段新建/编辑 Sheet（iOS Phone）
// ============================================================================

class _IosLocalSnippetEditorSheet extends StatefulWidget {
  const _IosLocalSnippetEditorSheet({
    required this.credentials,
    this.existing,
  });

  final SnippetRecord? existing;
  final List<LocalCredentialSummary> credentials;

  @override
  State<_IosLocalSnippetEditorSheet> createState() =>
      _IosLocalSnippetEditorSheetState();
}

class _IosLocalSnippetEditorSheetState
    extends State<_IosLocalSnippetEditorSheet> {
  final _uuid = const Uuid();
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final TextEditingController _body = TextEditingController(
    text: widget.existing?.body ?? '',
  );
  late final TextEditingController _tags = TextEditingController(
    text: widget.existing?.tags.join(', ') ?? '',
  );
  late final TextEditingController _program = TextEditingController(
    text: widget.existing?.program ?? '',
  );
  late final TextEditingController _parameters = TextEditingController(
    text: jsonEncode(
      widget.existing?.parameters.map((item) => item.toJson()).toList() ??
          const [],
    ),
  );
  late final TextEditingController _arguments = TextEditingController(
    text: jsonEncode(
      widget.existing?.arguments.map((item) => item.toJson()).toList() ??
          const [],
    ),
  );
  late SnippetExecutionMode _mode =
      widget.existing?.executionMode ?? SnippetExecutionMode.script;
  late String _shell = widget.existing?.shell ?? 'bash';
  String? _error;

  bool get _isDirty =>
      _title.text != (widget.existing?.title ?? '') ||
      _body.text != (widget.existing?.body ?? '') ||
      _tags.text != (widget.existing?.tags.join(', ') ?? '') ||
      _program.text != (widget.existing?.program ?? '') ||
      _mode != (widget.existing?.executionMode ?? SnippetExecutionMode.script) ||
      _shell != (widget.existing?.shell ?? 'bash');

  @override
  void dispose() {
    _body.clear();
    _parameters.clear();
    _arguments.clear();
    _title.dispose();
    _body.dispose();
    _tags.dispose();
    _program.dispose();
    _parameters.dispose();
    _arguments.dispose();
    super.dispose();
  }

  List<Object?> _jsonArray(TextEditingController controller, String label) {
    final decoded = jsonDecode(controller.text);
    if (decoded is! List) {
      throw FormatException('$label must be a JSON array.');
    }
    return decoded.cast<Object?>();
  }

  void _save() {
    try {
      final title = _title.text.trim();
      if (title.isEmpty) throw FormatException(context.l10n.enterASnippetTitle);
      final parameters = _mode == SnippetExecutionMode.script
          ? const <SnippetParameter>[]
          : _jsonArray(
              _parameters,
              context.l10n.parameterDefinitions,
            ).map(SnippetParameter.fromJson).toList(growable: false);
      final arguments = _mode == SnippetExecutionMode.script
          ? const <SnippetArgument>[]
          : _jsonArray(
              _arguments,
              context.l10n.argumentList,
            ).map(SnippetArgument.fromJson).toList(growable: false);
      for (final parameter in parameters) {
        if (parameter.type != SnippetParameterType.credentialSecret) continue;
        final credential = widget.credentials
            .where((item) => item.id == parameter.credentialId)
            .firstOrNull;
        if (credential == null || credential.kind != AuthKind.password) {
          throw FormatException(
            context.l10n.credentialParameterNameMustReferenceA(parameter.name),
          );
        }
      }
      final candidate = SnippetRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        title: title,
        body: _mode == SnippetExecutionMode.script ? _body.text : '',
        shell: _shell,
        executionMode: _mode,
        program: _mode == SnippetExecutionMode.script ? '' : _program.text,
        parameters: parameters,
        arguments: arguments,
        tags: _tags.text
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .toList(growable: false),
        manifest: widget.existing?.manifest,
      );
      validateSnippetDefinition(candidate);
      if (_mode == SnippetExecutionMode.script &&
          candidate.body.trim().isEmpty) {
        throw FormatException(context.l10n.enterTheScriptBody);
      }
      Navigator.pop(context, candidate);
    } on Object catch (error) {
      setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    return IosSheetScaffold(
      title: widget.existing == null
          ? l10n.addLocalSnippet
          : l10n.editLocalSnippet,
      cancelKey: const ValueKey('local_snippet_cancel'),
      actionLabel: l10n.saveEncryptedSnippet,
      actionKey: const ValueKey('local_snippet_save'),
      onAction: _save,
      isDirty: () => _isDirty,
      children: [
        IosListSection(
          children: [
            IosTextFieldRow(
              label: l10n.snippetTitle2,
              fieldKey: const ValueKey('local_snippet_title'),
              controller: _title,
              placeholder: l10n.snippetTitle2,
              autofocus: widget.existing == null,
            ),
            IosSegmentedRow<SnippetExecutionMode>(
              controlKey: const ValueKey('local_snippet_mode'),
              label: l10n.executionType,
              value: _mode,
              segments: {
                SnippetExecutionMode.script: l10n.script,
                SnippetExecutionMode.bashCommand: l10n.structuredBashCommand,
              },
              onChanged: (value) => setState(() {
                _mode = value;
                if (value == SnippetExecutionMode.bashCommand) {
                  _shell = 'bash';
                }
                _error = null;
              }),
            ),
            if (_mode == SnippetExecutionMode.script)
              IosPickerRow<String>(
                rowKey: const ValueKey('local_snippet_shell'),
                label: l10n.shellLabel,
                value: _shell,
                options: [
                  const IosPickerOption(value: 'bash', label: 'Bash'),
                  const IosPickerOption(
                    value: 'powershell',
                    label: 'PowerShell',
                  ),
                  if (_shell != 'bash' && _shell != 'powershell')
                    IosPickerOption(
                      value: _shell,
                      label: l10n.existingShellLabelShell(_shell),
                    ),
                ],
                onChanged: (value) => setState(() => _shell = value),
              ),
            IosTextFieldRow(
              label: l10n.tagsCommaSeparated,
              fieldKey: const ValueKey('local_snippet_tags'),
              controller: _tags,
              placeholder: 'prod, deploy',
            ),
          ],
        ),
        if (_mode == SnippetExecutionMode.script)
          IosListSection(
            header: l10n.scriptBody,
            children: [
              IosTextFieldRow(
                fieldKey: const ValueKey('local_snippet_body'),
                controller: _body,
                placeholder: '#!/usr/bin/env bash',
                mono: true,
                minLines: 6,
                maxLines: 12,
              ),
            ],
          )
        else
          IosListSection(
            footer: l10n.textParametersAndPasswordCredentialReferences,
            children: [
              IosTextFieldRow(
                label: l10n.program,
                fieldKey: const ValueKey('local_snippet_program'),
                controller: _program,
                mono: true,
              ),
              IosTextFieldRow(
                label: l10n.parameterDefinitionsJsonArray,
                fieldKey: const ValueKey('local_snippet_parameters'),
                controller: _parameters,
                mono: true,
                minLines: 3,
                maxLines: 6,
              ),
              IosTextFieldRow(
                label: l10n.argumentsJsonArray,
                fieldKey: const ValueKey('local_snippet_arguments'),
                controller: _arguments,
                mono: true,
                minLines: 3,
                maxLines: 6,
              ),
            ],
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.sectionHeaderInset,
            ),
            child: Text(
              _error!,
              key: const ValueKey('local_snippet_editor_error'),
              style: IosType.footnote.copyWith(color: c.destructive),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// 本地凭据新建/编辑 Sheet（iOS Phone）
// ============================================================================

class _IosLocalCredentialEditorSheet extends StatefulWidget {
  const _IosLocalCredentialEditorSheet({this.existing});

  final CredentialRecord? existing;

  @override
  State<_IosLocalCredentialEditorSheet> createState() =>
      _IosLocalCredentialEditorSheetState();
}

class _IosLocalCredentialEditorSheetState
    extends State<_IosLocalCredentialEditorSheet> {
  final _uuid = const Uuid();
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _username = TextEditingController(
    text: widget.existing?.username ?? '',
  );
  final _secret = TextEditingController();
  final _passphrase = TextEditingController();
  late final TextEditingController _certificate = TextEditingController(
    text: widget.existing?.certificate ?? '',
  );
  late AuthKind _kind = widget.existing?.kind ?? AuthKind.password;
  String? _error;

  bool get _isDirty =>
      _name.text != (widget.existing?.name ?? '') ||
      _username.text != (widget.existing?.username ?? '') ||
      _secret.text.isNotEmpty ||
      _passphrase.text.isNotEmpty ||
      _certificate.text != (widget.existing?.certificate ?? '') ||
      _kind != (widget.existing?.kind ?? AuthKind.password);

  @override
  void dispose() {
    _secret.clear();
    _passphrase.clear();
    _certificate.dispose();
    _name.dispose();
    _username.dispose();
    _secret.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    final username = _username.text.trim();
    final secret = _secret.text.isEmpty ? null : _secret.text;
    final passphrase = _passphrase.text.isEmpty ? null : _passphrase.text;
    if (name.isEmpty || username.isEmpty) {
      setState(() => _error = context.l10n.enterACredentialNameAndUser);
      return;
    }
    if ((_kind == AuthKind.password || _kind == AuthKind.privateKey) &&
        secret == null &&
        (widget.existing == null || widget.existing!.kind != _kind)) {
      setState(
        () => _error = _kind == AuthKind.password
            ? context.l10n.enterAPassword
            : context.l10n.enterTheSshPrivateKey,
      );
      return;
    }
    KeychainKeyCheck? keyCheck;
    if (_kind == AuthKind.privateKey) {
      final sameKind = widget.existing?.kind == AuthKind.privateKey;
      final effectiveKey =
          secret ?? (sameKind ? widget.existing?.privateKey : null);
      final effectivePassphrase =
          passphrase ?? (sameKind ? widget.existing?.passphrase : null);
      if (effectiveKey != null) {
        keyCheck = checkKeychainKey(
          privateKey: effectiveKey,
          passphrase: effectivePassphrase,
          certificateText: _certificate.text,
        );
        if (keyCheck.error != null) {
          setState(() => _error = keyCheck!.error);
          return;
        }
      }
    }
    Navigator.pop(
      context,
      CredentialRecord(
        id: widget.existing?.id ?? _uuid.v4(),
        name: name,
        username: username,
        kind: _kind,
        secret: _kind == AuthKind.password ? secret : null,
        privateKey: _kind == AuthKind.privateKey ? secret : null,
        passphrase: _kind == AuthKind.privateKey ? passphrase : null,
        fingerprint:
            keyCheck?.fingerprint ??
            (_kind == AuthKind.password ? null : widget.existing?.fingerprint),
        certificate: _kind == AuthKind.privateKey
            ? keyCheck?.certificate
            : null,
        manifest: widget.existing?.manifest,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    return IosSheetScaffold(
      title: widget.existing == null
          ? l10n.addLocalCredential
          : l10n.editLocalCredential,
      cancelKey: const ValueKey('local_credential_cancel'),
      actionLabel: l10n.saveEncryptedCredential,
      actionKey: const ValueKey('local_credential_save'),
      onAction: _save,
      isDirty: () => _isDirty,
      children: [
        IosListSection(
          children: [
            IosTextFieldRow(
              label: l10n.credentialName,
              fieldKey: const ValueKey('local_credential_name'),
              controller: _name,
              placeholder: l10n.credentialName,
              autofocus: widget.existing == null,
            ),
            IosTextFieldRow(
              label: l10n.userName,
              fieldKey: const ValueKey('local_credential_username'),
              controller: _username,
              placeholder: 'root',
            ),
            IosSegmentedRow<AuthKind>(
              controlKey: const ValueKey('local_credential_kind'),
              label: l10n.authenticationType,
              value: _kind,
              segments: {
                AuthKind.password: l10n.password2,
                AuthKind.privateKey: l10n.sshPrivateKey,
              },
              onChanged: (value) => setState(() {
                _kind = value;
                _error = null;
              }),
            ),
          ],
        ),
        IosListSection(
          footer: widget.existing == null
              ? null
              : l10n.leaveBlankToKeepTheCurrent,
          children: [
            if (_kind == AuthKind.password)
              IosTextFieldRow(
                label: l10n.password2,
                fieldKey: const ValueKey('local_credential_secret'),
                controller: _secret,
                placeholder: l10n.password2,
                obscureText: true,
              )
            else ...[
              IosTextFieldRow(
                label: l10n.sshPrivateKey,
                fieldKey: const ValueKey('local_credential_private_key'),
                controller: _secret,
                placeholder: '-----BEGIN OPENSSH PRIVATE KEY-----',
                mono: true,
                minLines: 4,
                maxLines: 8,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: KeychainKeyFileButton(
                    onLoaded: (text) => setState(() {
                      _secret.text = text;
                      _error = null;
                    }),
                    onError: (message) => setState(() => _error = message),
                  ),
                ),
              ),
              IosTextFieldRow(
                label: l10n.privateKeyPassphraseOptional,
                fieldKey: const ValueKey('local_credential_passphrase'),
                controller: _passphrase,
                obscureText: true,
              ),
            ],
          ],
        ),
        if (_kind == AuthKind.privateKey)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.sectionMargin,
              0,
              IosMetrics.sectionMargin,
              IosMetrics.sectionSpacing,
            ),
            child: ClipRSuperellipse(
              borderRadius: BorderRadius.circular(IosMetrics.groupRadius),
              child: ColoredBox(
                color: c.cell,
                child: Padding(
                  padding: const EdgeInsets.all(IosMetrics.rowPaddingH),
                  child: KeychainCertificateField(controller: _certificate),
                ),
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.sectionHeaderInset,
            ),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                key: const ValueKey('local_credential_editor_error'),
                style: IosType.footnote.copyWith(color: c.destructive),
              ),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// 本地已知主机（Known Hosts）信任管理 Sheet（iOS Phone）
// ============================================================================

class _IosLocalKnownHostsSheet extends StatefulWidget {
  const _IosLocalKnownHostsSheet({
    required this.repository,
    required this.initialRecords,
    required this.initialCandidates,
  });

  final LocalHostRepository repository;
  final List<KnownHostRecord> initialRecords;
  final List<LocalKnownHostArchiveCandidate> initialCandidates;

  @override
  State<_IosLocalKnownHostsSheet> createState() =>
      _IosLocalKnownHostsSheetState();
}

class _IosLocalKnownHostsSheetState extends State<_IosLocalKnownHostsSheet> {
  late List<KnownHostRecord> _records = widget.initialRecords;
  late List<LocalKnownHostArchiveCandidate> _candidates =
      widget.initialCandidates;
  String? _error;

  Future<void> _reviewCandidate(KnownHostRecord record) async {
    final l10n = context.l10n;
    final confirmed = await showIosConfirmAlert(
      context,
      title: l10n.reviewSshHostKeysFromThe,
      message: l10n.onlyContinueAfterVerifyingTheFingerprint(
        record.host,
        record.port,
        record.algorithm,
        record.fingerprint,
      ),
      confirm: l10n.confirmTrustingThisKey,
      cancel: l10n.cancel,
      confirmKey: ValueKey('local-known-host-confirm-${record.id}'),
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.repository.approveImportedKnownHost(
        candidateId: record.id,
        explicitlyConfirmed: true,
      );
      final updatedRecords = await widget.repository.listKnownHosts();
      final updatedCandidates = await widget.repository
          .listImportedKnownHostCandidates();
      if (!mounted) return;
      setState(() {
        _records = updatedRecords;
        _candidates = updatedCandidates;
        _error = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = l10n.trustReviewFailedTheExistingSsh);
    }
  }

  Future<void> _revokeRecord(KnownHostRecord record) async {
    final l10n = context.l10n;
    final confirmed = await showIosDestructiveConfirm(
      context,
      title: l10n.revokeSshHostKeyTrust,
      message: l10n.afterRevokingThisKeyForHost(record.host, record.port),
      action: l10n.revokeTrust,
      cancel: l10n.cancel,
    );
    if (!confirmed || !mounted) return;
    try {
      await widget.repository.revokeKnownHost(recordId: record.id);
      final updated = await widget.repository.listKnownHosts();
      if (!mounted) return;
      setState(() {
        _records = updated;
        _error = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = l10n.revokingFailedTheTrustStateIs);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = IosColors.of(context);
    return IosSheetScaffold(
      title: l10n.localvaultHostKeyTrust,
      cancelLabel: l10n.close,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              IosMetrics.sectionHeaderInset,
              0,
              IosMetrics.sectionHeaderInset,
              12,
            ),
            child: Text(
              _error!,
              style: IosType.footnote.copyWith(color: c.destructive),
            ),
          ),
        if (_candidates.isEmpty && _records.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 48),
            child: IosEmptyState(
              icon: IosIcons.verified,
              title: l10n.localvaultHostKeyTrust,
              message: l10n.thisLocalvaultHasNoSshHost,
            ),
          ),
        if (_candidates.isNotEmpty)
          IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final candidate in _candidates)
                IosListRow(
                  key: ValueKey(
                    'local-known-host-import-${candidate.record.id}',
                  ),
                  leading: IosIconTile(
                    icon: Icons.rate_review_rounded,
                    color: c.orange,
                  ),
                  title: Text(
                    l10n.hostPortPendingReview(
                      candidate.record.host,
                      candidate.record.port,
                    ),
                  ),
                  subtitle: Text(
                    '${candidate.record.algorithm} · ${candidate.record.fingerprint}',
                  ),
                  monoSubtitle: true,
                  trailing: CupertinoButton(
                    key: ValueKey(
                      'local-known-host-review-${candidate.record.id}',
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 32),
                    onPressed: () => _reviewCandidate(candidate.record),
                    child: Text(
                      l10n.reviewAndTrust,
                      style: IosType.subheadline.copyWith(color: c.tint),
                    ),
                  ),
                ),
            ],
          ),
        if (_records.isNotEmpty)
          IosListSection(
            separatorIndent: IosListSection.indentForIcon(),
            children: [
              for (final record in _records)
                IosSwipeActionCell(
                  trailing: record.state == KnownHostState.trusted
                      ? [
                          IosSwipeAction(
                            label: l10n.revokeTrust,
                            icon: Icons.remove_circle_rounded,
                            color: c.destructive,
                            onTap: () => _revokeRecord(record),
                          ),
                        ]
                      : const [],
                  child: IosListRow(
                    leading: IosIconTile(
                      icon: record.state == KnownHostState.trusted
                          ? IosIcons.verified
                          : Icons.gpp_bad_rounded,
                      color: record.state == KnownHostState.trusted
                          ? c.green
                          : c.gray,
                    ),
                    title: Text('${record.host}:${record.port}'),
                    subtitle: Text(
                      '${record.algorithm} · ${record.fingerprint}',
                    ),
                    monoSubtitle: true,
                    value: record.state == KnownHostState.trusted
                        ? l10n.trusted
                        : l10n.revoked,
                    onTap: record.state == KnownHostState.trusted
                        ? () => _revokeRecord(record)
                        : null,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
