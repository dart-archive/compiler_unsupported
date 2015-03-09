// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:grinder/grinder.dart';

import 'dart:io';

final Directory dartDir = joinDir(new Directory('trunk'), ['dart']);

// TODO: we need to include the sdk sources as well

// TODO: we'll have to encode the sources as compressed, base64'd text for cli apps

// TODO: we don't want the clients who don't need the large dartium files to
// pay the price for them

// TODO: we don't want web clients to get the code bloat associated with source
// encoded resources

void main(List<String> args) {
  task('init', defaultInit);
  task('build', build, ['init']);
  task('validate', validate);
  task('clean', clean);

  startGrinder(args);
}

void build(GrinderContext context) {
  if (!dartDir.existsSync()) {
    context.log('trunk/ dir not found.');
    context.log('Please run ./tool/co.sh and ./tool/up.sh.');
    context.fail('trunk/ dir not found');
  }

  // Get the version from the repo.
  ProcessResult result = Process.runSync('tools/print_version.py', [],
      workingDirectory: 'trunk/dart');
  if (result.exitCode != 0) {
    context.fail('Error executing tools/print_version.py: ${result.stderr}');
  }
  String versionLong = result.stdout.trim();
  context.log('Using repo at ${dartDir.path}; version ${versionLong}.');

  // Generate version file.
  String version = versionLong;
  if (version.contains('-')) version = version.substring(0, version.indexOf('-'));
  if (version.contains('+')) version = version.substring(0, version.indexOf('+'));
  File versionDest = joinFile(LIB_DIR, ['version.dart']);
  _writeDart(versionDest, '''
final String version = '${version}';
final String versionLong = '${versionLong}';
''');

  // Copy dart2js sources.
  Directory sourceDir = joinDir(dartDir, ['sdk', 'lib', '_internal']);
  Directory pkgDir = joinDir(dartDir, ['pkg']);

  copyFile(joinFile(pkgDir, ['compiler', 'lib', 'compiler.dart']), LIB_DIR,
      context);
  copyFile(joinFile(sourceDir, ['libraries.dart']), LIB_DIR, context);
  copyDirectory(joinDir(sourceDir, ['compiler']),
      joinDir(LIB_DIR, ['_internal', 'compiler']), context);
  copyDirectory(joinDir(pkgDir, ['compiler', 'lib', 'src']),
      joinDir(LIB_DIR, ['src']), context);

  // Copy js_ast into lib/src/js_ast
  copyDirectory(joinDir(pkgDir, ['js_ast', 'lib']),
      joinDir(LIB_DIR, ['src', 'js_ast']), context);

  // Copy sdk sources.
  _copySdk(joinDir(dartDir, ['sdk']), joinDir(LIB_DIR, ['sdk']), context);

  // Adjust sources.
  List replacements = [
      [
        r'package:_internal/libraries.dart',
        r'package:compiler_unsupported/libraries.dart'
      ],
      [
        r'package:_internal/',
        r'package:compiler_unsupported/_internal/'
      ],
      [
        r'package:js_ast/js_ast.dart',
        r'package:compiler_unsupported/src/js_ast/js_ast.dart'
      ]
  ];

  int modifiedCount = 0;

  joinDir(LIB_DIR, ['src']).listSync(recursive: true).forEach((entity) {
    if (entity is File && entity.path.endsWith('.dart')) {
      String text = entity.readAsStringSync();
      String newText = text;

      for (List replacement in replacements) {
        newText = newText.replaceAll(replacement[0], replacement[1]);
      }

      if (text != newText) {
        modifiedCount++;
        entity.writeAsStringSync(newText);
      }
    }
  });

  context.log('Updated ${modifiedCount} package references.');

  // Update pubspec version and add an entry to the changelog.
  _updateVersion(context, versionLong);
  _updateChangelog(context, versionLong);

}

/**
 * Validate that the library looks good.
 */
void validate(GrinderContext context) {
  Tests.runCliTests(context);
}

/**
 * Delete files copied from the dart2js sources.
 */
void clean(GrinderContext context) {
  deleteEntity(joinDir(LIB_DIR, ['sdk']), context);
  deleteEntity(joinDir(LIB_DIR, ['src']), context);
  deleteEntity(joinDir(LIB_DIR, ['_internal']), context);
}

void _copySdk(Directory srcDir, Directory destDir, GrinderContext context) {
  String srcPath = srcDir.path;
  String destPath = destDir.path;

  int count = 0;

  ZLibCodec zlib = new ZLibCodec(level: 9);

  srcDir.listSync(recursive: true, followLinks: false).forEach((entity) {
    if (entity is File && entity.path.endsWith('.dart')) {
      // Create the new path, remove the `lib/` section.
      String newPath = destPath + entity.path.substring(srcPath.length + 4) + '_';
      File f = new File(newPath);
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      List bytes = entity.readAsBytesSync();
      bytes = zlib.encode(bytes);
      new File(newPath).writeAsBytesSync(bytes, flush: true);
      count++;
    }
  });

  context.log('Copied ${count} sdk files.');

  deleteEntity(joinDir(destDir, ['_internal', 'pub']));
  deleteEntity(joinDir(destDir, ['_internal', 'pub_generated']));
}

void _writeDart(File file, String text) {
  String contents = '''
// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

${text}
''';

  file.writeAsStringSync(contents.trim() + '\n');
}

void _updateVersion(GrinderContext context, String version) {
  File pubFile = new File('pubspec.yaml');
  List lines = pubFile.readAsStringSync().split('\n');
  String output = lines.map((line) {
    if (line.startsWith('version: ')) {
      return 'version: ${version}';
    } else {
      return line;
    }
  }).join('\n');
  pubFile.writeAsStringSync(output);

  context.log('Updated pubspec.yaml to version ${version}');
}

void _updateChangelog(GrinderContext context, String version) {
  File changelogFile = new File('changelog.md');
  String text = changelogFile.readAsStringSync();

  if (!text.contains(version)) {
    String date = new DateTime.now().toString().substring(0, 10);
    int insert = text.indexOf('\n## ') + 1;

    text = text.substring(0, insert) +
        '## ${version} (${date})\n- upgraded to SDK ${version}\n\n' +
        text.substring(insert);

    changelogFile.writeAsStringSync(text);

    context.log('Added a new entry to the changelog.');
  }
}
