// ignore_for_file: non_constant_identifier_names, curly_braces_in_flow_control_structures, constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:wsa_pacman/android/adb_install_error.dart';
import 'package:wsa_pacman/android/android_utils.dart';
import 'package:wsa_pacman/android/permissions.dart';
import 'package:wsa_pacman/android/reader_apk.dart';
import 'package:wsa_pacman/global_state.dart';
import 'package:wsa_pacman/io/isolate_runner.dart';
import 'package:wsa_pacman/main.dart';
import 'package:wsa_pacman/utils/wsa_utils.dart';
import 'package:wsa_pacman/windows/win_io.dart';
import 'package:wsa_pacman/windows/win_path.dart';

enum BundleType {
  APKS,
  APKM,
}

/// Selector and filter for Split APK bundles (.apks and .apkm)
class SplitSelector {
  static const List<String> _amd64Labels = ['x86_64', 'amd64'];
  static const List<String> _arm64Labels = ['arm64_v8a', 'arm64-v8a', 'arm64', 'aarch64'];
  static const List<String> _i386Labels = ['x86', 'i386', 'i686'];
  static const List<String> _arm32Labels = ['armeabi_v7a', 'armeabi-v7a', 'armeabi', 'arm', 'aarch32'];

  /// Detects whether an APK filename represents an architecture-specific split.
  /// Returns the normalized architecture key ('amd64', 'arm64', 'i386', 'arm32') or null.
  static String? detectAbi(String filename) {
    final lower = p.basename(filename).toLowerCase();
    if (!lower.endsWith('.apk')) return null;

    for (final label in _amd64Labels) {
      if (_hasWord(lower, label)) return 'amd64';
    }
    for (final label in _arm64Labels) {
      if (_hasWord(lower, label)) return 'arm64';
    }
    for (final label in _i386Labels) {
      if (_hasWord(lower, label)) return 'i386';
    }
    for (final label in _arm32Labels) {
      if (_hasWord(lower, label)) return 'arm32';
    }
    return null;
  }

  static bool _hasWord(String text, String word) {
    final pattern = RegExp('(^|[._\\-])${RegExp.escape(word)}([._\\-]|\\.apk\$)');
    return pattern.hasMatch(text);
  }

  /// Locates the candidate base APK from a list of archive entries.
  static String? findBaseApk(List<String> files) {
    final apkFiles = files.where((f) => f.toLowerCase().endsWith('.apk')).toList();
    if (apkFiles.isEmpty) return null;

    // 1. Exact base matches (base.apk, base-master.apk, splits/base-master.apk, etc.)
    for (final f in apkFiles) {
      final name = p.basename(f).toLowerCase();
      if (name == 'base.apk' || name == 'base-master.apk' || name == 'base_master.apk') {
        return f;
      }
    }

    // 2. Starts with base-master or base. (without ABI)
    for (final f in apkFiles) {
      final name = p.basename(f).toLowerCase();
      if (name.startsWith('base-master') || (name.startsWith('base') && detectAbi(name) == null)) {
        return f;
      }
    }

    // 3. Fallback to first non-ABI APK
    for (final f in apkFiles) {
      if (detectAbi(f) == null) return f;
    }

    // 4. Ultimate fallback: first APK
    return apkFiles.first;
  }

