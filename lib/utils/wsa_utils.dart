import 'dart:io';

import 'package:wsa_pacman/global_state.dart';
import 'package:wsa_pacman/main.dart';
import 'package:wsa_pacman/windows/win_io.dart';
import 'package:wsa_pacman/windows/win_pkg.dart';
import '../utils/string_utils.dart';
import '../utils/regexp_utils.dart';

class WSAUtils {
  static bool launch([String? param]) {
    // Direct protocol URI activation when param has a registered scheme
    if (param != null && (param.startsWith('wsa://') || param.startsWith('wsa-client://') || param.startsWith('wsa-settings://'))) {
      if (WinIO.run(ShellOp.OPEN, param, null)) {
        return true;
      }
    }

    bool ok = WinIO.run(ShellOp.OPEN, "shell:appsFolder\\${Env.WSA_INFO.familyName}!${Env.WSA_INFO.clientID}", param);
    if (!ok) {
      if (param != null && (param.startsWith('wsa://') || param.startsWith('wsa-client://'))) {
        ok = WinIO.run(ShellOp.OPEN, param, null);
      } else {
        ok = WinIO.run(ShellOp.OPEN, "wsa://", null);
      }
    }
    if (!ok && File(Env.WSA_EXECUTABLE).existsSync()) {
      Process.run(Env.WSA_EXECUTABLE, param != null ? [param] : []);
      return true;
    }
    return ok;
  }

  static bool launchApp(String package) => launch("wsa://$package");

  static bool launchSettings() {
    // 1. Direct protocol activation for WSA Settings app
    if (WinIO.run(ShellOp.OPEN, "wsa-settings://", null)) {
      return true;
    }
    // 2. Direct AppX activation for SettingsApp
    if (WinIO.run(ShellOp.OPEN, "shell:appsFolder\\${Env.WSA_INFO.familyName}!SettingsApp", null)) {
      return true;
    }
    // 3. Fallback to direct executable if available
    final settingsExe = '${Env.WSA_SYSTEM_PATH}\\WsaSettings.exe';
    if (File(settingsExe).existsSync()) {
      Process.run(settingsExe, []);
      return true;
    }
    return launchApp("com.android.settings");
  }

  static bool launchDeveloperSettings() {
    if (WinIO.run(ShellOp.OPEN, "wsa-client://developer-settings", null)) {
      return true;
    }
    if (launch("/deeplink wsa-client://developer-settings")) {
      return true;
    }
    final settingsExe = '${Env.WSA_SYSTEM_PATH}\\WsaSettings.exe';
    if (File(settingsExe).existsSync()) {
      Process.run(settingsExe, ['/deeplink', 'wsa-client://developer-settings']);
      return true;
    }
    return false;
  }

  static bool launchManageApplications() {
    // 1. Deeplink to App Settings page in WSA Settings
    if (WinIO.run(ShellOp.OPEN, "wsa-client://app-settings", null)) {
      return true;
    }
    // 2. Launch via WsaClient deeplink
    if (launch("/deeplink wsa-client://app-settings")) {
      return true;
    }
    // 3. Fallback to general settings
    return launchSettings();
  }

  static bool launchSystem() => launchApp("android.system");
  static bool shutdown() => launch("/shutdown");
  static bool modifyApp(String package) => launch("/modify $package");
  static bool launchPartial() => launch("/partiallyrunning");
}

class WSAPkgInfo extends WinPkgInfo {
  late final String clientID;

  WSAPkgInfo.fromSystemPath(String systemPath) : super.fromSystemPath(systemPath);

  @override void parseManifestExtras(String manifest) {
    String? clientInfo = RegExp('<\\s*Application${REGEX_XML_NOCLOSE}Executable\\s*=\\s*${REGEX_QUOTED_PATTERN((c)=>"[^$c>]*WsaClient.exe")}$REGEX_XML_NOCLOSE', caseSensitive: false, multiLine: true, dotAll: true)
      .firstMatch(manifest)?.group(0);
    clientID = clientInfo?.find('Id\\s*=\\s*($REGEX_XML_QUOTED)', 1)?.unquoted ?? "App";
  }
}

final _timeoutProcessResult = ProcessResult(-1, -999, null, null);

extension ProcessResultTimeout on ProcessResult {
  bool get isTimeout => exitCode == -999;
}

extension ADBUtils on Future<ProcessResult> {
  Future<ProcessResult> defaultError() => onError((error, stackTrace) => ProcessResult(-1, -1, null, null));
  Future<ProcessResult> processTimeout(Duration duration) =>
    timeout(duration, onTimeout: () => Future.value(_timeoutProcessResult));

  static String get deviceName => '${GState.ipAddress.$}:${GState.androidPort.$}';
  static String _toName(String ipAddress, int port) => '$ipAddress:$port';
  static String get adbPath => '${Env.TOOLS_DIR}\\adb.exe';

