#!/usr/bin/env bash
#
# Take one exception out of force by commenting it out of kustomization.yaml.
#
# The manifest stays in requests/ deliberately. An exemption that was granted and
# then withdrawn is part of the record - deleting the file would erase the fact
# that it ever existed, and the next person to ask the same question deserves to
# find the previous answer.
#
# Usage:
#   .github/scripts/revoke-exception.sh <name>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUST="${REPO_ROOT}/kustomization.yaml"

NAME="${1:?usage: revoke-exception.sh <name>}"
line="  - requests/${NAME}.yaml"

grep -qxF "$line" "$KUST" || {
  printf 'error: %s is not in force in kustomization.yaml\n' "$NAME" >&2
  exit 1
}

# Same shape grant-exception.sh --revoke produces, so the two paths are
# indistinguishable in the register's history.
awk -v want="$line" -v out="  # - requests/${NAME}.yaml" \
  '$0 == want { print out; next } { print }' "$KUST" > "${KUST}.tmp"
mv "${KUST}.tmp" "$KUST"

grep -qxF "  # - requests/${NAME}.yaml" "$KUST" ||
  { printf 'error: failed to comment out %s\n' "$NAME" >&2; exit 1; }
