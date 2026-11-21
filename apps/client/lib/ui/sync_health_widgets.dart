import 'dart:async';

import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';

/// Building blocks of the Sync health page (`/sync`).
///
/// The page leads with one status summary ([SyncHealthHero]), then a row of
/// counters ([SyncMetricGrid]), then conflicts and the technical detail. The
/// widgets only lay out what they are given; every label and value comes
/// from the page, so nothing here depends on the sync state machine.

/// Radius shared by the page's own surfaces; one step rounder than a Card so
/// the summary reads as the page's lead element.
double _radius(BuildContext context) => AppDensity.of(context).radiusLg + 4;

/// One label/value fact shown under the summary title.
class SyncHeroFact {
  const SyncHeroFact({
    required this.icon,
    required this.label,
    required this.value,
    this.tooltip,
    this.tone,
  });

  final IconData icon;
  final String label;
  final String value;

  /// Colour of [value]; the text colour when null.
  final Color? tone;

  /// Longer form of [value] (for example the absolute time of a relative
  /// one), shown on hover and read by screen readers.
  final String? tooltip;
}

/// The page's lead card: what state sync is in, what that means, and the
/// actions that change it.
class SyncHealthHero extends StatelessWidget {
  const SyncHealthHero({
    required this.icon,
    required this.tone,
    required this.overline,
    required this.title,
    required this.description,
    required this.facts,
    required this.actions,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final Color tone;
  final String overline;
  final String title;
  final String description;
  final List<SyncHeroFact> facts;
  final List<Widget> actions;

  /// Shows a progress ring around the status icon.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(_radius(context));
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 640;
        final badgeSize = narrow ? 46.0 : 56.0;
        final badge = SizedBox(
          width: badgeSize,
          height: badgeSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: .14),
                  shape: BoxShape.circle,
                  border: Border.all(color: tone.withValues(alpha: .28)),
                ),
              ),
              if (busy)
                Positioned.fill(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tone,
                    backgroundColor: Colors.transparent,
                  ),
                ),
              Icon(icon, color: tone, size: narrow ? 22 : 26),
            ],
          ),
        );
        final text = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              overline,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(
                fontSize: narrow ? 20 : 24,
                height: 1.2,
                fontWeight: FontWeight.w700,
                letterSpacing: -.4,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              description,
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: palette.text.withValues(alpha: .82),
              ),
            ),
          ],
        );
        final factWrap = facts.isEmpty
            ? null
            : Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [for (final fact in facts) _HeroFactChip(fact: fact)],
              );
        // Beside the text the buttons stack in one column of equal width;
        // below it (narrow) each one takes the full width.
        final actionColumn = actions.isEmpty
            ? null
            : IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      actions[i],
                    ],
                  ],
                ),
              );
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: palette.surface,
            border: Border.all(color: tone.withValues(alpha: .32)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(tone.withValues(alpha: .12), palette.surface),
                palette.surface,
              ],
              stops: const [0, .75],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.all(narrow ? 16 : 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: narrow
                      ? CrossAxisAlignment.start
                      : CrossAxisAlignment.center,
                  children: [
                    badge,
                    SizedBox(width: narrow ? 14 : 18),
                    Expanded(child: text),
                    if (!narrow && actionColumn != null) ...[
                      const SizedBox(width: 18),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxWidth * .4,
                        ),
                        child: actionColumn,
                      ),
                    ],
                  ],
                ),
                if (factWrap != null) ...[
                  SizedBox(height: narrow ? 14 : 18),
                  Divider(height: 1, color: palette.line),
                  SizedBox(height: narrow ? 12 : 14),
                  factWrap,
                ],
                if (narrow && actions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    actions[i],
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeroFactChip extends StatelessWidget {
  const _HeroFactChip({required this.fact});
  final SyncHeroFact fact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.surfaceRaised.withValues(alpha: .7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.line.withValues(alpha: .7)),
      ),
      // A Wrap, not a Row: a long label (Russian) moves the value to a
      // second line instead of running out of the chip.
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(fact.icon, size: 14, color: palette.muted),
          Text(
            fact.label,
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
          Text(
            fact.value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: fact.tone ?? palette.text,
            ),
          ),
        ],
      ),
    );
    final tooltip = fact.tooltip;
    if (tooltip == null || tooltip.isEmpty) return chip;
    return Tooltip(message: tooltip, child: chip);
  }
}

/// One counter on the page: an icon, what is counted, and the count.
class SyncMetricTile extends StatelessWidget {
  const SyncMetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.tone,
    this.caption,
    this.textual = false,
    this.showIcon = true,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? caption;
  final Color tone;

  /// [value] is a word rather than a count: smaller, and it may wrap.
  final bool textual;

  /// [SyncMetricGrid] turns the icon off when a tile is so narrow (about
  /// 170 px) that it would squeeze the label into broken words.
  final bool showIcon;

