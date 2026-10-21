// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:wsa_pacman/windows/nt_io.dart';
import 'package:wsa_pacman/windows/win_io.dart';
import 'package:wsa_pacman/windows/win_reg.dart';

class WSAStatus {
  static late final _WSA_CLIENT_MUTEX = TEXT(r"{42CEB0DF-325A-4FBE-BBB6-C259A6C3F0BB}");
  static LPWSTR REG_VOLATILE_STORE = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\HostComputeService\\VolatileStore\\ComputeSystem\\".normalizedRegKey!.toNativeUtf16();
  static int? REG_VOLATILE_STORE_KEY;
  static String? WSA_VM_UUID;

  /// Checks if the WsaService Windows Service is running
  static bool get isServiceRunning {
    final scm = OpenSCManager(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (scm == 0) return false;
    final lpServiceName = TEXT('WsaService');
    final service = OpenService(scm, lpServiceName, SERVICE_QUERY_STATUS);
    free(lpServiceName);
    if (service == 0) {
      CloseServiceHandle(scm);
      return false;
    }
    final status = calloc<SERVICE_STATUS_PROCESS>();
    final bytesNeeded = calloc<DWORD>();
    bool running = false;
    try {
      if (QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, status.cast(), sizeOf<SERVICE_STATUS_PROCESS>(), bytesNeeded) != 0) {
        running = status.ref.dwCurrentState == SERVICE_RUNNING;
      }
    } finally {
      free(status);
      free(bytesNeeded);
      CloseServiceHandle(service);
      CloseServiceHandle(scm);
    }
    return running;
  }

  /// Checks if WSA is booted (With this status, it may still be in sleep mode)
  static bool get isBooted => isServiceRunning || WinIO.findMutexWstr(_WSA_CLIENT_MUTEX);

  /// Checks if WSA is running (VM actively executing in HCS or gralloc/latte)
  static bool get isRunning {
    if (!isBooted) return false;
    REG_VOLATILE_STORE_KEY ??= WinReg.openKeyLp(RegHKey.HKEY_LOCAL_MACHINE, REG_VOLATILE_STORE);
    if (REG_VOLATILE_STORE_KEY == null) return isServiceRunning;

    int? sessionId = NtIO.SESSION_ID;
    String? wsaVmUUID = WSA_VM_UUID;
    List<String> runningVMs = wsaVmUUID == null ? WinReg.listSubkeys(REG_VOLATILE_STORE_KEY!, 36) : [wsaVmUUID];

    if (runningVMs.isNotEmpty) {
      if (sessionId == null) return true;
      for (String uuid in runningVMs) {
        bool isSubsystemVMRunning = NtIO.openSection("\\Sessions\\$sessionId\\BaseNamedObjects\\WSL\\$uuid\\latte\\gralloc_0", false);
        if (isSubsystemVMRunning) {
          WSA_VM_UUID = uuid;
          return true;
        }
      }
      WSA_VM_UUID = runningVMs.first;
      return true;
    }
    WSA_VM_UUID = null;
    return false;
  }
}