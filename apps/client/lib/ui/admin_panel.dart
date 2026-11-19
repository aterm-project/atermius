import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../l10n/l10n.dart';
import 'app_density.dart';
import 'app_theme.dart';
import 'ios_native/ios_native.dart';
import 'settings_scaffold.dart';

/// One section of the admin console.
///
/// The console renders whatever list of sections it is given, in order, so a
/// new global function (for example an online sandbox) is added by appending
/// one [AdminPanelSection] to the registry in `app_shell.dart`
/// (`_adminPanelSections`); nothing else in the console has to change.
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
    this.wide = false,
  });

  /// Stable identifier, also used for widget keys, section requests and the
  /// section's address (`/admin/<id>`): lower-case letters, digits and `-`.
  final String id;
  final IconData icon;

  /// Resolved from the active catalog at build time so a runtime language
  /// switch relabels the console.
  final String Function(AppLocalizations l10n) title;
  final String Function(AppLocalizations l10n) description;
  final Widget Function(BuildContext context, AppController app) builder;

  /// Hides the section when the instance does not offer the function. A null
  /// predicate means the section is always offered to administrators.
  final bool Function(AppController app)? available;

  /// Runs once when the section is first opened, for example to load the list
  /// it shows.
  final void Function(AppController app)? onFirstShown;

  /// The section is a table, not a form: it gets the whole content width.
  final bool wide;
}

/// The admin console: a site of its own, not a page of the user workspace.
///
/// It fills the window with its own navigation (the sections), its own
/// heading and its own way back, and in the browser it lives under `/admin`
/// (`/admin/users`, …; see `web/page_address.dart`). The workspace shell shows
/// it instead of the workspace, never inside it.
///
/// It renders nothing for an account that is not an instance administrator, so
/// a stale page selection can never expose administrative controls. The server
/// independently authorizes every admin endpoint.
class AdminPanel extends StatefulWidget {
  const AdminPanel({
    required this.app,
    required this.sections,
    this.onExit,
    super.key,
  });

  final AppController app;
  final List<AdminPanelSection> sections;

  /// Leaves the console. Defaults to opening the workspace's Hosts page.
  final VoidCallback? onExit;

  /// A section requested from outside the console; the console showing now, or
  /// the next one built, selects it.
  static final ValueNotifier<String?> requestedSection = ValueNotifier(null);

  /// The section on screen while the console is; null otherwise. The browser
  /// address follows it.
  static final ValueNotifier<String?> shownSection = ValueNotifier(null);

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
  State<AdminPanel> createState() => _AdminPanelState();
}

class _AdminPanelState extends State<AdminPanel> {
  AppController get app => widget.app;

