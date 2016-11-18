// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * `DartSdk` implementations that use `dart:io` to retrieve the SDK contents.
 */
library compiler_unsupported.sdk_io;

import 'dart:convert' show UTF8;
import 'dart:io' show File, ZLibCodec;

import 'package:compiler_unsupported/version.dart' as sdk_version;
import 'package:path/path.dart' as ppath;

import 'sdk.dart';
export 'sdk.dart';

/**
 * This `DartSdk` implementation reads the SDK resources encoded into the
 * `compiler_unsupported` package as part of a build step. This does not rely
 * on being able to locate an SDK on disk. It _does_ need to have a .packages
 * file in the working directory
 */
class DartSdkIO implements DartSdk {
  static String _pkgPath;

  Map<String, String> _cache = {};
  ZLibCodec _zlib = new ZLibCodec();

  DartSdkIO();

  String get version => sdk_version.versionLong;

  String get location => '<built in>';

  String getSourceForPath(String path) {
    if (_cache.containsKey(path)) {
      return _cache[path];
    }

    if (path.length < 4) return null;

    if (_pkgPath == null) {
      File packageFile = new File('.packages');

      if (packageFile.existsSync()) {
        List<String> lines = packageFile.readAsLinesSync();
        String compilerLn =
          lines.firstWhere((ln) => ln.startsWith("compiler_unsupported:"));
        compilerLn =
            compilerLn.substring("compiler_unsupported:".length) + 'sdk';
        if (compilerLn.startsWith("file://")) compilerLn = compilerLn.substring(("file://").length);
        _pkgPath = compilerLn;
      }
    }
    // Remove the `/lib` dir.
    var p = _pkgPath + path.substring(4) + '_';

    File file = new File(p);

    if (file.existsSync()) {
      List bytes = file.readAsBytesSync();
      bytes = _zlib.decode(bytes);
      _cache[path] = UTF8.decode(bytes);
      return _cache[path];
    }

    return null;
  }
}

/**
 * A `DartSdk` implementation that pulls the SDK resources out of the given path
 * to an SDK.
 */
class DartSdkPath implements DartSdk {
  final String _sdkPath;

  Map<String, String> _cache = {};

  DartSdkPath(this._sdkPath);

  String get version =>
      new File(ppath.join(_sdkPath, 'version')).readAsStringSync().trim();

  String get location => _sdkPath;

  String getSourceForPath(String path) {
    if (_cache.containsKey(path)) {
      return _cache[path];
    }

    var p = _sdkPath.endsWith('/') ? '${_sdkPath}${path}' : '${_sdkPath}/${path}';
    File file = new File(p);

    if (file.existsSync()) {
      _cache[path] = file.readAsStringSync();
      return _cache[path];
    }

    return null;
  }
}
