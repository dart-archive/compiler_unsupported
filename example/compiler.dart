// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library compiler_unsupported.compiler;

import 'dart:async';
import 'dart:io';

import 'package:compiler_unsupported/compiler.dart' as compiler;
import 'package:grinder/grinder.dart' as grinder;

import 'package:compiler_unsupported/sdk_io.dart';

final String _sample = """
import 'dart:html';

void main() {
  print("hello");
  querySelector('#foo').text = 'bar';
}
""";

void main(List<String> args) {
  Directory sdkDir = grinder.getSdkDir(args);

  if (sdkDir == null) {
    print('Unable to locate the Dart SDK.');
    print('Please set the DART_SDK environment variable or pass --dart-sdk '
        '<path> into this script.');
  } else {
    DartSdk sdk = new DartSdkIO();
    print('Using SDK at ${sdk.location}; version ${sdk.version}.');
    print('');

    Compiler compiler = new Compiler(sdk);
    compiler.compile(_sample).then((CompilationResults results) {
      print(results);

      if (results.success) {
        print('');
        print(results.getOutput());
      }
    });
  }
}

/**
 * An interface to the dart2js compiler. A compiler object can process one
 * compile at a time. They are heavy-weight objects, and can be re-used once
 * a compile finishes. Subsequent compiles after the first one will be faster,
 * on the order of a 2x speedup.
 */
class Compiler {
  final DartSdk sdk;

  Compiler(this.sdk);

  /// Compile the given string and return the resulting [CompilationResults].
  Future<CompilationResults> compile(String input) {
    _CompilerProvider provider = new _CompilerProvider(sdk, input);
    _Lines lines = new _Lines(input);

    CompilationResults result = new CompilationResults(lines);

    return compiler.compile(
        provider.getInitialUri(),
        new Uri(scheme: 'sdk', path: '/'),
        new Uri(scheme: 'package', path: '/'),
        provider.inputProvider,
        result._diagnosticHandler,
        ['--no-source-maps'],
        result._outputProvider).then((_) {
      result._problems.sort();
      return result;
    });
  }
}

/// The result of a dart2js compile.
class CompilationResults {
  final StringBuffer _output = new StringBuffer();
  final List<CompilationProblem> _problems = [];
  final _Lines _lines;

  CompilationResults(this._lines);

  bool get hasOutput => _output.isNotEmpty;

  String getOutput() => _output.toString();

  List<CompilationProblem> get problems => _problems;

  /// This is true if none of the reported problems were errors.
  bool get success => !_problems.any((p) => p.severity == CompilationProblem.ERROR);

  void _diagnosticHandler(Uri uri, int begin, int end, String message,
      compiler.Diagnostic kind) {
    // Convert dart2js crash types to our error type.
    if (kind == compiler.Diagnostic.CRASH) kind = compiler.Diagnostic.ERROR;

    if (kind == compiler.Diagnostic.ERROR ||
        kind == compiler.Diagnostic.WARNING ||
        kind == compiler.Diagnostic.HINT) {
      _problems.add(new CompilationProblem._(
          uri, begin, end, message, kind, _lines));
    }
  }

  EventSink<String> _outputProvider(String name, String extension) {
    return extension == 'js' ? new _StringSink(_output) : new _NullSink();
  }

  String toString() {
    if (success) {
      return 'success!';
    } else {
      return _problems.map((p) => p.toString()).join('\n');
    }
  }
}

/// An error, warning, hint, or into associated with a [CompilationResults].
class CompilationProblem implements Comparable {
  static const int INFO = 0;
  static const int WARNING = 1;
  static const int ERROR = 2;

  /// The Uri for the compilation unit; can be `null`.
  final Uri uri;

  /// The starting (0-based) character offset; can be `null`.
  final int begin;

  /// The ending (0-based) character offset; can be `null`.
  final int end;

  int _line;

  final String message;

  final compiler.Diagnostic _diagnostic;

  CompilationProblem._(this.uri, this.begin, this.end, this.message,
      this._diagnostic, _Lines lines) {
    _line = begin == null ? 0 : lines.getLineForOffset(begin) + 1;
  }

  /// The 1-based line number.
  int get line => _line;

  String get kind => _diagnostic.name;

  int get severity {
    if (_diagnostic == compiler.Diagnostic.ERROR) return ERROR;
    if (_diagnostic == compiler.Diagnostic.WARNING) return WARNING;
    return INFO;
  }

  int compareTo(CompilationProblem other) {
    return severity == other.severity
        ? line - other.line : other.severity - severity;
  }

  String toString() {
    if (uri == null) {
      return "[${kind}] ${message}";
    } else {
      return "[${kind}] ${message} (${uri}:${line})";
    }
  }
}

class _Lines {
  List<int> _starts = [];

  _Lines(String source) {
    List<int> units = source.codeUnits;
    for (int i = 0; i < units.length; i++) {
      if (units[i] == 10) _starts.add(i);
    }
  }

  /// Return the 0-based line number.
  int getLineForOffset(int offset) {
    assert(offset != null);
    for (int i = 0; i < _starts.length; i++) {
      if (offset <= _starts[i]) return i;
    }
    return _starts.length;
  }
}

/// A sink that drains into /dev/null.
class _NullSink implements EventSink<String> {
  _NullSink();

  add(String value) { }
  void addError(Object error, [StackTrace stackTrace]) { }
  void close() { }
}

/// Used to hold the output from dart2js.
class _StringSink implements EventSink<String> {
  final StringBuffer buffer;

  _StringSink(this.buffer);

  add(String value) => buffer.write(value);
  void addError(Object error, [StackTrace stackTrace]) { }
  void close() { }
}

/// Instances of this class allow dart2js to resolve Uris to input sources.
class _CompilerProvider {
  static const String resourceUri = 'resource:/main.dart';

  final String text;
  final DartSdk sdk;

  _CompilerProvider(this.sdk, this.text);

  Uri getInitialUri() => Uri.parse(_CompilerProvider.resourceUri);

  Future<String> inputProvider(Uri uri) {
    if (uri.scheme == 'resource') {
      if (uri.toString() == resourceUri) {
        return new Future.value(text);
      }
    } else if (uri.scheme == 'sdk') {
      String contents = sdk.getSourceForPath(uri.path);

      if (contents != null) {
        return new Future.value(contents);
      }
    }

    return new Future.error('file not found');
  }
}
