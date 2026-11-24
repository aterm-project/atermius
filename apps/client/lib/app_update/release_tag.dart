/// The release this binary was built for, for example
/// `local-20261124.2-178e1a78f57b`. Release builds pass it with
/// `--dart-define=ATERMIUS_RELEASE_TAG=<tag>`; it is empty in development
/// builds, which never look for updates.
const atermiusReleaseTag = String.fromEnvironment('ATERMIUS_RELEASE_TAG');

/// The ordering part of a release tag: the build day and its number on that
/// day (`<prefix>-<yyyymmdd>.<n>-<commit>`). Releases are compared by this
/// alone, so every channel prefix sorts on one timeline.
class ReleaseStamp implements Comparable<ReleaseStamp> {
  const ReleaseStamp(this.day, this.sequence);

  /// `yyyymmdd` as a number.
  final int day;
  final int sequence;

  static final _pattern = RegExp(r'(?:^|-)(\d{8})\.(\d{1,4})-[0-9a-f]{7,40}$');

  static ReleaseStamp? tryParse(String tag) {
    final match = _pattern.firstMatch(tag);
    if (match == null) return null;
    return ReleaseStamp(int.parse(match[1]!), int.parse(match[2]!));
  }

  /// What the user sees for this release, e.g. `20261124.2`.
  String get label => '$day.$sequence';

  @override
  int compareTo(ReleaseStamp other) =>
      day != other.day ? day.compareTo(other.day) : sequence.compareTo(other.sequence);

  bool operator >(ReleaseStamp other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is ReleaseStamp && other.day == day && other.sequence == sequence;

  @override
  int get hashCode => Object.hash(day, sequence);

  @override
  String toString() => label;
}

/// True when [candidate] is a later release than [current]. Tags that do not
/// carry a stamp are never treated as newer.
bool isNewerRelease(String candidate, String current) {
  final a = ReleaseStamp.tryParse(candidate), b = ReleaseStamp.tryParse(current);
  return a != null && b != null && a > b;
}

/// Short text for a release in the UI; falls back to the whole tag.
String releaseLabel(String tag) => ReleaseStamp.tryParse(tag)?.label ?? tag;
