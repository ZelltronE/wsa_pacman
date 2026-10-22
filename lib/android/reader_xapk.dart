// ignore_for_file: non_constant_identifier_names, curly_braces_in_flow_control_structures, constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:collection/collection.dart';

import 'package:flutter/cupertino.dart';
import 'package:wsa_pacman/android/adb_install_error.dart';
import 'package:wsa_pacman/android/android_utils.dart';
import 'package:wsa_pacman/android/permissions.dart';
import 'package:wsa_pacman/android/reader_apk.dart';
import 'package:wsa_pacman/global_state.dart';
import 'package:wsa_pacman/io/isolate_runner.dart';
import 'package:wsa_pacman/main.dart';
import 'package:wsa_pacman/utils/misc_utils.dart';
import 'package:wsa_pacman/proto/manifest_xapk.pb.dart';
import 'package:wsa_pacman/utils/wsa_utils.dart';
import 'package:wsa_pacman/windows/win_io.dart';
import 'package:wsa_pacman/windows/win_path.dart';
import 'package:path/path.dart' as path;

enum Architecture {
  amd64, i386, aarch64, arm, ppc64, ppc
}

extension Architectures on Architecture {
  static late final fullRegex = '(${[for (final arch in Architecture.values) for (final label in arch.labels) label].join('|')})';
  get regex => '(${[for (final label in labels) label].join('|')})';
  List<String> get labels => (){switch (this) {
    case Architecture.i386: return ["i386", "i686", "i586", "i486", "x86"];
    case Architecture.amd64: return ["x86_64", "amd64"];
    case Architecture.arm: return ["aarch32", "arm"];
    case Architecture.aarch64: return ["arm64", "aarch64"];
    case Architecture.ppc: return ["powerpc", "ppc"];
    case Architecture.ppc64: return ["powerpc64", "ppc64"];
  }}();
}

class XapkReader extends IsolateRunner<String, APK_READER_FLAGS> {
  static int _versionCode = 0;
  static late Future<Archive> _xapkArchive;
  static Directory? _xapkTempDir;

  static Directory _getOrCreateTempDir() {
    if (_xapkTempDir != null && _xapkTempDir!.existsSync()) {
      return _xapkTempDir!;
    }
    final baseDir = Directory(WinPath.tempSubdir);
    if (!baseDir.existsSync()) {
      baseDir.createSync(recursive: true);
    }
    _xapkTempDir = baseDir.createTempSync("XAPK-Extracted@${pid}_${DateTime.now().millisecondsSinceEpoch}@");
    return _xapkTempDir!;
  }

  Future<Archive> _initArchiveFile(File file) async => ZipDecoder().decodeBuffer(InputFileStream(file.path));
  void _initArchive() {
    File file = File(data);
    _xapkArchive = _initArchiveFile(file);
  }

  static ManifestXapk _decodeManifest(List<int> bytes) => ManifestXapk.create()
    ..mergeFromProto3Json(utf8.decoder.fuse(json.decoder).convert(bytes));

  static Future<List<ProcessResult>> copyApkResources(List<ManifestXapk_ApkExpansion> expansions, String workingDir, String ipAddress, int port) => Future.wait(() sync* {
    int index = 0;
    for (ManifestXapk_ApkExpansion exp in expansions) {
      if (exp.installPath.isEmpty) exp.installPath = exp.file;
      final tempName = '${path.basename(workingDir)}@${index++}';
      final resourceName = path.basename(exp.installPath);
      final resourceDir = '${exp.installPath.startsWith('/') ? '' : '/sdcard/'}${path.dirname(exp.installPath)}';
      yield ADBUtils.pushToAddress(ipAddress, port, exp.file, '/sdcard/$tempName', workDir: workingDir)
          .timeout(const Duration(seconds: 30)).then((_) =>
          ADBUtils.shellToAddress(ipAddress, port, 'mkdir -p "$resourceDir"; cd "$resourceDir"; mv /sdcard/$tempName ./$resourceName')
              .timeout(const Duration(seconds: 30)));
    }
  }());

  static void installXApk(String workingDir /* tempDir */, List<String> apkFiles, List<ManifestXapk_ApkExpansion> expansions, String ipAddress, int port, AppLocalizations lang, int timeout, FileDisposeQueue disposeLock, [bool downgrade = false]) async {
    if (apkFiles.isNotEmpty) log("INSTALLING \"${apkFiles.first}\" on $ipAddress:$port...");
    disposeLock.clear();
    GState.apkInstallState.update((_) => InstallState.INSTALLING);

    // Fast check / reconnect to ensure ADB is connected to WSA
    try {
      final conn = await ADBUtils.connectAddress(ipAddress, port).timeout(const Duration(seconds: 3));
      log("Pre-install ADB connect result: exitCode=${conn.exitCode}, stdout=${conn.stdout}");
    } catch (e) {
      log("Pre-install connect check: $e");
    }

    final effectiveTimeout = Duration(seconds: timeout > 0 ? timeout : 90);
    var installation = ADBUtils.installMultipleToAddress(ipAddress, port, apkFiles, downgrade: downgrade, workDir: workingDir, timeout: effectiveTimeout);
    final resources = copyApkResources(expansions, workingDir, ipAddress, port);

    final result = await installation;
    try {
      await resources;
    } catch (e) {
      log("Error copying resources: $e");
    }

    log("EXIT CODE: ${result.exitCode}");
    log("OUTPUT: ${result.stdout}");
    log("ERROR: ${result.stderr}");

    if (result.exitCode == 0) {
      try {
        if (Directory(workingDir).existsSync()) {
          Directory(workingDir).deleteSync(recursive: true);
        }
      } catch (e) {
        log("Notice: Could not delete temp extraction dir: $e");
      }
      GState.apkInstallState.update((_) => InstallState.SUCCESS);
    } else if (result.isTimeout) {
      GState.apkInstallState.update((_) => InstallState.TIMEOUT);
      GState.errorCode.update((_) => "TIMEOUT");
      GState.errorDesc.update((_) => '${lang.installer_error_timeout}\n\n${lang.installer_warning_dirty(workingDir)}');
    } else {
      GState.apkInstallState.update((_) => InstallState.ERROR);
      final error = AdbInstallError.parse(result.stdout?.toString() ?? '', result.stderr?.toString() ?? '', lang);
      GState.errorCode.update((_) => error.code);
      GState.errorDesc.update((_) => error.description);
    }
  }

