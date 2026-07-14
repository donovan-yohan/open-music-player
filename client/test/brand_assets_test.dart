import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _logoAsset = 'assets/brand/soundq-logo.png';

int _pngDimension(Uint8List bytes, int offset) {
  return ByteData.sublistView(bytes).getUint32(offset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundles the canonical 1024px Sound Q logo', () async {
    final bytes = (await rootBundle.load(_logoAsset)).buffer.asUint8List();
    expect(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(_pngDimension(bytes, 16), 1024);
    expect(_pngDimension(bytes, 20), 1024);
  });

  test('auth surfaces reference the canonical logo instead of the placeholder', () {
    for (final path in [
      'lib/features/auth/screens/login_screen.dart',
      'lib/features/splash/splash_screen.dart',
      'lib/app/router.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, contains(_logoAsset));
      expect(source, isNot(contains('soundq-placeholder-logo')));
    }
  });
}
