import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:wsa_pacman/android/android_utils.dart';
import 'package:wsa_pacman/android/reader_bundle.dart';

void main() {
  group('AppPackageType format detection', () {
    test('correctly identifies .apk, .xapk, .apks and .apkm files', () {
      expect(AppPackageType.fromFilename('app.apk'), AppPackage.APK);
      expect(AppPackageType.fromFilename('app.xapk'), AppPackage.XAPK);
      expect(AppPackageType.fromFilename('bundle.apks'), AppPackage.APKS);
      expect(AppPackageType.fromFilename('bundle.apkm'), AppPackage.APKM);

      // Case insensitivity
      expect(AppPackageType.fromFilename('test.APKS'), AppPackage.APKS);
      expect(AppPackageType.fromFilename('test.APKM'), AppPackage.APKM);
      expect(AppPackageType.fromFilename('test.XAPK'), AppPackage.XAPK);

      // Empty or null
      expect(AppPackageType.fromFilename(null), AppPackage.NONE);
      expect(AppPackageType.fromFilename(''), AppPackage.NONE);
    });

    test('directInstall is only true for monolithic APK', () {
      expect(AppPackage.APK.directInstall, isTrue);
      expect(AppPackage.XAPK.directInstall, isFalse);
      expect(AppPackage.APKS.directInstall, isFalse);
      expect(AppPackage.APKM.directInstall, isFalse);
    });
  });

  group('SplitSelector ABI and split resolution', () {
    test('detectAbi identifies target architectures correctly', () {
      expect(SplitSelector.detectAbi('base-x86_64.apk'), 'amd64');
      expect(SplitSelector.detectAbi('split_config.x86_64.apk'), 'amd64');
      expect(SplitSelector.detectAbi('split_config.arm64_v8a.apk'), 'arm64');
      expect(SplitSelector.detectAbi('config.arm64-v8a.apk'), 'arm64');
      expect(SplitSelector.detectAbi('split_config.arm64.apk'), 'arm64');
      expect(SplitSelector.detectAbi('config.x86.apk'), 'i386');
      expect(SplitSelector.detectAbi('split_config.armeabi_v7a.apk'), 'arm32');
      expect(SplitSelector.detectAbi('split_config.armeabi-v7a.apk'), 'arm32');

      // Non-ABI files should return null
      expect(SplitSelector.detectAbi('base-master.apk'), isNull);
      expect(SplitSelector.detectAbi('base.apk'), isNull);
      expect(SplitSelector.detectAbi('split_config.en.apk'), isNull);
      expect(SplitSelector.detectAbi('config.xxhdpi.apk'), isNull);
    });

    test('findBaseApk locates primary package split', () {
      final apksFiles = [
        'splits/base-en.apk',
        'splits/base-xxhdpi.apk',
        'splits/base-master.apk',
        'splits/base-arm64_v8a.apk',
      ];
      expect(SplitSelector.findBaseApk(apksFiles), 'splits/base-master.apk');

      final apkmFiles = [
        'split_config.arm64_v8a.apk',
        'split_config.en.apk',
        'base.apk',
      ];
      expect(SplitSelector.findBaseApk(apkmFiles), 'base.apk');
    });

    test('selectSplits prioritizes x86_64 for WSA host when present', () {
      final files = [
        'splits/base-master.apk',
        'splits/base-en.apk',
        'splits/base-es.apk',
        'splits/base-xxhdpi.apk',
        'splits/base-arm64_v8a.apk',
        'splits/base-x86_64.apk',
        'splits/base-armeabi_v7a.apk',
      ];

      final selected = SplitSelector.selectSplits(files);
      expect(selected, contains('splits/base-master.apk'));
      expect(selected, contains('splits/base-x86_64.apk'));
      expect(selected, contains('splits/base-en.apk'));
      expect(selected, contains('splits/base-es.apk'));
      expect(selected, contains('splits/base-xxhdpi.apk'));

      // Incompatible / conflicting ABIs must be excluded
      expect(selected, isNot(contains('splits/base-arm64_v8a.apk')));
      expect(selected, isNot(contains('splits/base-armeabi_v7a.apk')));
    });

    test('selectSplits selects arm64 when x86_64 is not present', () {
      final files = [
        'base.apk',
        'split_config.en.apk',
        'split_config.xxhdpi.apk',
        'split_config.arm64_v8a.apk',
        'split_config.armeabi_v7a.apk',
      ];

      final selected = SplitSelector.selectSplits(files);
      expect(selected, contains('base.apk'));
      expect(selected, contains('split_config.arm64_v8a.apk'));
      expect(selected, contains('split_config.en.apk'));
      expect(selected, contains('split_config.xxhdpi.apk'));

      // Lower 32-bit ARM must be excluded
      expect(selected, isNot(contains('split_config.armeabi_v7a.apk')));
    });

    test('selectSplits preserves all non-ABI splits in universal bundle', () {
      final files = [
        'base.apk',
        'split_config.en.apk',
        'split_config.es.apk',
        'split_config.xxhdpi.apk',
      ];

      final selected = SplitSelector.selectSplits(files);
      expect(selected.length, 4);
      expect(selected, containsAll(files));
    });
  });

  group('Synthetic Bundle Archive parsing', () {
    test('APKM bundle with info.json is extracted correctly in memory', () {
      final archive = Archive();

      final infoContent = utf8.encode(json.encode({
        'pname': 'com.example.modernapp',
        'version_code': 10500,
        'version_name': '1.5.0',
        'app_name': 'Modern Test App',
        'permissions': ['android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE'],
      }));

      archive.addFile(ArchiveFile('info.json', infoContent.length, infoContent));
      archive.addFile(ArchiveFile('base.apk', 10, utf8.encode('DUMMY_BASE')));
      archive.addFile(ArchiveFile('split_config.arm64_v8a.apk', 10, utf8.encode('DUMMY_ARM')));
      archive.addFile(ArchiveFile('split_config.en.apk', 10, utf8.encode('DUMMY_EN')));

      final files = archive.files.map((f) => f.name).toList();
      final selected = SplitSelector.selectSplits(files);

      expect(selected, contains('base.apk'));
      expect(selected, contains('split_config.arm64_v8a.apk'));
      expect(selected, contains('split_config.en.apk'));
      expect(selected, isNot(contains('info.json'))); // info.json is not an APK
    });

    test('APKS bundle with splits directory is extracted correctly in memory', () {
      final archive = Archive();
      archive.addFile(ArchiveFile('toc.pb', 10, utf8.encode('DUMMY_TOC')));
      archive.addFile(ArchiveFile('splits/base-master.apk', 10, utf8.encode('DUMMY_BASE')));
      archive.addFile(ArchiveFile('splits/base-x86_64.apk', 10, utf8.encode('DUMMY_X64')));
      archive.addFile(ArchiveFile('splits/base-en.apk', 10, utf8.encode('DUMMY_EN')));

      final files = archive.files.map((f) => f.name).toList();
      final selected = SplitSelector.selectSplits(files);

      expect(selected, contains('splits/base-master.apk'));
      expect(selected, contains('splits/base-x86_64.apk'));
      expect(selected, contains('splits/base-en.apk'));
      expect(selected, isNot(contains('toc.pb')));
    });
  });
}
