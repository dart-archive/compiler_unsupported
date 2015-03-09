# Run the from the project root. This will update the sparse checkout of the
# Dart repo, for the dart/sdk and dart/tools directories.

# Fast fail the script on failures.
set -e

pushd trunk > /dev/null
svn update --parents dart/pkg/compiler
svn update --parents dart/pkg/js_ast
svn update --parents dart/sdk
svn update --parents dart/tools

pushd dart > /dev/null
./tools/print_version.py
popd > /dev/null
popd > /dev/null
