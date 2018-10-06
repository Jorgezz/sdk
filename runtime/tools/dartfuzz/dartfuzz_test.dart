// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:args/args.dart';

import 'dartfuzz.dart';

const debug = false;
const sigkill = 9;
const timeout = 30; // in seconds

// Exit code of running a test.
enum ResultCode { success, timeout, error }

/// Result of running a test.
class TestResult {
  const TestResult(this.code, this.output);
  final ResultCode code;
  final String output;
}

/// Command runner.
TestResult runCommand(List<String> cmd, Map<String, String> env) {
  // TODO: use Dart API for some of the modes?
  ProcessResult res = Process.runSync(
      'timeout', ['-s', '$sigkill', '$timeout'] + cmd,
      environment: env);
  if (debug) {
    print('\nrunning $cmd yields:\n'
        '${res.exitCode}\n${res.stdout}\n${res.stderr}\n');
  }
  if (res.exitCode == -sigkill) {
    return new TestResult(ResultCode.timeout, res.stdout);
  } else if (res.exitCode != 0) {
    return new TestResult(ResultCode.error, res.stdout);
  }
  return new TestResult(ResultCode.success, res.stdout);
}

/// Abstraction for running one test in a particular mode.
abstract class TestRunner {
  TestResult run();
  String description;

  // Factory.
  static TestRunner getTestRunner(
      String mode, String top, String tmp, Map<String, String> env) {
    if (mode.startsWith('jit'))
      return new TestRunnerJIT(getTag(mode), top, tmp, env);
    if (mode.startsWith('aot'))
      return new TestRunnerAOT(getTag(mode), top, tmp, env);
    if (mode.startsWith('kbc'))
      return new TestRunnerKBC(mode, getTag(mode), top, tmp, env);
    if (mode.startsWith('js')) return new TestRunnerJS(top, tmp, env);
    throw ('unknown runner in mode: $mode');
  }

  // Convert mode to tag.
  static String getTag(String mode) {
    if (mode.endsWith('debug-ia32')) return 'DebugIA32';
    if (mode.endsWith('debug-x64')) return 'DebugX64';
    if (mode.endsWith('debug-arm32')) return 'DebugSIMARM';
    if (mode.endsWith('debug-arm64')) return 'DebugSIMARM64';
    if (mode.endsWith('ia32')) return 'ReleaseIA32';
    if (mode.endsWith('x64')) return 'ReleaseX64';
    if (mode.endsWith('arm32')) return 'ReleaseSIMARM';
    if (mode.endsWith('arm64')) return 'ReleaseSIMARM64';
    throw ('unknown tag in mode: $mode');
  }
}

/// Concrete test runner of Dart JIT.
class TestRunnerJIT implements TestRunner {
  TestRunnerJIT(String tag, String top, String tmp, Map<String, String> e) {
    description = 'JIT-${tag}';
    dart = '$top/out/$tag/dart';
    fileName = '$tmp/fuzz.dart';
    env = e;
  }

  TestResult run() {
    return runCommand([dart, fileName], env);
  }

  String description;
  String dart;
  String fileName;
  Map<String, String> env;
}

/// Concrete test runner of Dart AOT.
class TestRunnerAOT implements TestRunner {
  TestRunnerAOT(String tag, String top, String tmp, Map<String, String> e) {
    description = 'AOT-${tag}';
    precompiler = '$top/pkg/vm/tool/precompiler2';
    dart = '$top/pkg/vm/tool/dart_precompiled_runtime2';
    fileName = '$tmp/fuzz.dart';
    snapshot = '$tmp/snapshot';
    env = Map<String, String>.from(e);
    env['DART_CONFIGURATION'] = tag;
  }

  TestResult run() {
    TestResult result = runCommand([precompiler, fileName, snapshot], env);
    if (result.code != ResultCode.success) {
      return result;
    }
    return runCommand([dart, snapshot], env);
  }

  String description;
  String precompiler;
  String dart;
  String fileName;
  String snapshot;
  Map<String, String> env;
}

/// Concrete test runner of bytecode.
class TestRunnerKBC implements TestRunner {
  TestRunnerKBC(
      String mode, String tag, String top, String tmp, Map<String, String> e) {
    generate = '$top/pkg/vm/tool/gen_kernel';
    platform = '--platform=$top/out/$tag/vm_platform_strong.dill';
    dill = '$tmp/out.dill';
    dart = '$top/out/$tag/dart';
    fileName = '$tmp/fuzz.dart';
    env = e;
    cmd = [dart];
    if (mode.startsWith('kbc-int')) {
      description = 'KBC-INT-${tag}';
      cmd += ['--enable-interpreter', '--compilation-counter-threshold=-1'];
    } else if (mode.startsWith('kbc-mix')) {
      description = 'KBC-MIX-${tag}';
      cmd += ['--enable-interpreter'];
    } else if (mode.startsWith('kbc-cmp')) {
      description = 'KBC-CMP-${tag}';
      cmd += ['--use-bytecode-compiler'];
    } else {
      throw ('unknown KBC mode: $mode');
    }
    cmd += [dill];
  }

