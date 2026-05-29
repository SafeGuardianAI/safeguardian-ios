#!/usr/bin/env bash
# Style and structure checks not covered by SwiftFormat or the agent name linter.
# Run from the repo root.

set -euo pipefail

FAILED=0

# 1. No semicolons used to join multiple statements on one line.
#    Single semicolons in for/while are acceptable; joined statements (let x = ...; let y = ...) are not.
while IFS= read -r -d '' file; do
    # Flag only `let x = ...; let y = ...` or `var x = ...; var y = ...` joins at statement level.
    # `guard ... else { action; return }` is idiomatic and excluded by requiring the semicolon
    # to be followed by let/var (assignment statements, not guard/return in a block).
    if grep -nE '^\s*(let|var)\s+\w.*;\s+(let|var)\s+\w' "$file" 2>/dev/null; then
        echo "ERROR: multiple let/var statements joined by semicolon in $file"
        FAILED=1
    fi
done < <(find SafeGuardian SafeGuardianTests -name "*.swift" -not -path "*/.build/*" -print0 2>/dev/null)

# 2. Tool files in Tools/ must each define exactly one tool (one AgentToolEntry extension func).
#    Files that define multiple tool factory functions are grouping violations.
TOOLS_DIR="SafeGuardian/Features/nova/Tools"
if [ -d "$TOOLS_DIR" ]; then
    while IFS= read -r -d '' file; do
        basename=$(basename "$file")
        # Skip the infrastructure files that are allowed to define multiple things.
        case "$basename" in
            AgentTool.swift|AgentToolRegistry+AllTools.swift|DeviceMetrics.swift) continue ;;
        esac
        count=$(grep -cE '^\s+static func [a-z].*\(\).*AgentToolEntry' "$file" 2>/dev/null || true)
        if [ "$count" -gt 1 ]; then
            echo "ERROR: $file defines $count tool entries — each tool should be its own file"
            FAILED=1
        fi
    done < <(find "$TOOLS_DIR" -name "*.swift" -print0 2>/dev/null)
fi

if [ "$FAILED" -eq 1 ]; then
    echo "FAILURE: style/structure violations found."
    exit 1
else
    echo "OK: style and structure checks passed."
fi
