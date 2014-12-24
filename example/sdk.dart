// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library compiler_unsupported.sdk;

import 'dart:io' show File;

import 'package:path/path.dart' as ppath;

class DartSdk {
  final String sdkPath;

  Map<String, String> _cache = {};

  DartSdk(this.sdkPath);

  String get version =>
      new File(ppath.join(sdkPath, 'version')).readAsStringSync().trim();

  String getSourceForPath(String path) {
    if (_cache.containsKey(path)) {
      return _cache[path];
    }

    var p = sdkPath.endsWith('/') ? '${sdkPath}${path}' : '${sdkPath}/${path}';
    File file = new File(p);

    if (file.existsSync()) {
      _cache[path] = file.readAsStringSync();
      return _cache[path];
    }

    return null;
  }
}
