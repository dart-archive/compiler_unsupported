// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:grinder/grinder.dart' as grinder;
import 'package:test/test.dart';

import 'package:compiler_unsupported/sdk_io.dart';

import '../example/compiler.dart';

void main() {
  Directory sdkDir = grinder.getSdkDir();

  if (sdkDir == null) {
    print('Unable to locate the Dart SDK.');
    print('Please set the DART_SDK environment variable.');
    exit(1);
  }

  DartSdk sdk = new DartSdkIO();
  print('Using SDK at ${sdk.location}; version ${sdk.version}.');
  print('');

  group('compile', () {
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

    test('helloworld html null aware', () {
      return compiler.compile(sampleCodeNullAware).then((CompilationResults results) {
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
import 'dart:html';

main() async {
  print("hello");
  querySelector('#foo').text = 'bar';
  var foo = await HttpRequest.getString('http://www.google.com');
  print(foo);
}
""";

final String sampleCodeNullAware = r"""
main() {
  Dog fido = new Dog('Fido');
  Dog rex = null;

  fido?.bark();
  rex?.bark();
}

class Dog {
  final String name;

  Dog(this.name);

  void bark() => print('[${name}] bark!');
}
""";

final String hasErrors = """
void main() {
  prints("hello")
}
""";
