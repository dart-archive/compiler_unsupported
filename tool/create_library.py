#!/usr/bin/env python
#
# Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.
#
# Create the compiler_unsupported package. This will copy the
# sdk/lib/_internal/compiler directory and the libraries.dart file into lib/.
#
# Usage: create_library.py

import os
import re
import shutil
import sys

from os.path import dirname, join


def ReplaceInFiles(paths, subs):
  '''Reads a series of files, applies a series of substitutions to each, and
     saves them back out. subs should be a list of (pattern, replace) tuples.'''
  for path in paths:
    contents = open(path).read()
    for pattern, replace in subs:
      contents = re.sub(pattern, replace, contents)
    dest = open(path, 'w')
    dest.write(contents)
    dest.close()


def RemoveFile(f):
  if os.path.exists(f):
    os.remove(f)


def Main(argv):
  # pkg/compiler_unsupported
  HOME = dirname(dirname(os.path.realpath(__file__)))

  # pkg/compiler_unsupported/lib
  TARGET = join(HOME, 'lib')

  # sdk/lib/_internal
  SOURCE = join(dirname(dirname(HOME)), 'sdk', 'lib', '_internal')

  # pkg
  PKG_SOURCE = join(dirname(dirname(HOME)), 'pkg')

  # clean compiler_unsupported/lib
  if not os.path.exists(TARGET):
    os.mkdir(TARGET)
  shutil.rmtree(join(TARGET, 'src'), True)
  RemoveFile(join(TARGET, 'compiler.dart'))
  RemoveFile(join(TARGET, 'libraries.dart'))

  # copy dart2js code
  shutil.copy(join(PKG_SOURCE, 'compiler', 'lib', 'compiler.dart'), TARGET)
  shutil.copy(join(SOURCE, 'libraries.dart'), TARGET)
  shutil.copytree(join(SOURCE, 'compiler'), join(TARGET, '_internal', 'compiler'))
  shutil.copytree(
      join(PKG_SOURCE, 'compiler', 'lib', 'src'),
      join(TARGET, 'src'))

  # patch up the libraries.dart and package references
  replace1 = [(
      r'package:_internal/', 
      r'package:compiler_unsupported/_internal/')]
      
  replace2 = [(
      r'package:compiler_unsupported/_internal/libraries.dart', 
      r'package:compiler_unsupported/libraries.dart')]

  for root, dirs, files in os.walk(join(TARGET, 'src')):
    for name in files:
      if name.endswith('.dart'):
        ReplaceInFiles([join(root, name)], replace1)
        ReplaceInFiles([join(root, name)], replace2)


if __name__ == '__main__':
  sys.exit(Main(sys.argv))
