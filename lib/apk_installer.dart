// ignore_for_file: non_constant_identifier_names, curly_braces_in_flow_control_structures

import 'dart:async';
import 'dart:io';

import 'package:wsa_pacman/android/adb_install_error.dart';
import 'package:wsa_pacman/android/android_utils.dart';
import 'package:wsa_pacman/android/permissions.dart';
import 'package:wsa_pacman/android/reader_apk.dart';
import 'package:wsa_pacman/global_state.dart';
import 'package:wsa_pacman/main.dart';
import 'package:wsa_pacman/utils/wsa_utils.dart';
import 'package:wsa_pacman/widget/smooth_list_view.dart';
import 'package:wsa_pacman/windows/win_io.dart';
import 'package:wsa_pacman/widget/adaptive_icon.dart';
import 'package:wsa_pacman/widget/flexible_info_bar.dart';
import 'package:wsa_pacman/widget/move_window_nomax.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/material.dart' as material;

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:wsa_pacman/windows/win_path.dart';

import 'dart:developer';


class ApkInstaller extends StatefulWidget {
  const ApkInstaller({Key? key}) : super(key: key);

  static void createLaunchIcon(String package, String appName) {
    WinIO.createShortcut(
      "%LOCALAPPDATA%\\Microsoft\\WindowsApps\\${Env.WSA_INFO.familyName}\\WsaClient.exe", 
      "${WinPath.desktop}\\$appName", 
      args: "/launch wsa://$package",
      icon: '%LOCALAPPDATA%\\Packages\\${Env.WSA_INFO.familyName}\\LocalState\\$package.ico');
  }

  static void installApk(String apkFile, String ipAddress, int port, AppLocalizations lang, int timeout, [bool downgrade = false]) async {
    log("INSTALLING \"$apkFile\" on $ipAddress:$port...");
    GState.apkInstallState.update((_) => InstallState.INSTALLING);

    // Fast check / reconnect to ensure ADB is connected to WSA
    try {
      final conn = await ADBUtils.connectAddress(ipAddress, port).timeout(const Duration(seconds: 3));
      log("Pre-install ADB connect result: exitCode=${conn.exitCode}, stdout=${conn.stdout}");
    } catch (e) {
      log("Pre-install connect check: $e");
    }

    final effectiveTimeout = Duration(seconds: timeout > 0 ? timeout : 90);
    var installation = ADBUtils.installToAddress(ipAddress, port, apkFile, downgrade: downgrade, timeout: effectiveTimeout);
    installation = installation.defaultError();

    var result = await installation;
    log("EXIT CODE: ${result.exitCode}");
    log("OUTPUT: ${result.stdout}");
    log("ERROR: ${result.stderr}");

    if (result.exitCode == 0) {
      GState.apkInstallState.update((_) => InstallState.SUCCESS);
    } else if (result.isTimeout) {
      GState.apkInstallState.update((_) => InstallState.TIMEOUT);
      GState.errorCode.update((_) => "TIMEOUT");
      GState.errorDesc.update((_) => lang.installer_error_timeout);
    } else {
      GState.apkInstallState.update((_) => InstallState.ERROR);
      final error = AdbInstallError.parse(result.stdout?.toString() ?? '', result.stderr?.toString() ?? '', lang);
      GState.errorCode.update((_) => error.code);
      GState.errorDesc.update((_) => error.description);
    }
  }

  @override
  _ApkInstallerState createState() => _ApkInstallerState();
}

class _ApkInstallerState extends State<ApkInstaller> {
  int index = 0;
  ToggleButtonThemeData? warningButtonTheme;
  bool createShortcut = false;
  bool startingWSA = false;
  bool pendingInstall = false;
  StreamSubscription? _connectionSub;

  @override
  void initState() {
    super.initState();
    _connectionSub = GState.connectionStatus.stream.listen((status) {
      if (status.isConnected) {
        if (startingWSA) {
          setState(() { startingWSA = false; });
        }
        if (pendingInstall) {
          pendingInstall = false;
          _doInstall();
        }
      }
    });
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    super.dispose();
  }

