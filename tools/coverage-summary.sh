#!/usr/bin/env bash
# Coverage summary for the kit (#56). Run AFTER `swift test --enable-code-coverage`.
#
# Prints a per-file line-coverage table plus a single "KIT COVERAGE" line meant
# to be eyeballed in CI logs across PRs. This is a TREND signal, not a gate:
# no threshold, no failing exit code on low coverage — regressions should be
# noticed, not enforced (see issue #56).
#
# Scope: Sources/TimeTrackKit + Sources/TimeTrackCLICore only.
#   - Tests/ and .build/ (dependencies) are excluded as noise.
#   - Sources/TimeTrackApp is excluded deliberately: SwiftUI view bodies inflate
#     the denominator meaninglessly, and the app layer holds no business logic
#     (CLAUDE.md invariant 3). timetrack-cli's main.swift likewise (thin shim).
#
# Works on macOS (xcrun, .xctest bundle) and Linux CI (bare llvm-cov, flat binary).
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR=".build/debug"
PROFDATA="$BUILD_DIR/codecov/default.profdata"

if [[ ! -f "$PROFDATA" ]]; then
    echo "error: $PROFDATA not found — run 'swift test --enable-code-coverage' first" >&2
    exit 1
fi

# Locate the test binary. macOS builds a .xctest bundle; Linux a flat executable.
BINARY=""
for bundle in "$BUILD_DIR"/*.xctest; do
    [[ -e "$bundle" ]] || continue
    if [[ -d "$bundle" ]]; then
        name="$(basename "$bundle" .xctest)"
        BINARY="$bundle/Contents/MacOS/$name"
    else
        BINARY="$bundle"
    fi
    break
done
if [[ -z "$BINARY" || ! -f "$BINARY" ]]; then
    echo "error: no .xctest binary under $BUILD_DIR — run 'swift test --enable-code-coverage' first" >&2
    exit 1
fi

# macOS needs llvm-cov via xcrun; the Linux swift image ships it on PATH.
if command -v xcrun >/dev/null 2>&1; then
    LLVM_COV=(xcrun llvm-cov)
else
    LLVM_COV=(llvm-cov)
fi

# Everything except the two logic targets is ignored (regex on file paths).
IGNORE='(Tests/|\.build/|Sources/TimeTrackApp/|Sources/timetrack-cli/)'

REPORT="$("${LLVM_COV[@]}" report "$BINARY" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex="$IGNORE")"

echo "$REPORT"
echo

# One glanceable line for CI logs. In llvm-cov's TOTAL row the %-valued fields
# are: region cover, functions executed, LINE cover, [branch cover if emitted —
# older llvm omits the branch columns entirely]. Picking the 3rd % field is
# stable across llvm versions, unlike counting columns from the end.
TOTAL_LINE_PCT="$(echo "$REPORT" | awk '/^TOTAL/ { n=0; for (i=1; i<=NF; i++) if ($i ~ /%$/ && ++n == 3) print $i }')"
echo "KIT COVERAGE (TimeTrackKit + TimeTrackCLICore, line): ${TOTAL_LINE_PCT}"