  /// Selects the optimal set of APK splits for WSA from a bundle.
  /// Prefers x86_64, then arm64, then x86, then arm32, while retaining all
  /// non-ABI configuration splits (language, density, feature splits).
  static List<String> selectSplits(List<String> files) {
    final apkFiles = files.where((f) => f.toLowerCase().endsWith('.apk')).toList();
    if (apkFiles.isEmpty) return [];

    final baseApk = findBaseApk(apkFiles);
    final remainingApks = baseApk != null ? apkFiles.where((f) => f != baseApk).toList() : apkFiles;

    // Group remaining APKs into ABI splits and non-ABI splits
    final Map<String, List<String>> abiSplits = {
      'amd64': [],
      'arm64': [],
      'i386': [],
      'arm32': [],
    };
    final List<String> nonAbiSplits = [];

    for (final f in remainingApks) {
      final abi = detectAbi(f);
      if (abi != null && abiSplits.containsKey(abi)) {
        abiSplits[abi]!.add(f);
      } else {
        nonAbiSplits.add(f);
      }
    }

    // Select the best matching ABI for Windows Subsystem for Android (WSA)
    List<String> selectedAbiFiles = [];
    if (abiSplits['amd64']!.isNotEmpty) {
      selectedAbiFiles = abiSplits['amd64']!;
    } else if (abiSplits['arm64']!.isNotEmpty) {
      selectedAbiFiles = abiSplits['arm64']!;
    } else if (abiSplits['i386']!.isNotEmpty) {
      selectedAbiFiles = abiSplits['i386']!;
    } else if (abiSplits['arm32']!.isNotEmpty) {
      selectedAbiFiles = abiSplits['arm32']!;
    }

    final result = <String>[];
    if (baseApk != null) result.add(baseApk);
    result.addAll(selectedAbiFiles);
    result.addAll(nonAbiSplits);

    return result;
  }
}

/// Information parsed from an APK bundle (.apks / .apkm)
class BundleMetadata {
  final String packageName;
  final int versionCode;
  final String versionName;
  final String appName;
  final Set<AndroidPermission> permissions;
  final List<int>? iconBytes;

  BundleMetadata({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.appName,
    required this.permissions,
    this.iconBytes,
  });
}

/// Reads .apks and .apkm bundles on a background isolate and manages installation
class BundleReader extends IsolateRunner<String, APK_READER_FLAGS> {
  final BundleType bundleType;
  static int _versionCode = 0;
  static Directory? _tempDir;

  BundleReader(this.bundleType);

  static IsolateRef<String, APK_READER_FLAGS>? startApks(String path) =>
      BundleReader(BundleType.APKS).start(path);

  static IsolateRef<String, APK_READER_FLAGS>? startApkm(String path) =>
      BundleReader(BundleType.APKM).start(path);

  static Directory _getOrCreateTempDir(BundleType type) {
    if (_tempDir != null && _tempDir!.existsSync()) {
      return _tempDir!;
    }
    final prefix = type == BundleType.APKS ? "APKS-Extracted" : "APKM-Extracted";
    final baseDir = Directory(WinPath.tempSubdir);
    if (!baseDir.existsSync()) {
      baseDir.createSync(recursive: true);
    }
    _tempDir = baseDir.createTempSync("$prefix@${pid}_${DateTime.now().millisecondsSinceEpoch}@");
    return _tempDir!;
  }

  void updateManifest(BundleMetadata meta) {
    executeInUi(() {
      _versionCode = meta.versionCode;
      GState.apkTitle.$ = meta.appName;
      GState.version.$ = meta.versionName;
      GState.package.$ = meta.packageName;
      GState.permissions.$ = meta.permissions;
    });
  }

  void updateIcon(Image? image) {
    executeInUi(() async {
      if (image != null) {
        GState.apkAdaptiveNoScale.$ = true;
        GState.apkBackgroundIcon.$ = image;
        GState.apkForegroundIcon.$ = const SizedBox();
      } else {
        ApkReader.setDefaultIcon(await GState.legacyIcons.whenReady());
      }
    });
  }

  void updateInstallInfo(BundleMetadata meta, String installDir, List<String> relativeApks, FileDisposeQueue disposeLock) {
    executeInUi(() {
      if (meta.packageName.isNotEmpty) {
        ApkReader.loadInstallType(meta.packageName, meta.versionCode);
      }
      GState.installCallback.$ = (ipAddress, port, lang, timeout, [downgrade = false]) =>
          installBundle(installDir, relativeApks, ipAddress, port, lang, timeout, disposeLock, downgrade);
    });
  }