  static Future<ProcessResult> _command(List<String> args, {String? workDir, Duration timeout = const Duration(seconds: 8)}) =>
      Process.run(adbPath, args, workingDirectory: workDir).timeout(
        timeout,
        onTimeout: () => _timeoutProcessResult,
      );
  static Future<ProcessResult> command(String command, {String? param, String? workDir}) => _command([command, if (param != null) param], workDir: workDir);
  static Future<ProcessResult> commandWSA(String command, String? Function(String device) param, {String? workDir}) => ADBUtils.command(command, param: param(deviceName), workDir: workDir);

  static Future<ProcessResult> _withDevice(String device, String command, {List<String>? args, String? workDir, Duration timeout = const Duration(seconds: 8)}) => _command(['-s', device, command, if (args != null) ...args], workDir: workDir, timeout: timeout);
  static Future<ProcessResult> withDevice(String device, String command, {String? param, String? workDir, Duration timeout = const Duration(seconds: 8)}) => _command(['-s', device, command, if (param != null) param], workDir: workDir, timeout: timeout);
  static Future<ProcessResult> withAddress(String ipAddress, int port, String command, {String? param, String? workDir, Duration timeout = const Duration(seconds: 8)}) => withDevice(_toName(ipAddress, port), command, param: param, workDir: workDir, timeout: timeout);
  static Future<ProcessResult> withWSA(String command, {String? param, String? workDir, Duration timeout = const Duration(seconds: 8)}) => withDevice(deviceName, command, param: param, workDir: workDir, timeout: timeout);

  static Future<ProcessResult> devices() => command('devices');

  static Future<ProcessResult> disconnect(String device) => command('disconnect', param: device);
  static Future<ProcessResult> disconnectAddress(String ipAddress, int port) => disconnect(_toName(ipAddress, port));
  static Future<ProcessResult> disconnectWSA() => disconnect(deviceName);

  static Future<ProcessResult> connect(String device) => command('connect', param: device);
  static Future<ProcessResult> connectAddress(String ipAddress, int port) => connect(_toName(ipAddress, port));
  static Future<ProcessResult> connectWSA() => connect(deviceName);

  static Future<ProcessResult> shell(String device, String command) => withDevice(device, 'shell', param: command);
  static Future<ProcessResult> shellToAddress(String ipAddress, int port, String command) => shell(_toName(ipAddress, port), command);
  static Future<ProcessResult> shellToWSA(String command) => shell(deviceName, command);

  static Future<ProcessResult> push(String device, String inPath, String outPath, {String? workDir, Duration timeout = const Duration(seconds: 30)}) => _withDevice(device, 'push', args: [inPath, outPath], workDir: workDir, timeout: timeout);
  static Future<ProcessResult> pushToAddress(String ipAddress, int port, String inPath, String outPath, {String? workDir, Duration timeout = const Duration(seconds: 30)}) => push(_toName(ipAddress, port), inPath, outPath, workDir: workDir, timeout: timeout);
  static Future<ProcessResult> pushToWSA(String inPath, String outPath, {String? workDir, Duration timeout = const Duration(seconds: 30)}) => push(deviceName, inPath, outPath, workDir: workDir, timeout: timeout);

  static Future<ProcessResult> _installWithOptions(String device, String apk, {List<String>? options, String? workDir, Duration? timeout}) => _withDevice(device, 'install', args: [if (options != null) ...options, apk], workDir: workDir, timeout: timeout ?? const Duration(seconds: 90));
  static Future<ProcessResult> install(String device, String apk, {bool downgrade = false, String? workDir, Duration? timeout}) => _installWithOptions(device, apk, options: ['-r', if (downgrade) '-d'], workDir: workDir, timeout: timeout);
  static Future<ProcessResult> installToAddress(String ipAddress, int port, String apk, {bool downgrade = false, String? workDir, Duration? timeout}) => install(_toName(ipAddress, port), apk, downgrade: downgrade, workDir: workDir, timeout: timeout);
  static Future<ProcessResult> installToWSA(String apk, {bool downgrade = false, String? workDir, Duration? timeout}) => install(deviceName, apk, downgrade: downgrade, workDir: workDir, timeout: timeout);

  static Future<ProcessResult> _installMultipleWithOptions(String device, List<String> apkFiles, {List<String>? options, String? workDir, Duration? timeout}) => _withDevice(device, 'install-multiple', args: [if (options != null) ...options, ...apkFiles], workDir: workDir, timeout: timeout ?? const Duration(seconds: 90));
  static Future<ProcessResult> installMultiple(String device, List<String> apkFiles, {bool downgrade = false, String? workDir, Duration? timeout}) => _installMultipleWithOptions(device, apkFiles, options: ['-r', if (downgrade) '-d'], workDir: workDir, timeout: timeout);
  static Future<ProcessResult> installMultipleToAddress(String ipAddress, int port, List<String> apkFiles, {bool downgrade = false, String? workDir, Duration? timeout}) => installMultiple(_toName(ipAddress, port), apkFiles, downgrade: downgrade, workDir: workDir, timeout: timeout);
  static Future<ProcessResult> installMultipleToWSA(List<String> apkFiles, {bool downgrade = false, String? workDir, Duration? timeout}) => installMultiple(deviceName, apkFiles, downgrade: downgrade, workDir: workDir, timeout: timeout);
}