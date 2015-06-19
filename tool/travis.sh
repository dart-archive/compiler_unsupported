#!/bin/bash

# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Fast fail the script on failures.
set -e

# Verify that the libraries are error free.
dartanalyzer --fatal-warnings \
  example/compiler.dart \
  lib/libraries.dart \
  lib/version.dart \
  test/all_test.dart \
  tool/grind.dart

# Run the tests.
dart test/all_test.dart