  static List<String> _getApkList(ManifestXapk manifest) {
    final archRegex = RegExp('^config\\.${Architectures.fullRegex}.*');
    final String defaultBaseName = '${manifest.packageName}.apk';
    Iterable<String> apkList;
    if (manifest.splitApks.isNotEmpty) {
      bool isBaseApk(ManifestXapk_ApkFile fileInfo) => fileInfo.id == 'base' || fileInfo.file == defaultBaseName;
      ManifestXapk_ApkFile? baseApk = manifest.splitApks.firstWhereOrNull(isBaseApk);
      if (manifest.splitApks.first == baseApk || baseApk == null) apkList = manifest.splitApks.map((e) => e.file);
      else apkList = [baseApk.file].followedBy(manifest.splitApks.whereNot(isBaseApk).map((e) => e.file));
    }
    else if (manifest.splitConfigs.isNotEmpty) {
      Iterable<String> configFiles = manifest.splitConfigs.map((e) => '$e.apk');
      apkList = manifest.splitConfigs.contains(manifest.packageName) ? configFiles : [defaultBaseName].followedBy(configFiles);
    }
    else apkList = [defaultBaseName];

    final List<String> archApkList = apkList.where((file) => archRegex.hasMatch(file)).toList();
    if (archApkList.isEmpty || archApkList.length == 1) return apkList.toList();
    apkList = apkList.whereNot((file) => archRegex.hasMatch(file));
    for (final arch in Architecture.values) {
      final regex = RegExp('^config\\.${arch.regex}.*');
      for (final file in archApkList) if (regex.hasMatch(file)) return apkList.followedBy([file]).toList();
    }
    return apkList.followedBy([apkList.first]).toList();
  }
  
  void updateManifest(ManifestXapk manifest, Set<AndroidPermission> permissions) {
    executeInUi(() {
      _versionCode = manifest.versionCode;
      GState.apkTitle.$ = manifest.name;
      GState.version.$ = manifest.versionName;
      GState.package.$ = manifest.packageName;
      GState.permissions.$ = permissions;
    });
  }

  void updateIcon(Image? image) {
    executeInUi(() async {
      if (image != null) {
        GState.apkAdaptiveNoScale.$ = true;
        GState.apkBackgroundIcon.$ = image;
        GState.apkForegroundIcon.$ = const SizedBox();
      }
      else ApkReader.setDefaultIcon(await GState.legacyIcons.whenReady());
    });
  }

  void updateInstallInfo(ManifestXapk manifest, String installDir, List<String> apkList, FileDisposeQueue disposeLock) {
    executeInUi(() {
      if (manifest.packageName.isNotEmpty) ApkReader.loadInstallType(manifest.packageName, manifest.versionCode);
      GState.installCallback.$ = (ipAddress, port, lang, timeout, [downgrade = false]) => installXApk(installDir, apkList, manifest.expansions, ipAddress, port, lang, timeout, disposeLock, downgrade);
    });
  }

  @override
  void run() async { try {
    _initArchive();
    final archive = (await _xapkArchive);
    log("LOADING MANIFEST");
    final manifestFile = archive.findFile('manifest.json');
    if (manifestFile == null) return;
    log("READING MANIFEST");
    final manifest = _decodeManifest(manifestFile.content as List<int>);
    final permissions = AndroidPermissionList.fromNames(manifest.permissions);
    updateManifest(manifest, permissions);
    String iconFile = manifest.icon.isNotEmpty ? manifest.icon : "icon.png";
    final icon = archive.findFile(iconFile);
    final image = icon != null ? Image.memory(icon.content) : null;
    updateIcon(image);

    final tempDir = _getOrCreateTempDir();
    final apkList = _getApkList(manifest);
    String installDir = tempDir.absolute.path;
    final disposeLock = FileDisposeQueue();
    
    await waitFlag(APK_READER_FLAGS.UI_LOADED);
    archive.extractAllSync(tempDir, disposeLock: disposeLock);
    updateInstallInfo(manifest, installDir, apkList, disposeLock);

    log("DIRECTORY: ${tempDir.path}");
  } catch (e, st) {
    log("Error in XapkReader.run: $e\n$st");
    if (_xapkTempDir != null && _xapkTempDir!.existsSync()) {
      try {
        _xapkTempDir!.deleteSync(recursive: true);
      } catch (_) {}
    }
  }}

  @override
  FutureOr<void> postStartCallback(IsolateRef<String, APK_READER_FLAGS> isolate) {
    late StreamSubscription sub; sub = GState.connectionStatus.stream.listen((event) async {
      String package = GState.package.$;
      InstallType? installType = GState.apkInstallType.$;
      if (GState.apkInstallType.$ == InstallType.UNKNOWN) {
        await ApkReader.loadInstallType(GState.package.$, _versionCode);
        if (GState.apkInstallType.$ != InstallType.UNKNOWN) sub.cancel();
      }
      else if (installType != null) sub.cancel();
    });
  }
}