  void _doInstall() {
    final lang = AppLocalizations.of(context);
    if (lang == null) return;
    final ipAddress = GState.ipAddress.$;
    final port = GState.androidPort.$;
    final installTimeout = GState.installTimeout.$;
    final installType = GState.apkInstallType.$;
    final isDowngrade = installType == InstallType.DOWNGRADE;

    if (!GState.connectionStatus.$.isConnected) {
      setState(() {
        startingWSA = true;
        pendingInstall = true;
      });
      WSAUtils.launch();
      return;
    }

    if (Constants.packageType.directInstall) {
      ApkInstaller.installApk(Constants.packageFile, ipAddress, port, lang, installTimeout, isDowngrade);
    } else {
      GState.installCallback.$?.call(ipAddress, port, lang, installTimeout, isDowngrade);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final lang = AppLocalizations.of(context)!;
    final isLtr = Directionality.of(context) == TextDirection.ltr;
    Widget icon;
    String appTitle = GState.apkTitle.of(context);
    Widget? aForeground = GState.apkForegroundIcon.of(context);
    bool adaptiveNoScale = GState.apkAdaptiveNoScale.of(context);
    Widget? lIcon = GState.apkIcon.of(context);
    WSAStatusAlert connectionStatus = GState.connectionStatus.of(context);
    bool isConnected = connectionStatus.isConnected;
    InstallType? installType = GState.apkInstallType.of(context);
    InstallState installState = GState.apkInstallState.of(context);
    final mica = GState.mica.of(context);
    final theme = FluentTheme.of(context);
    if (startingWSA && isConnected) startingWSA = false;
    final autostartWSA = !startingWSA && !isConnected && GState.autostartWSA.of(context);

    if (autostartWSA) {
      startingWSA = true;
      if (!WSAUtils.launch()) setState(() {startingWSA = false;});
    }

    if (installType == InstallType.DOWNGRADE && warningButtonTheme == null) warningButtonTheme = ToggleButtonThemeData.standard(theme.copyWith(accentColor: Colors.orange));

    String package = GState.package.of(context);
    String version = GState.version.of(context);
    String activity = GState.activity.of(context);
    int installTimeout  = GState.installTimeout.of(context);
    bool isLaunchable = package.isNotEmpty && activity.isNotEmpty;

    String oldVersion = GState.oldVersion.of(context);

    String ipAddress = GState.ipAddress.of(context);
    int port = GState.androidPort.of(context);

    if (aForeground != null) icon = AdaptiveIcon(noScale: adaptiveNoScale, backColor: GState.apkBackgroundColor.of(context), background: GState.apkBackgroundIcon.of(context), foreground: aForeground, radius: GState.iconShape.of(context).radius);
    else if (lIcon != null) icon = FittedBox(child: lIcon);
    else icon = const ProgressRing();

    Widget titleWidget = Row (
      crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(child: SizedBox(width: 30.00, height: 30.00, child: icon)), const Flexible(child: SizedBox(width: 20)), Text(appTitle, style: theme.typography.bodyLarge), 
                //Spacer(), WindowButtons()
      ]
    );

    return Mica(child: moveWindow(Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      child: Column (
        crossAxisAlignment: CrossAxisAlignment.start,
        children: ((){switch(installState) {case InstallState.PROMPT: return [
          titleWidget,
          Column (
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 10),
              Text(lang.installer_message),
              const SizedBox(height: 10),
              Text((oldVersion.isNotEmpty ? lang.installer_info_version_change(oldVersion, version) : lang.installer_info_version(version)).replaceAll(' ', '\u00A0'), style: TextStyle(color: theme.resources.textFillColorDisabled), overflow: TextOverflow.ellipsis, maxLines: 1),
              Text(lang.installer_info_package(package).replaceAll(' ', '\u00A0'), style: TextStyle(color: theme.resources.textFillColorDisabled), overflow: TextOverflow.ellipsis, maxLines: 1),
            ]
          ),
          if (!isConnected)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: InfoBar(
                title: Text(startingWSA ? lang.installer_btn_starting : connectionStatus.title(lang)),
                content: Text(startingWSA ? lang.status_starting_desc : "WSA está apagado o en reposo. Pulsa 'Instalar' para encenderlo."),
                severity: startingWSA ? InfoBarSeverity.info : InfoBarSeverity.warning,
              ),
            ),
          const SizedBox(height: 10),
          Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(10), child: Container(
            //decoration: ChipTheme.of(context).decoration?.resolve({ButtonStates.focused})?.lerpTo(SnackbarTheme.of(context).decoration, 0.07),
            color: mica.disabled || theme.brightness.isDark ? theme.inactiveBackgroundColor.lerpWith(theme.scaffoldBackgroundColor, 0.65)
              : theme.scaffoldBackgroundColor.lerpWith(theme.inactiveBackgroundColor, 0.038),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 10),
            //color: Colors.red, 
            child: SmoothListView(
            //padding: const EdgeInsets.all(5),
            children: [
              for (var permission in GState.permissions.of(context)) Container(
                padding: EdgeInsets.only(right: isLtr ? 10 : 0, left: isLtr ? 0 : 10),
                child: ListTile(
                  leading: permission.icon,
                  title: Text(permission.description(lang)),
                ),
              )
            ],
          )))),
          const SizedBox(height: 20),
          //const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              noMoveWindow(Button(
                child: Text(lang.installer_btn_cancel),
                onPressed: false ? null : (){appWindow.close();},
              )),
              const SizedBox(width: 15),
              noMoveWindow(ToggleButton(
                child: Text(startingWSA ? lang.installer_btn_starting : installType?.buttonText(lang) ?? lang.installer_btn_loading),
                checked: true,
                style: installType == InstallType.DOWNGRADE ? warningButtonTheme : null,
                onChanged: startingWSA ? null : (_) {
                  if (isConnected) {
                    _doInstall();
                  } else {
                    setState(() {
                      startingWSA = true;
                      pendingInstall = true;
                    });
                    WSAUtils.launch();
                  }
                },
              )),
            ]
          )
        ];
        case InstallState.INSTALLING: return [
          titleWidget,
          const SizedBox(height: 10),
          Text(lang.installer_installing(appTitle)),
          const Spacer(),
          Row(children: const [Expanded(child: ProgressBar(strokeWidth: 6))]),
        ];
        case InstallState.SUCCESS: return [
          titleWidget,
          const SizedBox(height: 10),
          Text(lang.installer_installed(appTitle)),
          if (installType == InstallType.INSTALL) const SizedBox(height: 10),
          if (installType == InstallType.INSTALL) Checkbox(
            checked: createShortcut,
            content: Text(lang.installer_btn_checkbox_shortcut),
            onChanged: (value) => setState(() => createShortcut = value!),
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              noMoveWindow(Button(
                child: Text(lang.installer_btn_dismiss),
                onPressed: (){if (createShortcut) ApkInstaller.createLaunchIcon(package, appTitle); appWindow.close();},
              )),
              (){return isLaunchable ? const SizedBox(width: 15) : const SizedBox.shrink();}(),
              (){return isLaunchable ? noMoveWindow(ToggleButton(
                child: Text(lang.installer_btn_open),
                checked: true,
                onChanged: (_){if (createShortcut) ApkInstaller.createLaunchIcon(package, appTitle); WSAUtils.launchApp(package); appWindow.close();},
              )) : const SizedBox.shrink();}()
            ]
          )
        ];
        case InstallState.ERROR: case InstallState.TIMEOUT: return [
          titleWidget,
          const SizedBox(height: 10),
          Text(lang.installer_fail(appTitle)),
          const SizedBox(height: 10),
          FlexibleInfoBar(
            title: noMoveWindow(material.SelectableText(GState.errorCode.of(context))),
            content: noMoveWindow(material.SelectableText(GState.errorDesc.of(context))),
            severity: installState == InstallState.ERROR ? InfoBarSeverity.error : InfoBarSeverity.warning
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              noMoveWindow(Button(
                child: Text(lang.installer_btn_dismiss),
                onPressed: (){appWindow.close();},
              )),
              const SizedBox(width: 15),
              noMoveWindow(FilledButton(
                child: Text(lang.installer_btn_install),
                onPressed: () {
                  GState.apkInstallState.update((_) => InstallState.PROMPT);
                },
              )),
            ]
          )
        ];
        default: return [] as List<Widget> ;
        }})(),
      ),
    )));
  }
}