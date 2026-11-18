# Operating system marks

Sources of `lib/ui/host_system_marks.g.dart`, the outlines `HostSystemIcon`
paints for an identified system. Regenerate after any change here:

    dart run tool/host_system_marks.dart

- `*.svg`: single-path, 24-unit icons copied unchanged from
  [Simple Icons](https://simpleicons.org) 13.21.0 (CC0 1.0). The file name is
  the mark name used in `hostSystemMarkAliases`.
- `marks.json`: title, brand colour and source of each mark, from the same
  release. The generator adapts the colour so it reads on light and dark
  surfaces.

The names and logos are trademarks of their respective owners. They appear
only to tell the user which system a Host runs; do not recolour them into
other shapes, combine them, or use them to brand Atermius itself.

To add a system: add its SVG and `marks.json` entry, map its os-release `ID`
(or product identifier) in `hostSystemMarkAliases`
(`lib/domain/host_operating_system.dart`), regenerate, and run
`flutter test test/host_system_marks_test.dart`.
