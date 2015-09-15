// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:grinder/grinder.dart';

import 'dart:io';

final Directory trunk = new Directory('trunk');

main(List<String> args) => grind(args);

@Task()
build() {
  // The sdk repo version to download.
  final String sdkTag = '1.12.1';

  trunk.createSync();

  // Download the file.
  ProcessResult result = Process.runSync('wget',
      ['https://github.com/dart-lang/sdk/archive/${sdkTag}.zip'],
      workingDirectory: 'trunk');
  if (result.exitCode != 0) fail('Error executing wget: ${result.stderr}');

  // Uncompress it.
  String fileName = 'trunk/${sdkTag}.zip';
  result = Process.runSync('unzip', ['-o', fileName, '-d', 'trunk']);
  if (result.exitCode != 0) fail('Error executing unzip: ${result.stderr}');

  // Find the trunk path - trunk/sdk-1.11.0-dev.5.4.
  Directory dartDir = joinDir(trunk, ['sdk-${sdkTag}']);

  // Get the version from the repo.
  result = Process.runSync('tools/print_version.py', [],
      workingDirectory: dartDir.path);
  if (result.exitCode != 0) {
    fail('Error executing tools/print_version.py: ${result.stderr}');
  }
  String versionLong = result.stdout.trim();
  log('Using repo at ${dartDir.path}; version ${versionLong}.');

  // Generate version file.
  String version = versionLong;
  if (version.contains('-')) version = version.substring(0, version.indexOf('-'));
  if (version.contains('+')) version = version.substring(0, version.indexOf('+'));
  File versionDest = joinFile(libDir, ['version.dart']);
  _writeDart(versionDest, '''
final String version = '${version}';
final String versionLong = '${versionLong}';
''');

  // Copy dart2js sources.
  Directory sourceDir = joinDir(dartDir, ['sdk', 'lib', '_internal']);
  Directory pkgDir = joinDir(dartDir, ['pkg']);

  copy(joinFile(pkgDir, ['compiler', 'lib', 'compiler.dart']), libDir);
  copy(joinFile(pkgDir, ['compiler', 'lib', 'compiler_new.dart']), libDir);
  copy(joinDir(pkgDir, ['compiler', 'lib', 'src']), joinDir(libDir, ['src']));
  copy(joinFile(sourceDir, ['sdk_library_metadata', 'lib', 'libraries.dart']), libDir);

  // packages
  copy(joinDir(pkgDir, ['js_ast', 'lib']), joinDir(libDir, ['_internal', 'js_ast']));
  copy(joinDir(dartDir, ['sdk', 'lib', '_internal', 'js_runtime', 'lib']), joinDir(libDir, ['_internal', 'js_runtime']));
  copy(joinDir(dartDir, ['sdk', 'lib', '_internal', 'sdk_library_metadata', 'lib']), joinDir(libDir, ['_internal', 'sdk_library_metadata']));

  // Copy sdk sources.
  _copySdk(joinDir(dartDir, ['sdk']), joinDir(libDir, ['sdk']));

  // Adjust sources.
  List replacements = [
      [
        r'package:sdk_library_metadata/libraries.dart',
        r'package:compiler_unsupported/libraries.dart'
      ],
      [
        r'package:js_runtime/',
        r'package:compiler_unsupported/_internal/js_runtime/'
      ],
      [
        r'package:js_ast/',
        r'package:compiler_unsupported/_internal/js_ast/'
      ]
  ];

  int modifiedCount = 0;
  Map<String, int> counts = {};
  for (List replacement in replacements) {
    counts[replacement[0]] = 0;
  }

  joinDir(libDir, ['src']).listSync(recursive: true).forEach((entity) {
    if (entity is File && entity.path.endsWith('.dart')) {
      String text = entity.readAsStringSync();
      String newText = text;

      for (List replacement in replacements) {
        if (newText.contains(replacement[0])) {
          counts[replacement[0]] = counts[replacement[0]] + 1;
        }
        newText = newText.replaceAll(replacement[0], replacement[1]);
      }

      if (text != newText) {
        modifiedCount++;
        entity.writeAsStringSync(newText);
      }
    }
  });

  log('Updated ${modifiedCount} package references.');
  counts.keys.forEach((s) => log('  [${s}]: ${counts[s]}'));

  // Update pubspec version and add an entry to the changelog.
  _updateVersion(versionLong);
  _updateChangelog(versionLong);
}

@Task()
analyze() {
  Analyzer.analyze([
      'tool/grind.dart',
      'lib/sdk.dart',
      'lib/version.dart',
      'example/compiler.dart'
  ]);
}

@Task('Validate that the library looks good')
@Depends(analyze)
validate() => new TestRunner().test();

@Task('Delete files copied from the dart2js sources')
clean() {
  delete(joinDir(libDir, ['sdk']));
  delete(joinDir(libDir, ['src']));
  delete(joinDir(libDir, ['_internal']));
}

void _copySdk(Directory srcDir, Directory destDir) {
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

  log('Copied ${count} sdk files.');

  delete(joinDir(destDir, ['_internal', 'pub']));
  delete(joinDir(destDir, ['_internal', 'pub_generated']));
}

void _writeDart(File file, String text) {
  String contents = '''
// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

${text}
''';

  file.writeAsStringSync(contents.trim() + '\n');
}

void _updateVersion(String version) {
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

  log('Updated pubspec.yaml to version ${version}');
}

void _updateChangelog(String version) {
  File changelogFile = new File('changelog.md');
  String text = changelogFile.readAsStringSync();

  if (!text.contains(version)) {
    String date = new DateTime.now().toString().substring(0, 10);
    int insert = text.indexOf('\n## ') + 1;

    text = text.substring(0, insert) +
        '## ${version} (${date})\n- upgraded to SDK ${version}\n\n' +
        text.substring(insert);

    changelogFile.writeAsStringSync(text);

    log('Added a new entry to the changelog.');
  }
}
