#!/bin/bash

# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

# Fast fail the script on failures.
set -e

# TODO: Move this over to apt-get / the official Travis / Dart process.

# Get the Dart SDK.
DART_DIST=dartsdk-linux-x64-release.zip
curl http://storage.googleapis.com/dart-archive/channels/dev/release/latest/sdk/$DART_DIST > $DART_DIST
unzip $DART_DIST > /dev/null
rm $DART_DIST
export DART_SDK="$PWD/dart-sdk"
export PATH="$DART_SDK/bin:$PATH"

# Display installed versions.
dart --version

# Get our packages.
pub get

# Verify that the libraries are error free.
dartanalyzer --fatal-warnings \
  example/compiler.dart \
  lib/libraries.dart \
  lib/version.dart \
  test/all.dart \
  tool/grind.dart

# Run the tests.
dart test/all.dart