  @override
  void dispose() {
    // After the frame: this may be the same frame the address binding reads
    // the notifier in, and it must not be notified while the tree is locked.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AdminPanel.shownSection.value = null;
    });
    super.dispose();
  }

  void _exit() {
    final onExit = widget.onExit;
    if (onExit != null) return onExit();
    app.showWorkspacePage(WorkspacePage.hosts);
  }

  String get _identity {
    final username = app.authenticatedUsername?.trim();
    if (username != null && username.isNotEmpty) return username;
    final id = app.currentAccountId;
    if (id == null) return '';
    return id.length > 8 ? id.substring(0, 8) : id;
  }

  /// Host of the server this console administers, without scheme or path.
  String get _server {
    final base = app.api?.baseUrl;
    if (base == null) return '';
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return base;
    return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  }

  @override
  Widget build(BuildContext context) {
    final offered = AdminPanel.sectionsFor(app, widget.sections);
    if (offered.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    final palette = context.palette;
    return _AdminSiteTitle(
      title: 'Atermius · ${l10n.adminSiteTitle}',
      child: Material(
        color: palette.background,
        child: SettingsScaffold(
          key: const ValueKey('admin_panel'),
          title: l10n.adminSiteTitle,
          categoriesLabel: l10n.adminPanelSections,
          sectionRequests: AdminPanel.requestedSection,
          onSectionShown: (id) => AdminPanel.shownSection.value = id,
          navigationHeader: _AdminSiteBrand(server: _server),
          navigationFooter: _AdminSiteFooter(
            identity: _identity,
            onExit: _exit,
          ),
          narrowHeader: _AdminSiteBar(onExit: _exit),
          sections: [
            for (final section in offered)
              SettingsSection(
                id: section.id,
                title: section.title(l10n),
                icon: section.icon,
                description: section.description(l10n),
                wide: section.wide,
                builder: (context) => _AdminPanelSectionBody(
                  key: ValueKey('admin_panel_section_${section.id}'),
                  app: app,
                  section: section,
                ),
              ),
            // The iPhone layout is a list of rows without the console's own
            // column, so the way back is a row of that list.
            if (isIosPhone(context))
              SettingsSection(
                id: 'exit',
                title: l10n.adminSiteBackToWorkspace,
                icon: Icons.arrow_back_rounded,
                description: '',
                iosOnTap: _exit,
                builder: (_) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Names the browser tab (and the task switcher entry) after the console
/// while it is on screen, and gives the application its own name back after.
class _AdminSiteTitle extends StatefulWidget {
  const _AdminSiteTitle({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  State<_AdminSiteTitle> createState() => _AdminSiteTitleState();
}

class _AdminSiteTitleState extends State<_AdminSiteTitle> {
  int? _color;

  void _describe(String label) {
    SystemChrome.setApplicationSwitcherDescription(
      ApplicationSwitcherDescription(label: label, primaryColor: _color),
    );
  }

  @override
  void dispose() {
    // A [Title] only speaks when it builds; the application's own one above
    // does not build again just because this one went away.
    _describe('Atermius');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary.withValues(alpha: 1);
    _color = color.toARGB32();
    return Title(title: widget.title, color: color, child: widget.child);
  }
}

/// Heading of the console's own navigation column: whose console this is.
class _AdminSiteBrand extends StatelessWidget {
  const _AdminSiteBrand({required this.server});

  final String server;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final density = AppDensity.of(context);
    return Padding(
      key: const ValueKey('admin_site_brand'),
      padding: EdgeInsets.fromLTRB(
        density.space6,
        density.space7,
        density.space6,
        density.space6,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: palette.lime,
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              Icons.admin_panel_settings_outlined,
              color: palette.onAccentText,
              size: 21,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.adminSiteTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (server.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Tooltip(
                    message: server,
                    child: Text(
                      server,
                      key: const ValueKey('admin_site_server'),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: palette.muted),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Foot of the console's navigation column: who is signed in, and the way
/// back to the workspace.
class _AdminSiteFooter extends StatelessWidget {
  const _AdminSiteFooter({required this.identity, required this.onExit});

  final String identity;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final density = AppDensity.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        density.space4,
        density.space3,
        density.space4,
        density.space5,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(height: 1, color: palette.line),
          SizedBox(height: density.space4),
          if (identity.isNotEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: density.space3),
              child: Row(
                children: [
                  Icon(Icons.person_outline, size: 15, color: palette.muted),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Tooltip(
                      message: identity,
                      child: Text(
                        identity,
                        key: const ValueKey('admin_site_identity'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          SizedBox(height: density.space3),
          TextButton.icon(
            key: const ValueKey('admin_site_exit'),
            onPressed: onExit,
            style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            icon: const Icon(Icons.arrow_back_rounded, size: 17),
            label: Text(
              context.l10n.adminSiteBackToWorkspace,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// The console's heading on a narrow window, where the navigation column is
/// replaced by a section picker.
class _AdminSiteBar extends StatelessWidget {
  const _AdminSiteBar({required this.onExit});

  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Material(
      color: palette.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(
              Icons.admin_panel_settings_outlined,
              size: 19,
              color: palette.lime,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                context.l10n.adminSiteTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('admin_site_exit'),
              tooltip: context.l10n.adminSiteBackToWorkspace,
              onPressed: onExit,
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
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