  TestResult run() {
    TestResult result = runCommand(
        [generate, '--gen-bytecode', platform, '-o', dill, fileName], env);
    if (result.code != ResultCode.success) {
      return result;
    }
    return runCommand(cmd, env);
  }

  String description;
  String generate;
  String platform;
  String dill;
  String dart;
  String fileName;
  List<String> cmd;
  Map<String, String> env;
}

/// Concrete test runner of Dart2JS.
class TestRunnerJS implements TestRunner {
  TestRunnerJS(String top, String tmp, Map<String, String> e) {
    description = 'Dart2JS';
    dart2js = '$top/out/ReleaseX64/dart-sdk/bin/dart2js';
    fileName = '$tmp/fuzz.dart';
    js = '$tmp/out.js';
    env = e;
  }

  TestResult run() {
    TestResult result = runCommand([dart2js, fileName, '-o', js], env);
    if (result.code != ResultCode.success) {
      return result;
    }
    return runCommand(['nodejs', js], env);
  }

  String description;
  String dart2js;
  String fileName;
  String js;
  Map<String, String> env;
}

/// Class to run fuzz testing.
class DartFuzzTest {
  DartFuzzTest(this.env, this.repeat, this.trueDivergence, this.showStats,
      this.top, this.mode1, this.mode2);

  bool run() {
    setup();

    print('\n${isolate}: start');
    if (showStats) {
      showStatistics();
    }

    for (int i = 0; i < repeat; i++) {
      numTests++;
      seed = rand.nextInt(1 << 32);
      generateTest();
      runTest();
      if (showStats) {
        showStatistics();
      } else if ((i & 31) == 31) {
        print('\n${isolate}: busy @${numTests}....');
      }
    }

    print('\n${isolate}: done');
    showStatistics();
    print('');

    cleanup();
    return numDivergences == 0;
  }

  void setup() {
    rand = new Random();
    tmpDir = Directory.systemTemp.createTempSync('dart_fuzz');
    fileName = '${tmpDir.path}/fuzz.dart';
    runner1 = TestRunner.getTestRunner(mode1, top, tmpDir.path, env);
    runner2 = TestRunner.getTestRunner(mode2, top, tmpDir.path, env);
    isolate = 'Isolate (${tmpDir.path}) '
        '${runner1.description} - ${runner2.description}';

    numTests = 0;
    numSuccess = 0;
    numNotRun = 0;
    numTimeOut = 0;
    numDivergences = 0;
  }

  void cleanup() {
    tmpDir.delete(recursive: true);
  }

  void showStatistics() {
    stdout.write('\rTests: $numTests Success: $numSuccess Not-Run: '
        '$numNotRun: Time-Out: $numTimeOut Divergences: $numDivergences');
  }

  void generateTest() {
    final file = new File(fileName).openSync(mode: FileMode.write);
    new DartFuzz(seed, file).run();
    file.closeSync();
  }

  void runTest() {
    TestResult result1 = runner1.run();
    TestResult result2 = runner2.run();
    checkDivergence(result1, result2);
  }

  void checkDivergence(TestResult result1, TestResult result2) {
    if (result1.code == result2.code) {
      // No divergence in result code.
      switch (result1.code) {
        case ResultCode.success:
          // Both were successful, inspect output.
          if (result1.output == result2.output) {
            numSuccess++;
          } else {
            reportDivergence(result1, result2, true);
          }
          break;
        case ResultCode.timeout:
          // Both had a time out.
          numTimeOut++;
          break;
        case ResultCode.error:
          // Both had an error.
          numNotRun++;
          break;
      }
    } else {
      // Divergence in result code.
      if (trueDivergence) {
        // When only true divergences are requested, any divergence
        // with at least one time out is treated as a regular time out.
        if (result1.code == ResultCode.timeout ||
            result2.code == ResultCode.timeout) {
          numTimeOut++;
          return;
        }
      }
      reportDivergence(result1, result2, false);
    }
  }

  void reportDivergence(
      TestResult result1, TestResult result2, bool outputDivergence) {
    numDivergences++;
    print('\n${isolate}: !DIVERGENCE! $version:$seed');
    if (outputDivergence) {
      print('out1:\n${result1.output}\nout2:\n${result2.output}\n');
    }
  }

  // Context.
  final Map<String, String> env;
  final int repeat;
  final bool trueDivergence;
  final bool showStats;
  final String top;
  final String mode1;
  final String mode2;

  // Test.
  Random rand;
  Directory tmpDir;
  String fileName;
  TestRunner runner1;
  TestRunner runner2;
  String isolate;
  int seed;

  // Stats.
  int numTests;
  int numSuccess;
  int numNotRun;
  int numTimeOut;
  int numDivergences;
}

