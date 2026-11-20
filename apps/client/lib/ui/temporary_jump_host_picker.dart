import 'package:flutter/material.dart';

import '../domain/models.dart';
import 'jump_host_picker.dart';

/// Result of [showTemporaryJumpHostPicker]: the SSH Host to connect through,
/// or null for the target's saved route.
typedef TemporaryJumpChoice = JumpHostChoice;

/// SSH Hosts among [hosts] that [target] can be reached through: not the
/// target itself, and the candidate's own Jump Host chain is complete,
/// acyclic, does not pass through the target and leaves room for one more hop.
List<HostRecord> temporaryJumpHostCandidates(
  HostRecord target,
  Iterable<HostRecord> hosts,
) => jumpHostCandidates(hosts, targetId: target.id);

/// Lets the user pick the SSH Host a failed tab should be retried through.
/// Returns null when dismissed. [currentJumpHostId] is the tab's present
/// temporary jump host; when set, the saved route is offered as well.
Future<TemporaryJumpChoice?> showTemporaryJumpHostPicker(
  BuildContext context, {
  required HostRecord target,
  required List<HostRecord> candidates,
  String? currentJumpHostId,
  Iterable<GroupRecord> groups = const [],
}) => showJumpHostPicker(
  context,
  keyPrefix: 'temporary_jump',
  candidates: candidates,
  selectedId: currentJumpHostId,
  groups: groups,
  retryTarget: target,
);
