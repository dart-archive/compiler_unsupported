// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:grinder/grinder.dart' as grinder;
import 'package:unittest/unittest.dart';

import 'package:compiler_unsupported/sdk_io.dart';

import '../example/compiler.dart';

void main(List<String> args) {
  Directory sdkDir = grinder.getSdkDir(args);

  if (sdkDir == null) {
    print('Unable to locate the Dart SDK.');
    print('Please set the DART_SDK environment variable or pass --dart-sdk '
        '<path> into this script.');
    exit(1);
  }

  DartSdk sdk = new DartSdkIO();
  print('Using SDK at ${sdk.location}; version ${sdk.version}.');
  print('');

  group('compiler', () {
    Compiler compiler;

    setUp(() {
      compiler = new Compiler(sdk);
    });

    test('helloworld', () {
      return compiler.compile(sampleCode).then((CompilationResults results) {
        expect(results.success, true);
        expect(results.hasOutput, true);
        expect(results.getOutput(), isNotEmpty);
      });
    });

    test('helloworld html', () {
      return compiler.compile(sampleCodeWeb).then((CompilationResults results) {
        expect(results.success, true);
        expect(results.hasOutput, true);
        expect(results.getOutput(), isNotEmpty);
      });
    });

    test('helloworld html async', () {
      return compiler.compile(sampleCodeAsync).then((CompilationResults results) {
        expect(results.success, true);
        expect(results.hasOutput, true);
        expect(results.getOutput(), isNotEmpty);
      });
    });

    test('handles errors', () {
      return compiler.compile(hasErrors).then((CompilationResults results) {
        expect(results.success, false);
        expect(results.hasOutput, false);
        expect(results.getOutput(), isEmpty);
      });
    });
  });
}

final String sampleCode = """
void main() {
  print("hello");
}
""";

final String sampleCodeWeb = """
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:html';
import 'dart:isolate';
import 'dart:js';
import 'dart:math';

void main() {
  print("hello");
  querySelector('#foo').text = 'bar';
}
""";

final String sampleCodeAsync = """
import 'dart:async';
import 'dart:html';

void main() async {
  print("hello");
  querySelector('#foo').text = 'bar';
  var foo = await HttpClient.get('http://www.google.com');
}
""";

final String hasErrors = """
void main() {
  prints("hello")
}
""";
