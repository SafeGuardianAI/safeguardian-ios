#!/usr/bin/env bash
# Enforces the naming rule: infrastructure files and public types may not carry
# agent names (Nova, Trek, Apex) unless they are on the explicit allowlist below.
# Run from the repo root.

set -euo pipefail

INFRA_DIRS=(
  "SafeGuardian/Features/nova"
  "SafeGuardian/Services"
  "SafeGuardian/ViewModels"
  "SafeGuardian/Utils"
  "localPackages/BitFoundation/Sources"
  "localPackages/BitLogger/Sources"
)

# Types that are explicitly allowed to carry agent names because they ARE the
# agent or its direct behavioral contract.
ALLOWLIST=(
  "NovaConfig"
  "NovaStateTick"
  "NovaBroadcaster"
  "NovaPersonalizationStore"
  "TrekAgent"
  "TrekConfig"
  "ApexAgent"
  "ApexConfig"
)

AGENT_PATTERN="(Nova|Trek|Apex)"
FAILED=0

build_allow_grep() {
  local pattern=""
  for name in "${ALLOWLIST[@]}"; do
    pattern="${pattern}|${name}"
  done
  echo "${pattern:1}"
}

ALLOW_GREP=$(build_allow_grep)

for dir in "${INFRA_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' file; do
    basename=$(basename "$file" .swift)
    # Check filename
    if echo "$basename" | grep -qE "$AGENT_PATTERN"; then
      if ! echo "$basename" | grep -qE "$ALLOW_GREP"; then
        echo "ERROR: agent name in filename: $file"
        FAILED=1
      fi
    fi
    # Check public type declarations (class, struct, enum, protocol, actor)
    while IFS= read -r line; do
      type_name=$(echo "$line" | grep -oE "(class|struct|enum|protocol|actor)\s+\w+" | awk '{print $2}')
      [ -z "$type_name" ] && continue
      if echo "$type_name" | grep -qE "$AGENT_PATTERN"; then
        if ! echo "$type_name" | grep -qE "$ALLOW_GREP"; then
          echo "ERROR: agent name in public type '$type_name' in $file"
          FAILED=1
        fi
      fi
    done < <(grep -E "^(public |final |@MainActor )*(class|struct|enum|protocol|actor) [A-Z]" "$file")
  done < <(find "$dir" -name "*.swift" -print0 2>/dev/null)
done

if [ "$FAILED" -eq 1 ]; then
  echo "FAILURE: agent names found in infrastructure. Use generic names."
  exit 1
else
  echo "OK: no disallowed agent names in infrastructure."
fi
