import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'settings_scaffold.dart';

/// One section of the instance administration panel.
///
/// The panel renders whatever list of sections it is given, in order, so a new
/// global function (for example an online sandbox) is added by appending one
/// [AdminPanelSection] to the registry in `app_shell.dart`
/// (`_adminPanelSections`); nothing else in the panel has to change.
@immutable
class AdminPanelSection {
  const AdminPanelSection({
    required this.id,
    required this.icon,
    required this.title,
    required this.description,
    required this.builder,
    this.available,
    this.onFirstShown,
  });

  /// Stable identifier, also used for widget keys and section requests.
  final String id;
  final IconData icon;

  /// Resolved from the active catalog at build time so a runtime language
  /// switch relabels the panel.
  final String Function(AppLocalizations l10n) title;
  final String Function(AppLocalizations l10n) description;
  final Widget Function(BuildContext context, AppController app) builder;

  /// Hides the section when the instance does not offer the function. A null
  /// predicate means the section is always offered to administrators.
  final bool Function(AppController app)? available;

  /// Runs once when the section is first opened, for example to load the list
  /// it shows.
  final void Function(AppController app)? onFirstShown;
}

/// The instance administration panel: its own workspace page, with its own
/// section list in the same visual language as Settings.
///
/// It renders nothing for an account that is not an instance administrator, so
/// a stale page selection can never expose administrative controls. The server
/// independently authorizes every admin endpoint.
class AdminPanel extends StatelessWidget {
  const AdminPanel({required this.app, required this.sections, super.key});

  final AppController app;
  final List<AdminPanelSection> sections;

  /// A section requested from outside the panel; the panel showing now, or the
  /// next one built, selects it.
  static final ValueNotifier<String?> requestedSection = ValueNotifier(null);

  static void requestSection(String id) {
    requestedSection.value = null;
    requestedSection.value = id;
  }

  /// Sections offered to [app]'s account: none unless it is an instance
  /// administrator.
  static List<AdminPanelSection> sectionsFor(
    AppController app,
    List<AdminPanelSection> sections,
  ) => !app.isInstanceAdmin
      ? const []
      : [
          for (final section in sections)
            if (section.available?.call(app) ?? true) section,
        ];

  @override
  Widget build(BuildContext context) {
    final offered = sectionsFor(app, sections);
    if (offered.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    return SettingsScaffold(
      key: const ValueKey('admin_panel'),
      title: l10n.adminPanelTitle,
      categoriesLabel: l10n.adminPanelSections,
      sectionRequests: requestedSection,
      sections: [
        for (final section in offered)
          SettingsSection(
            id: section.id,
            title: section.title(l10n),
            icon: section.icon,
            description: section.description(l10n),
            builder: (context) => _AdminPanelSectionBody(
              key: ValueKey('admin_panel_section_${section.id}'),
              app: app,
              section: section,
            ),
          ),
      ],
    );
  }
}

class _AdminPanelSectionBody extends StatefulWidget {
  const _AdminPanelSectionBody({
    required this.app,
    required this.section,
    super.key,
  });

  final AppController app;
  final AdminPanelSection section;

  @override
  State<_AdminPanelSectionBody> createState() => _AdminPanelSectionBodyState();
}

class _AdminPanelSectionBodyState extends State<_AdminPanelSectionBody> {
  @override
  void initState() {
    super.initState();
    final onFirstShown = widget.section.onFirstShown;
    if (onFirstShown == null) return;
    // Loading notifies the controller, which must not happen during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.app.isInstanceAdmin) onFirstShown(widget.app);
    });
  }

  @override
  Widget build(BuildContext context) =>
      widget.section.builder(context, widget.app);
}
