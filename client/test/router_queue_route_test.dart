import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('router exposes the queue QA route', () {
    final routerSource = File('lib/app/router.dart').readAsStringSync();

    expect(routerSource, contains("path: '/queue'"));
    expect(routerSource, contains('QueueScreen'));
    expect(routerSource, contains('initialLocation: _initialRoute'));
    expect(routerSource, isNot(contains("initialLocation: '/'")));
  });
}
