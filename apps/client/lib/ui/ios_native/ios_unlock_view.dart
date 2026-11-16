import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../apple_hig.dart' show AppleHaptics;
import 'ios_glass.dart';
import 'ios_icons.dart';
import 'ios_tokens.dart';

/// [IosUnlockView] 底部的次级轻量操作项（切换配置库、同步、退出登录等）。
@immutable
class IosUnlockAction {
  const IosUnlockAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.destructive = false,
    this.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool destructive;
  final Key? key;
}

/// 纯正 iOS 解锁视图（云工作区锁屏与本地加密配置库解锁页共用）。
///
/// 视觉特征：
/// - 纯 `#000000`（OLED 暗色）/ `#F2F2F7`（亮色）底色，不使用极光渐变背景；
/// - 居中 64pt 连续曲率主题色锁块图标、标题与当前库名胶囊；
/// - 无描边胶囊灰槽密码输入框（显式关闭 SDK 默认 clearButton 避免图标字体方块）；
/// - 圆润主解锁按钮及次级切换/更多入口，完整保留外部传入的 `ValueKey`。
class IosUnlockView extends StatefulWidget {
  const IosUnlockView({
    super.key,
    required this.title,
    this.subtitle,
    this.vaultName,
    this.vaultBadgeKey,
    this.onTapVaultBadge,
    this.passwordController,
    this.passwordPlaceholder,
    this.passwordFieldKey,
    this.autofillHints = const [AutofillHints.password],
    this.requiresPassword = true,
    this.passwordlessHint,
    required this.unlockLabel,
    this.unlockButtonKey,
    required this.onUnlock,
    this.busy = false,
    this.loading = false,
    this.statusLabel,
    this.statusBusy = false,
    this.errorText,
    this.secondaryActions = const [],
    this.bottomChild,
    this.wrapInScaffold = false,
  });

  final String title;
  final String? subtitle;

  /// 当前待解锁的配置库 / Vault 名称徽章。
  final String? vaultName;
  final Key? vaultBadgeKey;
  final VoidCallback? onTapVaultBadge;

  final TextEditingController? passwordController;
  final String? passwordPlaceholder;
  final Key? passwordFieldKey;
  final Iterable<String>? autofillHints;

  /// 为 `false` 时隐藏密码框（例如受设备安全芯片托管的本地配置库），改为显示 [passwordlessHint]。
  final bool requiresPassword;
  final String? passwordlessHint;

  final String unlockLabel;
  final Key? unlockButtonKey;
  final VoidCallback? onUnlock;

  final bool busy;

  /// 初始读取配置库目录时的居中加载态。
  final bool loading;

  /// 实时状态说明（自动开启 `liveRegion` 无障碍播报）。
  final String? statusLabel;
  final bool statusBusy;

  final String? errorText;
  final List<IosUnlockAction> secondaryActions;

  /// 可选底部扩展区（例如本地配置库列表切换或新建配置库表单）。
  final Widget? bottomChild;

  /// 独立全屏页面（如 `LockedWorkspaceScreen`）设为 `true`；嵌在已有 `Scaffold` 内时保持 `false`。
  final bool wrapInScaffold;

  @override
  State<IosUnlockView> createState() => _IosUnlockViewState();
}

class _IosUnlockViewState extends State<IosUnlockView> {
  bool _obscure = true;

  void _submit() {
    if (widget.busy || widget.onUnlock == null) return;
    AppleHaptics.light(context);
    widget.onUnlock!();
  }

