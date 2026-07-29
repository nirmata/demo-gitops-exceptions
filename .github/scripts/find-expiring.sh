#!/usr/bin/env bash
#
# Report which of the exceptions currently in force have expired, or are about to.
#
# An exemption is only in force while it is listed in kustomization.yaml, so that
# list is what this walks - a manifest sitting unlisted in requests/ is already
# harmless however old its date is.
#
# Output, one line per finding, tab separated:
#
#   expired<TAB><name><TAB><date><TAB><days overdue><TAB><request url>
#   soon<TAB><name><TAB><date><TAB><days remaining><TAB><request url>
#
# Environment:
#   TODAY       pretend it is this date (YYYY-MM-DD). The whole point of an expiry
#               demo is not having to wait for one, and the workflow exposes this
#               as a workflow_dispatch input.
#   SOON_DAYS   how far ahead to look for "soon" (default 7)
#
# Usage:
#   .github/scripts/find-expiring.sh
#   TODAY=2027-01-01 .github/scripts/find-expiring.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUST="${REPO_ROOT}/kustomization.yaml"
REQ_DIR="${REPO_ROOT}/requests"
SOON_DAYS="${SOON_DAYS:-7}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Days since the epoch, for date arithmetic that does not care about months.
# GNU date on a runner, BSD date on a Mac.
epoch_days() {
  local d=$1 secs
  secs=$(date -u -d "${d}T00:00:00Z" +%s 2>/dev/null) ||
    secs=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${d}T00:00:00Z" +%s 2>/dev/null) ||
    return 1
  printf '%s' $(( secs / 86400 ))
}

TODAY="${TODAY:-$(date -u +%Y-%m-%d)}"
printf '%s' "$TODAY" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ||
  die "TODAY='${TODAY}' is not a YYYY-MM-DD date"
today_days=$(epoch_days "$TODAY") || die "could not parse TODAY='${TODAY}'"

# Read one `key: value` out of a manifest, from either the annotations or the
# labels - the expiry is written to both, and either is authoritative enough.
manifest_value() {
  awk -v key="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { esc = key; gsub(/\./, "[.]", esc) }
    found { next }
    match($0, "^[ \t]*" esc ":") {
      v = trim(substr($0, RLENGTH + 1))
      gsub(/^"|"$/, "", v)
      print v
      found = 1
    }
  ' "$1"
}

[ -f "$KUST" ] || die "${KUST} not found"

# Granted entries only: `  - requests/<name>.yaml`, uncommented.
while IFS= read -r name; do
  [ -n "$name" ] || continue
  manifest="${REQ_DIR}/${name}.yaml"
  [ -f "$manifest" ] || continue

  expires=$(manifest_value "$manifest" demo.nirmata.io/expires)
  [ -n "$expires" ] || expires=$(manifest_value "$manifest" cleanup.kyverno.io/ttl)
  # No expiry is a decision, not an oversight - node-exporter's need for host
  # namespaces is structural. Nothing to chase.
  [ -n "$expires" ] || continue
  printf '%s' "$expires" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || continue

  exp_days=$(epoch_days "$expires") || continue
  request=$(manifest_value "$manifest" demo.nirmata.io/request)

  if [ "$exp_days" -lt "$today_days" ]; then
    printf 'expired\t%s\t%s\t%s\t%s\n' "$name" "$expires" "$(( today_days - exp_days ))" "$request"
  elif [ $(( exp_days - today_days )) -le "$SOON_DAYS" ]; then
    printf 'soon\t%s\t%s\t%s\t%s\n' "$name" "$expires" "$(( exp_days - today_days ))" "$request"
  fi
done <<EOF
$(sed -n 's|^  - requests/\(.*\)\.yaml[[:space:]]*$|\1|p' "$KUST")
EOF
