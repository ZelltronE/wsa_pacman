// ignore_for_file: curly_braces_in_flow_control_structures

import 'dart:async';
import 'dart:developer';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';
import 'package:meta/meta.dart';

class _IsolateMessage<E extends Enum> {
  final E flag;
  final bool value;
  _IsolateMessage(this.flag, this.value);
}

class IsolateRef<O, FLAGS extends Enum> {
  final Completer<SendPort> _uiToIsolatePortCompleter = Completer<SendPort>();
  final ReceivePort _uiReceivePort;
  Isolate? _isolate;

  IsolateRef._(this._uiReceivePort) {
    _uiReceivePort.listen((message) {
      if (message is VoidCallback) {
        message();
      } else if (message is SendPort) {
        if (!_uiToIsolatePortCompleter.isCompleted) {
          _uiToIsolatePortCompleter.complete(message);
        }
      }
    });
  }

  void sendFlag(FLAGS flag, bool value) async {
    final port = await _uiToIsolatePortCompleter.future;
    port.send(_IsolateMessage(flag, value));
  }

  void dispose() {
    _uiReceivePort.close();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class _WorkerInitParams<O, FLAGS extends Enum> {
  final O data;
  final SendPort isolateToUiPort;
  final IsolateRunner<O, FLAGS> runner;
  _WorkerInitParams(this.data, this.isolateToUiPort, this.runner);
}

void _isolateWorkerEntry<O, FLAGS extends Enum>(_WorkerInitParams<O, FLAGS> params) async {
  final workerReceivePort = ReceivePort();
  params.isolateToUiPort.send(workerReceivePort.sendPort);

  workerReceivePort.listen((message) {
    if (message is _IsolateMessage<FLAGS>) {
      IsolateRunner._flagsLock.synchronized(() {
        IsolateRunner._flags.putIfAbsent(message.flag, () => Completer()).complete(message.value);
      });
    }
  });

  IsolateRunner._data = params.data;
  IsolateRunner._isolateToUiPort = params.isolateToUiPort;
  try {
    await params.runner.run();
  } catch (e, st) {
    log("Unhandled error in worker isolate: $e\n$st");
  }
}

/// Simplifies running an isolate
/// Allows running a callback in the UI thread
/// Allows waiting for a signal from the UI thread
/// Most fields are static not to be caught up in the executeInUi method
abstract class IsolateRunner<O, FLAGS extends Enum> {
  static late final _flags = <Enum, Completer<bool>>{};
  static late final _flagsLock = Lock();
  static late dynamic _data;
  static late SendPort _isolateToUiPort;

  /// Data passed to the start method
  @nonVirtual O get data => _data as O;
  /// Main runner, must be overridden
  @visibleForOverriding FutureOr<void> run();
  /// Executed in the UI thread after starting the isolate
  FutureOr<void> postStartCallback(IsolateRef<O, FLAGS> isolate) {}
  /// Waits for a flag from the UI thread with a fallback timeout to avoid deadlocks
  @nonVirtual Future<bool> waitFlag(FLAGS flag, [Duration timeout = const Duration(seconds: 2)]) async {
    final completer = await _flagsLock.synchronized(() => _flags.putIfAbsent(flag, () => Completer<bool>()));
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } catch (_) {
      return false;
    }
  }
  /// Executes a callback in the UI thread
  /// Will load all local variables in the current scope if one is referenced, therefore use carefully
  @nonVirtual void executeInUi(VoidCallback callback) => _isolateToUiPort.send(callback);

  @nonVirtual
  IsolateRef<O, FLAGS> start(O data) => IsolateRunner._start(this, data);

  /// Starts a process to read apk data
  static IsolateRef<O, FLAGS> _start<O, FLAGS extends Enum>(IsolateRunner<O, FLAGS> runner, O data) {
    final uiReceivePort = ReceivePort();
    final isolateRef = IsolateRef<O, FLAGS>._(uiReceivePort);

    Isolate.spawn<_WorkerInitParams<O, FLAGS>>(
      _isolateWorkerEntry,
      _WorkerInitParams(data, uiReceivePort.sendPort, runner),
    ).then((isolate) {
      isolateRef._isolate = isolate;
    }).catchError((error, stackTrace) {
      log("Failed to spawn isolate: $error\n$stackTrace");
    });

    runner.postStartCallback(isolateRef);
    return isolateRef;
  }
}