  static void installBundle(
    String workingDir,
    List<String> apkFiles,
    String ipAddress,
    int port,
    AppLocalizations lang,
    int timeout,
    FileDisposeQueue disposeLock, [
    bool downgrade = false,
  ]) async {
    if (apkFiles.isNotEmpty) log("INSTALLING BUNDLE \"${apkFiles.first}\" on $ipAddress:$port...");
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
    var installation = ADBUtils.installMultipleToAddress(
      ipAddress,
      port,
      apkFiles,
      downgrade: downgrade,
      workDir: workingDir,
      timeout: effectiveTimeout,
    );

    final result = await installation;
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

  /// Parses bundle metadata using info.json (if present) or aapt.exe badging dump on the base APK.
  static Future<BundleMetadata> _parseMetadata(Archive archive, String baseApkPath, List<int>? baseApkBytes) async {
    String? packageName;
    int? versionCode;
    String? versionName;
    String? appName;
    Set<AndroidPermission> permissions = {};
    List<int>? iconBytes;

    // Check for APKM info.json
    final infoFile = archive.findFile('info.json');
    if (infoFile != null) {
      try {
        final jsonStr = utf8.decode(infoFile.content as List<int>, allowMalformed: true);
        final dynamic jsonData = json.decode(jsonStr);
        if (jsonData is Map) {
          packageName = jsonData['pname']?.toString() ?? jsonData['package_name']?.toString();
          versionCode = int.tryParse(jsonData['version_code']?.toString() ?? '');
          versionName = jsonData['version_name']?.toString();
          appName = jsonData['app_name']?.toString() ?? jsonData['name']?.toString();
          if (jsonData['permissions'] is List) {
            final permNames = (jsonData['permissions'] as List).map((e) => e.toString()).toList();
            permissions = AndroidPermissionList.fromNames(permNames);
          }
        }
      } catch (e) {
        log("Notice: Failed parsing info.json in bundle: $e");
      }
    }

    // Check for root icon.png (common in APKM)
    final rootIcon = archive.findFile('icon.png') ?? archive.findFile('icon.webp');
    if (rootIcon != null) {
      iconBytes = rootIcon.content as List<int>;
    }

    // If metadata is incomplete, dump badging from base APK using aapt.exe
    if (packageName == null || versionCode == null || appName == null || iconBytes == null) {
      final tempBaseFile = File(p.join(WinPath.tempSubdir, "bundle_meta_base_${pid}_${DateTime.now().millisecondsSinceEpoch}.apk"));
      try {
        if (!tempBaseFile.parent.existsSync()) {
          tempBaseFile.parent.createSync(recursive: true);
        }
        if (baseApkBytes != null) {
          tempBaseFile.writeAsBytesSync(baseApkBytes);
        }

        if (tempBaseFile.existsSync()) {
          final result = await Process.run(
            '${Env.TOOLS_DIR}\\aapt.exe',
            ['dump', 'badging', tempBaseFile.path],
            stdoutEncoding: utf8,
          );

          if (result.exitCode == 0) {
            final output = result.stdout.toString();
            final pkgMatch = RegExp(r"package:\s+name='([^']*)'\s+versionCode='([^']*)'\s+versionName='([^']*)'").firstMatch(output);
            if (pkgMatch != null) {
              packageName ??= pkgMatch.group(1);
              versionCode ??= int.tryParse(pkgMatch.group(2) ?? '');
              versionName ??= pkgMatch.group(3);
            }

            final labelMatch = RegExp(r"application-label(?:-[a-zA-Z_\-]+)?:'([^']*)'").firstMatch(output);
            appName ??= labelMatch?.group(1);

            if (appName == null) {
              final appMatch = RegExp(r"application:\s+label='([^']*)'").firstMatch(output);
              appName = appMatch?.group(1);
            }

            if (permissions.isEmpty) {
              final permMatches = RegExp(r"uses-permission:\s+name='([^']*)'").allMatches(output);
              final permNames = permMatches.map((m) => m.group(1)!).toList();
              permissions = AndroidPermissionList.fromNames(permNames);
            }

            // If we don't have an icon yet, find the icon file inside the base APK
            if (iconBytes == null && baseApkBytes != null) {
              final iconMatch = RegExp(r"application-icon-(?:640|480|320|240|160):'([^']*)'").firstMatch(output) ??
                  RegExp(r"application:\s+.*icon='([^']*)'").firstMatch(output);
              final iconPath = iconMatch?.group(1);
              if (iconPath != null && !iconPath.endsWith('.xml')) {
                try {
                  final baseArchive = ZipDecoder().decodeBytes(baseApkBytes);
                  final fileEntry = baseArchive.findFile(iconPath);
                  if (fileEntry != null) {
                    iconBytes = fileEntry.content as List<int>;
                  }
                } catch (_) {}
              }
            }
          }
        }
      } catch (e) {
        log("Error dumping badging from base APK: $e");
      } finally {
        try {
          if (tempBaseFile.existsSync()) tempBaseFile.deleteSync();
        } catch (_) {}
      }
    }

    return BundleMetadata(
      packageName: packageName ?? 'unknown.package',
      versionCode: versionCode ?? 0,
      versionName: versionName ?? '1.0.0',
      appName: appName ?? p.basenameWithoutExtension(baseApkPath),
      permissions: permissions,
      iconBytes: iconBytes,
    );
  }

  @override
  void run() async {
    try {
      final file = File(data);
      log("OPENING BUNDLE ARCHIVE: ${file.path}");
      final archive = ZipDecoder().decodeBuffer(InputFileStream(file.path));

      final allFileNames = archive.files.map((f) => f.name).toList();
      final selectedApkNames = SplitSelector.selectSplits(allFileNames);
      final baseApkName = SplitSelector.findBaseApk(allFileNames);

      if (selectedApkNames.isEmpty || baseApkName == null) {
        log("No installable APK splits found in bundle: ${file.path}");
        return;
      }

      log("BASE APK: $baseApkName");
      log("SELECTED SPLITS (${selectedApkNames.length}): $selectedApkNames");

      // Extract base APK bytes for metadata extraction
      final baseEntry = archive.findFile(baseApkName);
      final baseApkBytes = baseEntry?.content as List<int>?;

      final meta = await _parseMetadata(archive, baseApkName, baseApkBytes);
      updateManifest(meta);

      final image = meta.iconBytes != null ? Image.memory(Uint8List.fromList(meta.iconBytes!)) : null;
      updateIcon(image);

      final tempDir = _getOrCreateTempDir(bundleType);
      final disposeLock = FileDisposeQueue();

      await waitFlag(APK_READER_FLAGS.UI_LOADED);

      // Extract selected splits to tempDir
      final extractedRelativeFiles = <String>[];
      for (final selectedName in selectedApkNames) {
        final entry = archive.findFile(selectedName);
        if (entry != null && entry.isFile) {
          final flatName = p.basename(entry.name);
          final targetFile = File(p.join(tempDir.path, flatName));
          targetFile.writeAsBytesSync(entry.content as List<int>);
          extractedRelativeFiles.add(flatName);
        }
      }

      updateInstallInfo(meta, tempDir.path, extractedRelativeFiles, disposeLock);
      log("BUNDLE EXTRACTION COMPLETED: ${tempDir.path}");
    } catch (e, st) {
      log("Error in BundleReader.run: $e\n$st");
      if (_tempDir != null && _tempDir!.existsSync()) {
        try {
          _tempDir!.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  }

  @override
  FutureOr<void> postStartCallback(IsolateRef<String, APK_READER_FLAGS> isolate) {
    late StreamSubscription sub;
    sub = GState.connectionStatus.stream.listen((event) async {
      final package = GState.package.$;
      InstallType? installType = GState.apkInstallType.$;
      if (GState.apkInstallType.$ == InstallType.UNKNOWN) {
        await ApkReader.loadInstallType(package, _versionCode);
        if (GState.apkInstallType.$ != InstallType.UNKNOWN) sub.cancel();
      } else if (installType != null) {
        sub.cancel();
      }
    });
  }
}
