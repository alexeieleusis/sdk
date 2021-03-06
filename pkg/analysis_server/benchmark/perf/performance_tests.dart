// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library server.performance;

import 'dart:async';
import 'dart:io';

import 'package:analysis_server/plugin/protocol/protocol.dart';
import 'package:unittest/unittest.dart';

import '../../test/integration/integration_tests.dart';

/**
 * Base class for analysis server performance tests.
 */
abstract class AbstractAnalysisServerPerformanceTest
    extends AbstractAnalysisServerIntegrationTest {
  /**
   * Stopwatch for timing results;
   */
  Stopwatch stopwatch = new Stopwatch();

  /**
   * Send the server an 'analysis.setAnalysisRoots' command directing it to
   * analyze [sourceDirectory].
   */
  Future setAnalysisRoot() =>
      sendAnalysisSetAnalysisRoots([sourceDirectory.path], []);

  /**
   * The server is automatically started before every test.
   */
  @override
  Future setUp() {
    onAnalysisErrors.listen((AnalysisErrorsParams params) {
      currentAnalysisErrors[params.file] = params.errors;
    });
    onServerError.listen((ServerErrorParams params) {
      // A server error should never happen during an integration test.
      fail('${params.message}\n${params.stackTrace}');
    });
    Completer serverConnected = new Completer();
    onServerConnected.listen((_) {
      expect(serverConnected.isCompleted, isFalse);
      serverConnected.complete();
    });
    return startServer().then((_) {
      server.listenToOutput(dispatchNotification);
      server.exitCode.then((_) {
        skipShutdown = true;
      });
      return serverConnected.future;
    });
  }

  /**
   * After every test, the server is stopped.
   */
  Future shutdown() async => await shutdownIfNeeded();

  /**
   * Enable [SERVER_STATUS] notifications so that [analysisFinished]
   * can be used.
   */
  Future subscribeToStatusNotifications() {
    List<Future> futures = <Future>[];
    futures.add(sendServerSetSubscriptions([ServerService.STATUS]));
    return Future.wait(futures);
  }
}

class AbstractTimingTest extends AbstractAnalysisServerPerformanceTest {
  Future init(String source) async {
    await super.setUp();
    sourceDirectory = new Directory(source);
    return subscribeToStatusNotifications();
  }
}