  @override
  Widget build(BuildContext context) {
    final c = IosColors.of(context);
    final mq = MediaQuery.of(context);
    final viewBottom = mq.viewInsets.bottom;

    final body = ColoredBox(
      color: c.groupedBackground,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              24,
              20,
              24,
              24 + (widget.wrapInScaffold ? 0 : viewBottom),
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 44).clamp(
                  0.0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 380),
                  child: widget.loading
                      ? const Center(
                          child: CupertinoActivityIndicator(radius: 14),
                        )
                      : _buildContent(context, c),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (!widget.wrapInScaffold) return body;
    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: body,
    );
  }

  Widget _buildContent(BuildContext context, IosColors c) {
    final canSubmit = !widget.busy && widget.onUnlock != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: DecoratedBox(
            decoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              shadows: [
                BoxShadow(
                  color: c.tint.withValues(alpha: c.isDark ? 0.24 : 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: IosIconTile(
              icon: IosIcons.lock,
              color: c.tint,
              glyphColor: c.onTint,
              size: 64,
              radius: 18,
              glyphSize: 30,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          widget.title,
          textAlign: TextAlign.center,
          style: IosType.title2.copyWith(color: c.label),
        ),
        if (widget.vaultName != null && widget.vaultName!.isNotEmpty) ...[
          const SizedBox(height: 10),
          Center(
            child: GestureDetector(
              key: widget.vaultBadgeKey,
              behavior: HitTestBehavior.opaque,
              onTap: widget.busy ? null : widget.onTapVaultBadge,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: c.fill,
                  shape: const StadiumBorder(),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(IosIcons.keychain, size: 14, color: c.tint),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.vaultName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.footnote.copyWith(
                            color: c.label,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (widget.onTapVaultBadge != null) ...[
                        const SizedBox(width: 6),
                        IosUpDownChevron(size: 8, color: c.secondaryLabel),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        if (widget.subtitle != null && widget.subtitle!.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            widget.subtitle!,
            textAlign: TextAlign.center,
            style: IosType.subheadline.copyWith(color: c.secondaryLabel),
          ),
        ],
        if (widget.statusLabel != null && widget.statusLabel!.isNotEmpty) ...[
          const SizedBox(height: 14),
          Semantics(
            container: true,
            liveRegion: true,
            label: widget.statusLabel,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.statusBusy) ...[
                  const CupertinoActivityIndicator(radius: 8),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    widget.statusLabel!,
                    textAlign: TextAlign.center,
                    style: IosType.footnote.copyWith(color: c.secondaryLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (widget.errorText != null && widget.errorText!.isNotEmpty) ...[
          const SizedBox(height: 14),
          DecoratedBox(
            decoration: ShapeDecoration(
              color: c.destructive.withValues(alpha: c.isDark ? 0.16 : 0.10),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Text(
                widget.errorText!,
                textAlign: TextAlign.center,
                style: IosType.footnote.copyWith(color: c.destructive),
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (!widget.requiresPassword && widget.passwordlessHint != null) ...[
          Text(
            widget.passwordlessHint!,
            textAlign: TextAlign.center,
            style: IosType.footnote.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: 16),
        ] else if (widget.requiresPassword &&
            widget.passwordController != null) ...[
          DecoratedBox(
            decoration: ShapeDecoration(
              color: c.fill,
              shape: const StadiumBorder(),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 50),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(18, 4, 8, 4),
                child: Row(
                  children: [
                    Icon(
                      IosIcons.keychain,
                      size: 18,
                      color: c.secondaryLabel,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: CupertinoTextField(
                        key: widget.passwordFieldKey,
                        controller: widget.passwordController,
                        obscureText: _obscure,
                        enabled: !widget.busy,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: widget.autofillHints,
                        textInputAction: TextInputAction.go,
                        clearButtonMode: OverlayVisibilityMode.never,
                        decoration: null,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        placeholder: widget.passwordPlaceholder,
                        placeholderStyle: IosType.body.copyWith(
                          color: c.tertiaryLabel,
                        ),
                        style: IosType.body.copyWith(color: c.label),
                        cursorColor: c.tint,
                        onSubmitted: (_) => _submit(),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.busy
                          ? null
                          : () => setState(() => _obscure = !_obscure),
                      child: SizedBox.square(
                        dimension: 38,
                        child: Icon(
                          _obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 19,
                          color: c.secondaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Semantics(
          button: true,
          enabled: canSubmit,
          child: IosGlassTapScale(
            key: widget.unlockButtonKey,
            pressedScale: 0.97,
            onTap: canSubmit ? _submit : null,
            child: SizedBox(
              height: 50,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: canSubmit ? c.tint : c.fill,
                  shape: const StadiumBorder(),
                ),
                child: Center(
                  child: widget.busy
                      ? CupertinoActivityIndicator(color: c.onTint)
                      : Text(
                          widget.unlockLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IosType.headline.copyWith(
                            color: canSubmit ? c.onTint : c.tertiaryLabel,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
        if (widget.secondaryActions.isNotEmpty) ...[
          const SizedBox(height: 18),
          for (final action in widget.secondaryActions)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Center(
                child: Semantics(
                  button: true,
                  enabled: action.onPressed != null,
                  child: GestureDetector(
                    key: action.key,
                    behavior: HitTestBehavior.opaque,
                    onTap: action.onPressed,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (action.icon != null) ...[
                            Icon(
                              action.icon,
                              size: 17,
                              color: action.onPressed == null
                                  ? c.tertiaryLabel
                                  : (action.destructive
                                        ? c.destructive
                                        : c.tint),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              action.label,
                              style: IosType.subheadline.copyWith(
                                color: action.onPressed == null
                                    ? c.tertiaryLabel
                                    : (action.destructive
                                          ? c.destructive
                                          : c.tint),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
        if (widget.bottomChild != null) ...[
          const SizedBox(height: 24),
          widget.bottomChild!,
        ],
      ],
    );
  }
}