  SyncMetricTile _withIcon(bool show) => show == showIcon
      ? this
      : SyncMetricTile(
          icon: icon,
          label: label,
          value: value,
          tone: tone,
          caption: caption,
          textual: textual,
          showIcon: show,
          key: key,
        );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(_radius(context) - 2),
          border: Border.all(color: palette.line),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
          child: Builder(
            builder: (context) {
              final valueStyle = TextStyle(
                fontSize: textual ? 16 : 22,
                height: textual ? 1.3 : 1.15,
                fontWeight: FontWeight.w700,
                letterSpacing: textual ? -.1 : -.3,
                color: textual ? tone : palette.text,
                fontFeatures: const [FontFeature.tabularFigures()],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: palette.muted,
                          ),
                        ),
                      ),
                      if (showIcon) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: tone.withValues(alpha: .12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(icon, size: 16, color: tone),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: textual ? 10 : 8),
                  if (textual)
                    Text(value, maxLines: 2, style: valueStyle)
                  else
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(value, maxLines: 1, style: valueStyle),
                    ),
                  if (caption != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      caption!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: palette.hint),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Lays [children] out in equal columns; every tile of a row is as tall as
/// the tallest one, so labels of different lengths never overflow.
class SyncMetricGrid extends StatelessWidget {
  const SyncMetricGrid({required this.children, super.key});
  final List<SyncMetricTile> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = box.maxWidth >= 760
          ? children.length.clamp(1, 4)
          : box.maxWidth >= 250
          ? 2
          : 1;
      const gap = 10.0;
      final tileWidth = (box.maxWidth - gap * (columns - 1)) / columns;
      final showIcons = tileWidth >= 170;
      final rows = <Widget>[];
      for (var start = 0; start < children.length; start += columns) {
        final row = <Widget>[];
        for (var i = 0; i < columns; i++) {
          if (i > 0) row.add(const SizedBox(width: gap));
          final index = start + i;
          row.add(
            Expanded(
              child: index < children.length
                  ? children[index]._withIcon(showIcons)
                  : const SizedBox.shrink(),
            ),
          );
        }
        if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
        rows.add(
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: row,
            ),
          ),
        );
      }
      return Column(children: rows);
    },
  );
}

/// A coloured notice for a state that needs attention.
class SyncNotice extends StatelessWidget {
  const SyncNotice({
    required this.icon,
    required this.tone,
    required this.message,
    super.key,
  });

  final IconData icon;
  final Color tone;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: .09), palette.surface),
        borderRadius: BorderRadius.circular(_radius(context) - 4),
        border: Border.all(color: tone.withValues(alpha: .35)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: tone, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: palette.text,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Section title with an optional count tag and explanation.
class SyncSectionHeader extends StatelessWidget {
  const SyncSectionHeader({
    required this.title,
    this.description,
    this.trailing,
    super.key,
  });

  final String title;
  final String? description;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: palette.text,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description!,
              style: TextStyle(fontSize: 12, height: 1.5, color: palette.muted),
            ),
          ],
        ],
      ),
    );
  }
}

/// A count tag beside a section title.
class SyncCountTag extends StatelessWidget {
  const SyncCountTag({required this.label, required this.tone, super.key});
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tone),
    ),
  );
}

/// One-line "nothing here" row; replaces a full-height empty state so an
/// empty section does not push the rest of the page down.
class SyncEmptyRow extends StatelessWidget {
  const SyncEmptyRow({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(_radius(context) - 2),
        border: Border.all(color: palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: palette.teal.withValues(alpha: .12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: palette.teal),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: palette.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A titled panel of the page's side column.
class SyncPanel extends StatelessWidget {
  const SyncPanel({
    required this.icon,
    required this.title,
    required this.children,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(_radius(context) - 2),
        border: Border.all(color: palette.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon, size: 18, color: palette.teal),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              ],
            ),
            if (children.isNotEmpty) const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// A label/value row of a [SyncPanel]; the value is selectable monospace
/// text so identifiers can be copied into a support request.
class SyncDetailRow extends StatelessWidget {
  const SyncDetailRow({
    required this.label,
    required this.value,
    this.monospace = true,
    super.key,
  });
  final String label;
  final String value;

  /// False for a value that is a sentence rather than an identifier.
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final labelText = Text(
      label,
      style: TextStyle(fontSize: 12, color: palette.muted),
    );
    final valueText = Semantics(
      label: value,
      child: SelectableText(
        value,
        style: TextStyle(
          fontSize: monospace ? 11.5 : 12,
          height: 1.45,
          fontFamily: monospace ? 'monospace' : null,
          color: palette.text,
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: palette.line.withValues(alpha: .6)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth < 340) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [labelText, const SizedBox(height: 3), valueText],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 116, child: labelText),
                const SizedBox(width: 10),
                Expanded(child: valueText),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A small coloured status label.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({required this.label, required this.tone, super.key});
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: tone.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: tone,
          ),
        ),
      ],
    ),
  );
}

/// Rebuilds [builder] every [interval] so relative times ("2 minutes ago")
/// stay true while the page is open and nothing else changes.
class SyncTicker extends StatefulWidget {
  const SyncTicker({
    required this.builder,
    this.interval = const Duration(seconds: 30),
    super.key,
  });

  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration interval;

  @override
  State<SyncTicker> createState() => _SyncTickerState();
}

class _SyncTickerState extends State<SyncTicker> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, DateTime.now());
}
