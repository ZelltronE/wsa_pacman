import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wsa_pacman/android/adb_install_error.dart';
import 'package:wsa_pacman/l10n/app_localizations.dart';

void main() {
  test('AdbInstallError parses device not found', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse('', "adb.exe: device '127.0.0.1:58526' not found", lang);
    expect(err.code, 'DEVICE_NOT_FOUND');
    expect(err.description, contains('No se encontró el dispositivo'));
  });

  test('AdbInstallError parses cannot connect', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse('', 'cannot connect to 127.0.0.1:58526: 10061', lang);
    expect(err.code, 'CONNECTION_FAILED');
  });

  test('AdbInstallError parses standard failure with desc', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse(
      'Performing Streamed Install\nFailure [INSTALL_FAILED_ALREADY_EXISTS: Attempt to re-install without -r]',
      '',
      lang,
    );
    expect(err.code, 'INSTALL_FAILED_ALREADY_EXISTS');
    expect(err.description, 'Attempt to re-install without -r');
  });

  test('AdbInstallError parses failure without desc', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse('', 'Failure [INSTALL_FAILED_VERSION_DOWNGRADE]', lang);
    expect(err.code, 'INSTALL_FAILED_VERSION_DOWNGRADE');
    expect(err.description, 'INSTALL_FAILED_VERSION_DOWNGRADE');
  });

  test('AdbInstallError parses adb.exe prefix with failure', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse(
      '',
      'adb.exe: failed to install com.foo.apk: Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE: Out of storage]',
      lang,
    );
    expect(err.code, 'INSTALL_FAILED_INSUFFICIENT_STORAGE');
    expect(err.description, 'Out of storage');
  });

  test('AdbInstallError falls back to trimmed output on generic failure', () async {
    final lang = await AppLocalizations.delegate.load(const Locale('es'));
    final err = AdbInstallError.parse('', 'adb.exe: unexpected error during handshake', lang);
    expect(err.code, 'INSTALL_ERROR');
    expect(err.description, contains('unexpected error'));
  });
}
