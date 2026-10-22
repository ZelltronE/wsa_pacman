import 'package:flutter_test/flutter_test.dart';
import 'package:wsa_pacman/android/android_utils.dart';
import 'package:wsa_pacman/main.dart';

void main() {
  test('Constants and bootstrap initialization test', () {
    Constants.installMode = false;
    Constants.packageFile = '';
    Constants.packageType = AppPackage.NONE;
    Constants.isolate = null;

    expect(Constants.installMode, isFalse);
    expect(Constants.packageType, AppPackage.NONE);
    expect(Constants.packageFile, isEmpty);
  });
}
