import 'dart:async';

import 'package:flutter/material.dart';

import 'app_density.dart';
import 'app_theme.dart';
import 'surfaces.dart';

/// Shared building blocks of the workspace pages (Sync health, Groups,
/// Keychain, Devices, …), so every page has the same header, panels,
/// counters, notices and empty rows.
///
/// A page leads with a [PageHeader]; a status page can follow it with a
/// [StatusHero]. The widgets only lay out what they are
/// given: every label and value comes from the page.

/// The title row of a workspace page: title, one-line explanation and the
/// page's actions.
///
/// The actions sit on the title row and only move below the text when the
/// page is narrower than about 640 px; they used to drop to a row of their
/// own on every window narrower than 1280 px, which left a lone button
/// floating under the title on most screens.
class PageHeader extends StatelessWidget {
  const PageHeader({
    required this.title,
    required this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            // R7 density: 20 compact / 22 touch (R6a 22).
            fontSize: Theme.of(context).textTheme.titleLarge!.fontSize! + 1,
            fontWeight: FontWeight.w700,
            letterSpacing: -.5,
            color: palette.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(color: palette.muted, height: 1.45, fontSize: 12),
        ),
      ],
    );
    if (actions.isEmpty) return heading;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 640;
        final buttons = Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: narrow ? WrapAlignment.start : WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: actions,
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [heading, const SizedBox(height: 12), buttons],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 16),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * .5),
              child: buttons,
            ),
          ],
        );
      },
    );
  }
}

/// Radius of the page's blocks: the block radius, or the concentric radius
/// of an enclosing block (see surfaces.dart).
double _radius(BuildContext context) => SurfaceScope.concentric(
  context,
  fallback: AppDensity.of(context).radiusLg,
  floor: AppDensity.of(context).radiusMd,
);

/// Fill of a page block at this depth (one level above its parent).
Color _blockFill(BuildContext context) =>
    context.palette.blockFill(SurfaceScope.depthOf(context) + 1);

/// One label/value fact shown under the summary title.
class HeroFact {
  const HeroFact({
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
class StatusHero extends StatelessWidget {
  const StatusHero({
    required this.icon,
    required this.tone,
    required this.title,
    required this.description,
    required this.facts,
    required this.actions,
    this.busy = false,
    super.key,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String description;
  final List<HeroFact> facts;
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
                  color: tone.withValues(alpha: .16),
                  shape: BoxShape.circle,
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
        final fill = _blockFill(context);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: fill,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(tone.withValues(alpha: .16), fill),
                fill,
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
                  SizedBox(height: narrow ? 16 : 20),
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
  final HeroFact fact;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: palette.fill,
        borderRadius: BorderRadius.circular(AppDensity.of(context).radiusMd),
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

/// A coloured notice for a state that needs attention.
class PageNotice extends StatelessWidget {
  const PageNotice({
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
        color: palette.tinted(tone, base: _blockFill(context)),
        borderRadius: BorderRadius.circular(_radius(context)),
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
class SectionHeader extends StatelessWidget {
  const SectionHeader({
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
class CountTag extends StatelessWidget {
  const CountTag({required this.label, required this.tone, super.key});
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
class EmptyRow extends StatelessWidget {
  const EmptyRow({
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
        color: _blockFill(context),
        borderRadius: BorderRadius.circular(_radius(context)),
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

/// A titled panel: an icon, a title, an optional explanation and content.
class PagePanel extends StatelessWidget {
  const PagePanel({
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
    final radius = _radius(context);
    return AppBlock(
      radius: radius,
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
    );
  }
}

/// A small coloured status label.
class StatusChip extends StatelessWidget {
  const StatusChip({required this.label, required this.tone, super.key});
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
class RelativeTimeTicker extends StatefulWidget {
  const RelativeTimeTicker({
    required this.builder,
    this.interval = const Duration(seconds: 30),
    super.key,
  });

  final Widget Function(BuildContext context, DateTime now) builder;
  final Duration interval;

  @override
  State<RelativeTimeTicker> createState() => _RelativeTimeTickerState();
}

class _RelativeTimeTickerState extends State<RelativeTimeTicker> {
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
