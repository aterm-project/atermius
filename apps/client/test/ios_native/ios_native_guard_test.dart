// iPhone 纯血 iOS 守卫测试：扫描 lib/ 全部 Dart 源码，阻止 Cupertino 图标字体
// 及 SDK 内部隐式引用它的组件进入代码库（真机未打包字体时会显示方块）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 去掉行注释与块注释（字符串内的 `//` 粗略保留：仅在引号外才视为注释）。
String _stripComments(String source) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < source.length) {
    final ch = source[i];
    final next = i + 1 < source.length ? source[i + 1] : '';
    if (quote != null) {
      out.write(ch);
      if (ch == r'\') {
        if (i + 1 < source.length) out.write(source[i + 1]);
        i += 2;
        continue;
      }
      if (ch == quote) quote = null;
      i++;
      continue;
    }
    if (ch == '/' && next == '/') {
      while (i < source.length && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (ch == '/' && next == '*') {
      i += 2;
      while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (ch == "'" || ch == '"') quote = ch;
    out.write(ch);
    i++;
  }
  return out.toString();
}

/// 从 `(` 位置起截取到配对的 `)`（含）。
String _balancedArgs(String source, int openIndex) {
  var depth = 0;
  for (var i = openIndex; i < source.length; i++) {
    final ch = source[i];
    if (ch == '(') depth++;
    if (ch == ')') {
      depth--;
      if (depth == 0) return source.substring(openIndex, i + 1);
    }
  }
  return source.substring(openIndex);
}

int _lineOf(String source, int index) =>
    '\n'.allMatches(source.substring(0, index)).length + 1;

void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
      .toList();

  Map<String, String> sources() => {
    for (final file in files)
      file.path: _stripComments(file.readAsStringSync()),
  };

  test('lib/ 中不得出现 Cupertino 图标字体及隐式引用它的 SDK 组件', () {
    final banned = RegExp(
      r'\b(CupertinoIcons|CupertinoListTileChevron|CupertinoExpansionTile|CupertinoNavigationBarBackButton)\b',
    );
    final violations = <String>[];
    sources().forEach((path, source) {
      for (final match in banned.allMatches(source)) {
        violations.add('$path:${_lineOf(source, match.start)} ${match.group(0)}');
      }
    });
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('Cupertino 导航栏必须关闭自动返回键，.search 必须显式传 searchField', () {
    final ctor = RegExp(
      r'\b(CupertinoNavigationBar|CupertinoSliverNavigationBar)(\.search|\.large)?\s*\(',
    );
    final violations = <String>[];
    sources().forEach((path, source) {
      for (final match in ctor.allMatches(source)) {
        final args = _balancedArgs(source, match.end - 1);
        final where = '$path:${_lineOf(source, match.start)}';
        if (!RegExp(r'automaticallyImplyLeading\s*:\s*false').hasMatch(args)) {
          violations.add('$where 缺少 automaticallyImplyLeading: false');
        }
        if (match.group(2) == '.search' &&
            !RegExp(r'searchField\s*:').hasMatch(args)) {
          violations.add('$where .search 缺少 searchField:');
        }
      }
    });
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('CupertinoSearchTextField 必须显式传 prefixIcon 与 suffixIcon', () {
    final ctor = RegExp(r'\bCupertinoSearchTextField\s*\(');
    final violations = <String>[];
    sources().forEach((path, source) {
      for (final match in ctor.allMatches(source)) {
        final args = _balancedArgs(source, match.end - 1);
        if (!RegExp(r'prefixIcon\s*:').hasMatch(args) ||
            !RegExp(r'suffixIcon\s*:').hasMatch(args)) {
          violations.add('$path:${_lineOf(source, match.start)}');
        }
      }
    });
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('CupertinoTextField 的 clearButtonMode 只允许 never', () {
    final usage = RegExp(r'clearButtonMode\s*:\s*([A-Za-z_.]+)');
    final violations = <String>[];
    sources().forEach((path, source) {
      for (final match in usage.allMatches(source)) {
        if (match.group(1) != 'OverlayVisibilityMode.never') {
          violations.add('$path:${_lineOf(source, match.start)} ${match.group(1)}');
        }
      }
    });
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
