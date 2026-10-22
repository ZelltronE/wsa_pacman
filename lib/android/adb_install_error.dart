import 'package:wsa_pacman/l10n/app_localizations.dart';

class AdbInstallError {
  final String code;
  final String description;

  const AdbInstallError(this.code, this.description);

  static AdbInstallError parse(String stdout, String stderr, AppLocalizations lang) {
    final combined = '$stdout\n$stderr'.trim();
    if (combined.isEmpty) {
      return AdbInstallError("UNKNOWN_ERROR", lang.installer_error_nomsg);
    }

    // 1. Device offline / not found / connection refused
    if (combined.contains(RegExp(r"device ('.*' )?not found", caseSensitive: false)) ||
        combined.contains(RegExp(r"no devices/emulators found", caseSensitive: false))) {
      return const AdbInstallError(
        "DEVICE_NOT_FOUND",
        "No se encontró el dispositivo de WSA. Comprueba que el Subsistema de Windows para Android esté iniciado y con depuración USB/ADB activa.",
      );
    }
    if (combined.contains(RegExp(r"device offline", caseSensitive: false))) {
      return const AdbInstallError(
        "DEVICE_OFFLINE",
        "El dispositivo de WSA está fuera de línea. Reinicia WSA e inténtalo de nuevo.",
      );
    }
    if (combined.contains(RegExp(r"cannot connect to|failed to connect to|Connection refused|10061", caseSensitive: false))) {
      return const AdbInstallError(
        "CONNECTION_FAILED",
        "No se pudo conectar al puerto de depuración de WSA. Inicia WSA antes de instalar.",
      );
    }

    // 2. Failure [INSTALL_FAILED_...: msg]
    // Matches e.g.:
    //   Failure [INSTALL_FAILED_ALREADY_EXISTS: Attempt to re-install...]
    //   Failure [INSTALL_FAILED_VERSION_DOWNGRADE]
    //   adb: failed to install com.foo.apk: Failure [INSTALL_FAILED_...]
    //   adb.exe: failed to install ...: Failure [INSTALL_FAILED_...]
    final failureMatch = RegExp(
      r'Failure\s*\[([A-Z0-9_]+)(?::\s*([^\]\r\n]+))?\]',
      caseSensitive: false,
    ).firstMatch(combined);

    if (failureMatch != null) {
      final code = (failureMatch.group(1) ?? "INSTALL_FAILED").toUpperCase();
      final desc = failureMatch.group(2)?.trim();
      return AdbInstallError(code, (desc != null && desc.isNotEmpty) ? desc : code);
    }

    // 3. Fallback: extract the most informative non-empty line
    final lines = combined
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Performing Streamed Install'))
        .toList();

    if (lines.isNotEmpty) {
      final errorLine = lines.firstWhere(
        (l) =>
            l.toLowerCase().contains('error') ||
            l.toLowerCase().contains('failed') ||
            l.toLowerCase().contains('failure') ||
            l.toLowerCase().contains('exception'),
        orElse: () => lines.first,
      );
      return AdbInstallError("INSTALL_ERROR", errorLine);
    }

    return AdbInstallError("UNKNOWN_ERROR", lang.installer_error_nomsg);
  }
}
