// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library compiler_unsupported.sdk;

import 'dart:async';

/**
 * An abstraction of a Dart SDK. Concrete implementations provide a way to
 * retrieve the SDK resources at runtime.
 */
abstract class DartSdk {
  /**
   * The location of the SDK. This is a human readable string, and may not
   * coorespond to a location on disk.
   */
  String get location;

  /**
   * The verison of the SDK.
   */
  String get version;

  /**
   * Given an sdk path (`/lib/core/core.dart`), return the cooresponding SDK
   * resource.
   */
  String getSourceForPath(String path);
}

/**
 * An abstraction of a Dart SDK. Concrete implementations provide a way to
 * retrieve the SDK resources at runtime.
 */
abstract class DartSdkAsync {
  /**
   * The location of the SDK. This is a human readable string, and may not
   * coorespond to a location on disk.
   */
  String get location;

  /**
   * The verison of the SDK.
   */
  String get version;

  /**
   * Given an sdk path (`/lib/core/core.dart`), return the cooresponding SDK
   * resource.
   */
  Future<String> getSourceForPath(String path);

  /**
   * Return an list of all the file paths for the SDK.
   */
  List<String> getAllSourcePaths();
}
