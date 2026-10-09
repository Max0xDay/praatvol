#!/bin/bash
set -euo pipefail

minimumLinePercent=70
scriptDirectory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
applicationDirectory="$(cd -- "$scriptDirectory/.." && pwd)"
cd "$applicationDirectory"

swift test --enable-code-coverage

# #COMPLETION_DRIVE: The test bundle name follows the SwiftPM pattern <package>PackageTests.xctest.
# #SUGGEST_VERIFY: Run this script after renaming the package; the test bundle name must match.
binDirectory="$(swift build --show-bin-path)"
testBinary="$binDirectory/PraatvolPackageTests.xctest/Contents/MacOS/PraatvolPackageTests"
profileData="$binDirectory/codecov/default.profdata"

# #COMPLETION_DRIVE: python3 parses the llvm-cov JSON; macOS and the CI runner both provide it.
# #SUGGEST_VERIFY: Confirm python3 exists on the runner if the coverage step fails with "command not found".
linePercent="$(xcrun llvm-cov export -summary-only -instr-profile "$profileData" "$testBinary" Sources/PraatvolCore/*.swift \
    | python3 -c 'import json, sys; print("%.2f" % json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"])')"

printf 'PraatvolCore line coverage: %s%% (minimum %s%%)\n' "$linePercent" "$minimumLinePercent"

if awk -v measured="$linePercent" -v minimum="$minimumLinePercent" 'BEGIN { exit !(measured >= minimum) }'; then
    exit 0
fi

printf 'Line coverage %s%% is below the %s%% minimum.\n' "$linePercent" "$minimumLinePercent" >&2
exit 1
