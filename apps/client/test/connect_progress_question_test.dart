import 'package:aterm_client/terminal/connect_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a question waits for its answer and is cleared once answered',
    () async {
      final progress = ConnectProgress();
      var notified = 0;
      progress.addListener(() => notified++);
      progress.begin();

      final answer = progress.ask('review');
      final question = progress.question!;
      expect(question.request, 'review');
      expect(notified, 2);

      progress.answer(question, true);
      expect(await answer, isTrue);
      expect(progress.question, isNull);

      // A stale question cannot be answered again.
      progress.answer(question, false);
      expect(progress.question, isNull);
    },
  );

  for (final (label, end) in <(String, void Function(ConnectProgress))>[
    ('stop loading', (progress) => progress.cancel()),
    ('a failure', (progress) => progress.fail(progress.attempt, 'failed')),
    ('a new attempt', (progress) => progress.begin()),
    ('closing the tab', (progress) => progress.retire()),
  ]) {
    test('$label answers an open question no', () async {
      final progress = ConnectProgress()..begin();
      final answer = progress.ask('review');
      end(progress);
      expect(await answer, isFalse);
      expect(progress.question, isNull);
    });
  }

  test(
    'disconnecting a reconnect without a loading attempt answers no',
    () async {
      final progress = ConnectProgress();
      final answer = progress.ask('review');
      var notified = 0;
      progress.addListener(() => notified++);
      expect(progress.cancel(), isFalse);
      expect(await answer, isFalse);
      expect(progress.question, isNull);
      expect(notified, 1);
    },
  );

  test('a closed tab never asks', () async {
    final progress = ConnectProgress()..retire();
    expect(await progress.ask('review'), isFalse);
    expect(progress.question, isNull);
  });

  test(
    'a newer question replaces the open one, which is answered no',
    () async {
      final progress = ConnectProgress()..begin();
      final first = progress.ask('first');
      final second = progress.ask('second');
      expect(await first, isFalse);
      expect(progress.question!.request, 'second');
      progress.answer(progress.question!, true);
      expect(await second, isTrue);
    },
  );
}
