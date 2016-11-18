## Updating `compiler_unsupported`

- (optional) `rm -rf trunk`
- rm -rf lib/src lib/_internal lib/sdk
- update the `sdkTag` variable in tools/grind.dart
- run `dart tool/grind.dart build`
- run `dart tool/grind.dart validate`
- run `dart example/compiler.dart`

### Publishing

- run `pub publish`
- From the GitHub UI create a new release ( https://github.com/dart-lang/compiler_unsupported/releases )