/// Class to start fuzz testing session.
class DartFuzzTestSession {
  DartFuzzTestSession(this.isolates, this.repeat, this.trueDivergence,
      this.showStats, String tp, this.mode1, this.mode2)
      : top = getTop(tp) {}

  start() async {
    print('\n**\n**** Dart Fuzz Testing Session\n**\n');
    print('Fuzz Version    : ${version}');
    print('Isolates        : ${isolates}');
    print('Tests           : ${repeat}');
    print('True Divergence : ${trueDivergence}');
    print('Show Stats      : ${showStats}');
    print('Dart Dev        : ${top}');
    // Fork.
    List<ReceivePort> ports = new List();
    for (int i = 0; i < isolates; i++) {
      ReceivePort r = new ReceivePort();
      ports.add(r);
      port = r.sendPort;
      await Isolate.spawn(run, this);
    }
    // Join.
    bool success = true;
    for (int i = 0; i < isolates; i++) {
      var x = await ports[i].first;
      success = success && x;
    }
    if (success) {
      print('\nsuccess\n');
    } else {
      print('\nfailure\n');
      exitCode = 1;
    }
  }

  static run(DartFuzzTestSession session) {
    bool success = false;
    try {
      final m1 = getMode(session.mode1, null);
      final m2 = getMode(session.mode2, m1);
      final fuzz = new DartFuzzTest(Platform.environment, session.repeat,
          session.trueDivergence, session.showStats, session.top, m1, m2);
      success = fuzz.run();
    } catch (e) {
      print('Isolate: $e');
    }
    session.port.send(success);
  }

  // Picks a top directory (command line, environment, or current).
  static String getTop(String top) {
    if (top == null || top == '') {
      top = Platform.environment['DART_TOP'];
    }
    if (top == null || top == '') {
      top = Directory.current.path;
    }
    return top;
  }

  // Picks a mode (command line or random).
  static String getMode(String mode, String other) {
    // Random when not set.
    if (mode == null || mode == '') {
      // Pick a mode at random (cluster), different from other.
      const cluster_modes = 16;
      Random rand = new Random();
      do {
        mode = modes[rand.nextInt(cluster_modes)];
      } while (mode == other);
    }
    // Verify mode.
    if (modes.contains(mode)) {
      return mode;
    }
    throw ('unknown mode: $mode');
  }

  // Context.
  final int isolates;
  final int repeat;
  final bool trueDivergence;
  final bool showStats;
  final String top;
  final String mode1;
  final String mode2;

  // Passes each port to isolate.
  SendPort port;

  // Supported modes.
  static const List<String> modes = [
    // Cluster options:
    'jit-debug-ia32',
    'jit-debug-x64',
    'jit-debug-arm32',
    'jit-debug-arm64',
    'jit-ia32',
    'jit-x64',
    'jit-arm32',
    'jit-arm64',
    'aot-debug-x64',
    'aot-x64',
    'kbc-int-debug-x64',
    'kbc-cmp-debug-x64',
    'kbc-mix-debug-x64',
    'kbc-int-x64',
    'kbc-cmp-x64',
    'kbc-mix-x64',
    // Times out often:
    'aot-arm64',
    'aot-debug-arm64',
    // Too many divergences (due to arithmetic):
    'js'
  ];
}

/// Main driver for a fuzz testing session.
main(List<String> arguments) {
  // Set up argument parser.
  final parser = new ArgParser()
    ..addOption('isolates', help: 'number of isolates to use', defaultsTo: '1')
    ..addOption('repeat', help: 'number of tests to run', defaultsTo: '1000')
    ..addFlag('true-divergence',
        negatable: true, help: 'only report true divergences', defaultsTo: true)
    ..addFlag('show-stats',
        negatable: true, help: 'show session statistics', defaultsTo: true)
    ..addOption('dart-top', help: 'explicit value for \$DART_TOP')
    ..addOption('mode1', help: 'execution mode 1')
    ..addOption('mode2', help: 'execution mode 2')
    // Undocumented options for cluster runs.
    ..addOption('shards',
        help: 'number of shards used in cluster run', defaultsTo: '1')
    ..addOption('shard', help: 'shard id in cluster run', defaultsTo: '1');

  // Starts fuzz testing session.
  try {
    final results = parser.parse(arguments);
    final shards = int.parse(results['shards']);
    final shard = int.parse(results['shard']);
    if (shards > 1) {
      print('\nSHARD $shard OF $shards');
    }
    new DartFuzzTestSession(
            int.parse(results['isolates']),
            int.parse(results['repeat']),
            results['true-divergence'],
            results['show-stats'],
            results['dart-top'],
            results['mode1'],
            results['mode2'])
        .start();
  } catch (e) {
    print('Usage: dart dartfuzz_test.dart [OPTIONS]\n${parser.usage}\n$e');
    exitCode = 255;
  }
}
