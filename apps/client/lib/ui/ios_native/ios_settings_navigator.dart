import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../desktop/desktop_keyboard_mode.dart';
import '../../l10n/l10n.dart';
import '../../mcp/mcp_service.dart';
import '../app_theme_mode.dart';
import '../session_logs_page.dart';
import '../settings_scaffold.dart';
import 'ios_icons.dart';
import 'ios_large_title_page.dart';
import 'ios_list.dart';
import 'ios_tokens.dart';

/// iPhone 纯血 iOS 设置导航器：
/// - 一级页：34pt 大标题“设置” + 按逻辑分组的 Inset Grouped 彩色图标导航行；
/// - 二级页：声明式嵌套 `Navigator(pages: [...])` + `CupertinoPage`，
///   父级 `setState` 重建时详情页实时刷新最新状态且不重播 push 转场，
///   同时原生支持 iOS 左边缘右滑交互式返回手势。
class IosSettingsNavigator extends StatefulWidget {
  const IosSettingsNavigator({
    super.key,
    required this.sections,
    required this.openSectionId,
    required this.onOpenSectionChanged,
  });

  final List<SettingsSection> sections;
  final String? openSectionId;
  final ValueChanged<String?> onOpenSectionChanged;

  @override
  State<IosSettingsNavigator> createState() => _IosSettingsNavigatorState();
}

class _IosSettingsNavigatorState extends State<IosSettingsNavigator> {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final HeroController _heroController =
      CupertinoApp.createCupertinoHeroController();

  @override
  void dispose() {
    _heroController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settingsTitle = context.l10n.settings;
    final openId = widget.openSectionId;
    final openSection = openId == null
        ? null
        : widget.sections.where((s) => s.id == openId).firstOrNull;

    return HeroControllerScope(
      controller: _heroController,
      child: Navigator(
        key: _navigatorKey,
        pages: [
          CupertinoPage<void>(
            key: const ValueKey('ios_settings_root'),
            title: settingsTitle,
            child: _IosSettingsRootPage(
              sections: widget.sections,
              onSelectSection: widget.onOpenSectionChanged,
            ),
          ),
          if (openSection != null)
            CupertinoPage<void>(
              key: ValueKey('settings_page_${openSection.id}'),
              title: openSection.title,
              child: _IosSettingsDetailPage(
                key: ValueKey('settings_page_${openSection.id}'),
                section: openSection,
                backLabel: settingsTitle,
                onClose: () => widget.onOpenSectionChanged(null),
              ),
            ),
        ],
        onDidRemovePage: (page) {
          final currentOpenId = widget.openSectionId;
          if (currentOpenId != null &&
              page.key == ValueKey('settings_page_$currentOpenId')) {
            widget.onOpenSectionChanged(null);
          }
        },
      ),
    );
  }
}

class _IosSettingsRootPage extends StatelessWidget {
  const _IosSettingsRootPage({
    required this.sections,
    required this.onSelectSection,
  });

  final List<SettingsSection> sections;
  final ValueChanged<String?> onSelectSection;

  /// 将传入的一维 [SettingsSection] 按 Apple 系统“设置”逻辑节奏归组，
  /// 未命中预设分组的自定义分类保持原有相对顺序归入通用组。
  static List<List<SettingsSection>> _groupSections(
    List<SettingsSection> all,
  ) {
    const bucketOrder = <Set<String>>[
      {'account', 'workspace', 'vaults', 'security', 'trust'},
      {'appearance', 'wallpaper', 'terminal', 'shortcuts', 'remote-desktop'},
      {'mcp', 'notifications', 'logs', 'session-logs', 'session_logs'},
      {'data', 'instance', 'access', 'backup', 'audit'},
      {'about', 'lock', 'lock-profile', 'lock_profile'},
    ];

    final buckets = List<List<SettingsSection>>.generate(
      bucketOrder.length,
      (_) => <SettingsSection>[],
    );
    final custom = <SettingsSection>[];

    for (final section in all) {
      var placed = false;
      for (var i = 0; i < bucketOrder.length; i++) {
        if (bucketOrder[i].contains(section.id)) {
          buckets[i].add(section);
          placed = true;
          break;
        }
      }
      if (!placed) {
        custom.add(section);
      }
    }

    final result = <List<SettingsSection>>[
      if (buckets[0].isNotEmpty) buckets[0],
      if (custom.isNotEmpty) custom,
      for (var i = 1; i < buckets.length; i++)
        if (buckets[i].isNotEmpty) buckets[i],
    ];
    return result;
  }

  static Color _resolveTint(SettingsSection section, IosColors colors) {
    if (section.iosTint != null) return section.iosTint!;
    return switch (section.id) {
      'account' => colors.blue,
      'workspace' => colors.blue,
      'appearance' => colors.blue,
      'wallpaper' => colors.cyan,
      'terminal' => colors.green,
      'remote-desktop' => colors.green,
      'shortcuts' => colors.gray,
      'mcp' => colors.purple,
      'notifications' => colors.red,
      'logs' || 'session-logs' || 'session_logs' => colors.orange,
      'data' => colors.indigo,
      'vaults' => colors.teal,
      'trust' => colors.green,
      'security' => colors.red,
      'lock' || 'lock-profile' || 'lock_profile' => colors.red,
      'instance' => colors.teal,
      'access' => colors.indigo,
      'backup' => colors.green,
      'audit' => colors.orange,
      'about' => colors.gray,
      _ => colors.gray,
    };
  }

  static IconData _resolveRoundedIcon(SettingsSection section) =>
      switch (section.id) {
        'account' => Icons.person_rounded,
        'workspace' => Icons.tune_rounded,
        'appearance' => Icons.palette_rounded,
        'wallpaper' => Icons.wallpaper_rounded,
        'terminal' => Icons.terminal_rounded,
        'remote-desktop' => Icons.desktop_windows_rounded,
        'shortcuts' => Icons.keyboard_rounded,
        'mcp' => Icons.hub_rounded,
        'notifications' => Icons.notifications_rounded,
        'logs' || 'session-logs' || 'session_logs' => Icons.receipt_long_rounded,
        'data' => Icons.swap_vert_circle_rounded,
        'vaults' => Icons.folder_shared_rounded,
        'trust' => Icons.verified_user_rounded,
        'security' => Icons.shield_rounded,
        'lock' || 'lock-profile' || 'lock_profile' => Icons.lock_rounded,
        'instance' => Icons.dns_rounded,
        'access' => Icons.admin_panel_settings_rounded,
        'backup' => Icons.backup_rounded,
        'audit' => Icons.fact_check_rounded,
        'about' => Icons.info_rounded,
        _ => _fallbackRounded(section.icon),
      };

  static IconData _fallbackRounded(IconData original) {
    if (original == Icons.dashboard || original == Icons.dashboard_outlined) {
      return Icons.space_dashboard_rounded;
    }
    if (original == Icons.shield || original == Icons.shield_outlined) {
      return Icons.shield_rounded;
    }
    if (original == Icons.palette || original == Icons.palette_outlined) {
      return Icons.palette_rounded;
    }
    if (original == Icons.keyboard || original == Icons.keyboard_outlined) {
      return Icons.keyboard_rounded;
    }
    if (original == Icons.settings || original == Icons.settings_outlined) {
      return Icons.settings_rounded;
    }
    return original;
  }

  static String? _resolveSummaryValue(
    BuildContext context,
    SettingsSection section,
  ) {
    if (section.iosValue != null) {
      final explicit = section.iosValue!(context).trim();
      return explicit.isEmpty ? null : explicit;
    }
    final l10n = context.l10n;
    return switch (section.id) {
      'appearance' => AppThemeController.instance.preference.label(l10n),
      'workspace' => AppLanguageController.instance.preference.nativeName(l10n),
      'remote-desktop' =>
        DesktopKeyboardController.instance.mode == DesktopKeyboardMode.overlay
            ? l10n.desktopKeyboardOverlay
            : l10n.desktopKeyboardResize,
      'mcp' => McpService.instance.supported
          ? (McpService.instance.running ? 'ON' : l10n.off)
          : null,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groupSections(sections);
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppThemeController.instance,
        AppLanguageController.instance,
        DesktopKeyboardController.instance,
        McpService.instance,
      ]),
      builder: (context, _) {
        final colors = IosColors.of(context);
        return KeyedSubtree(
          key: const ValueKey('ios_settings_category_list'),
          child: IosLargeTitlePage(
            title: context.l10n.settings,
            slivers: [
              for (final group in groups)
                SliverToBoxAdapter(
                  child: IosListSection(
                    separatorIndent: IosListSection.indentForIcon(),
                    margin: const EdgeInsets.fromLTRB(
                      IosMetrics.sectionMargin,
                      0,
                      IosMetrics.sectionMargin,
                      20,
                    ),
                    children: [
                      for (final section in group)
                        IosListRow(
                          key: ValueKey('settings_category_${section.id}'),
                          leading: IosIconTile(
                            icon: _resolveRoundedIcon(section),
                            color: _resolveTint(section, colors),
                          ),
                          title: Text(section.title),
                          destructive: section.iosDestructive,
                          value: _resolveSummaryValue(context, section),
                          accessory: section.iosOnTap != null
                              ? IosRowAccessory.none
                              : IosRowAccessory.chevron,
                          onTap: () {
                            if (section.iosOnTap != null) {
                              section.iosOnTap!();
                            } else {
                              onSelectSection(section.id);
                            }
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _IosSettingsDetailPage extends StatelessWidget {
  const _IosSettingsDetailPage({
    super.key,
    required this.section,
    required this.backLabel,
    required this.onClose,
  });

  final SettingsSection section;
  final String backLabel;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final body = section.builder(context);
    if (section.iosFullPage || body is SessionLogsPage) {
      return body;
    }
    final colors = IosColors.of(context);
    final description = section.description.trim();
    return IosLargeTitlePage(
      title: section.title,
      largeTitle: false,
      leading: IosBackButton(
        key: const ValueKey('ios_settings_back_button'),
        label: backLabel,
        onPressed: () {
          final nav = Navigator.maybeOf(context);
          if (nav != null && nav.canPop()) {
            nav.maybePop();
          } else {
            onClose();
          }
        },
      ),
      slivers: [
        if (description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                IosMetrics.sectionHeaderInset,
                0,
                IosMetrics.sectionHeaderInset,
                12,
              ),
              child: Text(
                description,
                style: IosType.footnote.copyWith(color: colors.secondaryLabel),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IosMetrics.sectionMargin,
            ),
            child: body,
          ),
        ),
      ],
    );
  }
}
