#!/usr/bin/env bash
#
# Turn a filled-in exception request form into a PolicyException manifest and
# register it in kustomization.yaml.
#
# Reads the issue from the environment - never from the command line, and never
# interpolated into a shell string by the workflow, because the body is text a
# stranger wrote:
#
#   ISSUE_BODY      the rendered issue form
#   ISSUE_NUMBER    for traceability, and to break name collisions
#   ISSUE_AUTHOR    recorded as requested-by
#   ISSUE_URL       recorded as the request link
#
# Writes requests/<name>.yaml, adds it to kustomization.yaml, and prints
#   name=<name>
#   policies=<comma separated>
#   notes=<anything the reviewer should know, semicolon separated>
# on stdout for the workflow to pick up. Exits non-zero with a message on stderr
# if the request is not something we are willing to render.
#
# The one thing this script will not do is take CEL from the form. The scope
# expression is rendered from a fixed template around a namespace and a workload
# label, both validated as DNS labels, so no request can widen itself - there is
# no way to ask this for `expression: true`, or for a whole namespace.
#
# Usage (locally, against a saved issue body):
#   ISSUE_BODY="$(cat fixture.md)" ISSUE_NUMBER=1 ISSUE_AUTHOR=someone \
#     ISSUE_URL=https://example.invalid/1 .github/scripts/render-exception.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KUST="${REPO_ROOT}/kustomization.yaml"
REQ_DIR="${REPO_ROOT}/requests"

: "${ISSUE_BODY:?ISSUE_BODY is required}"
ISSUE_NUMBER="${ISSUE_NUMBER:-0}"
ISSUE_AUTHOR="${ISSUE_AUTHOR:-unknown}"
ISSUE_URL="${ISSUE_URL:-}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Every policy the Pod Security Standards set ships. A request naming anything
# else is rejected rather than rendered: an exception referring to a policy that
# does not exist is silently useless, which is worse than a failed request.
POLICIES="
disallow-capabilities
disallow-capabilities-strict
disallow-host-namespaces
disallow-host-path
disallow-host-ports
disallow-host-process
disallow-privilege-escalation
disallow-privileged-containers
disallow-proc-mount
disallow-selinux
require-run-as-non-root-user
require-run-as-nonroot
restrict-apparmor-profiles
restrict-seccomp
restrict-seccomp-strict
restrict-sysctls
restrict-volume-types
"

# --- Reading the form ---------------------------------------------------------

# GitHub renders an issue form as `### <label>` followed by the answer. Empty
# optional fields become the literal `_No response_`.
field() {
  printf '%s\n' "$ISSUE_BODY" | awk -v want="$1" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    /^###[ \t]/ {
      heading = trim(substr($0, 4))
      collecting = (heading == want)
      next
    }
    collecting {
      line = trim($0)
      if (line == "") next
      out = (out == "" ? line : out " " line)
    }
    END {
      if (out == "_No response_") out = ""
      print out
    }
  '
}

# A DNS-1123 label: what Kubernetes will accept as a name, and narrow enough that
# nothing can be smuggled through it into the YAML we are about to write.
valid_label() {
  printf '%s' "$1" | grep -qE '^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$'
}

workload=$(field "Workload")
namespace=$(field "Namespace")
policies_raw=$(field "Policies it cannot satisfy")
expires_in=$(field "Expires in")
justification=$(field "Justification")

# --- What is worth refusing, and what is worth only noting --------------------
#
# Two classes of problem, treated differently on purpose.
#
# A malformed namespace, workload or policy name changes *what gets granted*, so
# those still stop the render: they go into the scope expression or the policyRefs,
# and a wrong one either widens the exemption or silently exempts nothing.
#
# Everything else is request quality - a vague justification, an odd duration.
# Those are for the reviewer to push back on, not for a workflow to block, and
# blocking them dead-ends a demo on the least interesting thing on the screen. They
# are rendered anyway and listed on the pull request for the reviewer to see.
NOTES=""
note() { NOTES="${NOTES}${NOTES:+; }$1"; }

[ -n "$workload" ]     || die "no workload in the request"
[ -n "$namespace" ]    || die "no namespace in the request"
[ -n "$policies_raw" ] || die "no policies in the request"

valid_label "$workload" ||
  die "workload '${workload}' is not a valid label value (lowercase letters, digits and dashes)"
valid_label "$namespace" ||
  die "namespace '${namespace}' is not a valid namespace name (lowercase letters, digits and dashes)"

if [ -z "$justification" ]; then
  justification="No justification was given."
  note "no justification was given"
fi

# The form asks for a duration, because "how long do you need this for?" is a
# question a requester can answer, while "what date should this stop working?"
# invites a year from now. The manifest still carries an absolute date - a
# duration would be ambiguous the moment anyone read it later, and status.sh and
# grant-exception.sh --list both expect a date.
#
# Anything that looks like a number of days is accepted: `90`, `90d`, `90 days`.
# The form offers a fixed set, but a hand-edited issue is not a reason to refuse.
expires=""
case "$expires_in" in
  ""|Never*|never*|None*|none*)
    [ -n "$expires_in" ] || note "no duration was given, so this has no expiry date"
    ;;
  *)
    # Strip spaces and any trailing unit, then require what is left to be digits.
    # Done this way rather than with one regex because BRE alternation (`\|`) is a
    # GNU extension: it works on the runner and silently does not on a Mac, which
    # is where this gets tested.
    days=$(printf '%s' "$expires_in" | tr -d '[:space:]' |
      sed -e 's/days$//' -e 's/day$//' -e 's/d$//')
    case "$days" in
      ''|*[!0-9]*) days="" ;;
    esac
    if [ -z "$days" ] || [ "$days" = "0" ]; then
      note "could not read a duration from '${expires_in}', so this has no expiry date"
      days=""
    elif [ "$days" -gt 3650 ]; then
      note "'${expires_in}' is longer than ten years - rendered as given, but that is not an expiry"
    fi
    if [ -n "$days" ]; then
      # GNU date on the runner, BSD date when this is run on a Mac.
      expires=$(date -u -d "+${days} days" +%Y-%m-%d 2>/dev/null ||
                date -u -v"+${days}d" +%Y-%m-%d) ||
        { note "could not compute an expiry date from '${expires_in}'"; expires=""; }
    fi
    ;;
esac

# The dropdown arrives comma separated. Validate every entry against the set the
# policy set actually ships, and sort them so the manifest reads the same however
# the form was filled in.
selected=$(printf '%s' "$policies_raw" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
  grep -v '^$' | sort -u)
[ -n "$selected" ] || die "no policies in the request"
while IFS= read -r p; do
  printf '%s\n' "$POLICIES" | grep -qx "$p" ||
    die "'${p}' is not a policy in the Pod Security Standards set. One of:
$(printf '%s' "$POLICIES" | sed '/^$/d; s/^/  /')"
done <<EOF
$selected
EOF

# --- Naming -------------------------------------------------------------------

# Follow the convention the hand-written entries use: the workload, then what it
# is exempt from. The first policy alphabetically is a good enough summary, and
# it reproduces names like legacy-billing-host-path.
first=$(printf '%s\n' "$selected" | head -1)
suffix=$(printf '%s' "$first" | sed -e 's/^disallow-//' -e 's/^restrict-//' -e 's/^require-//')
name="${workload}-${suffix}"
# Two requests for the same workload and policy would otherwise overwrite each
# other; the issue number is the tie-break and points at the intake record.
if [ -f "${REQ_DIR}/${name}.yaml" ] &&
   ! grep -q "demo.nirmata.io/request: .*/${ISSUE_NUMBER}\$" "${REQ_DIR}/${name}.yaml" 2>/dev/null; then
  name="${name}-${ISSUE_NUMBER}"
fi
valid_label "$name" || die "could not derive a valid name from '${workload}' and '${first}'"

# --- Rendering ----------------------------------------------------------------

# Justification is the only free text that reaches the file. Collapse it to one
# line, drop anything non-printable, cap the length, and emit it as a
# double-quoted YAML scalar with backslashes and quotes escaped - so it cannot
# terminate the string and add YAML of its own.
justification=$(printf '%s' "$justification" |
  tr -d '\000-\010\013\014\016-\037' |
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
  cut -c1-600)

mkdir -p "$REQ_DIR"
{
  printf 'apiVersion: policies.kyverno.io/v1\n'
  printf 'kind: PolicyException\n'
  printf 'metadata:\n'
  printf '  name: %s\n' "$name"
  printf '  namespace: policy-exceptions\n'
  printf '  annotations:\n'
  # Not `approved-by`: whoever filed the request did not approve it. The approval
  # is the merge of the pull request this becomes, and Git records who did that.
  printf '    demo.nirmata.io/requested-by: %s\n' "$ISSUE_AUTHOR"
  [ -z "$ISSUE_URL" ] || printf '    demo.nirmata.io/request: %s\n' "$ISSUE_URL"
  [ -z "$expires" ]   || printf '    demo.nirmata.io/expires: "%s"\n' "$expires"
  printf '    demo.nirmata.io/justification: "%s"\n' "$justification"
  # Kyverno's own expiry mechanism, so the date is not merely documentation:
  # the cleanup controller deletes a resource carrying cleanup.kyverno.io/ttl
  # once it elapses.
  #
  # An absolute date rather than a duration on purpose. A relative `90d` is
  # counted from when the label was *observed*, so anything that recreates the
  # object - Argo CD self-healing it, a cluster rebuild, a resync - starts the
  # ninety days over, and the exemption quietly outlives its own deadline.
  # A date cannot be restarted. Colons are not valid in a label value, which is
  # why this is the date form and not a full timestamp.
  if [ -n "$expires" ]; then
    printf '  labels:\n'
    printf '    cleanup.kyverno.io/ttl: "%s"\n' "$expires"
  fi
  printf 'spec:\n'
  printf '  # Only the policies the request named.\n'
  printf '  policyRefs:\n'
  while IFS= read -r p; do
    printf '    - kind: ValidatingPolicy\n'
    printf '      name: %s\n' "$p"
  done <<EOF
$selected
EOF
  printf '\n'
  printf '  # Rendered from a fixed template - one workload in one namespace. The\n'
  printf '  # request form cannot express anything wider than this.\n'
  printf '  matchConditions:\n'
  printf '    - name: %s-only\n' "$workload"
  printf '      expression: >-\n'
  printf "        object.metadata.namespace == '%s' &&\n" "$namespace"
  printf '        has(object.metadata.labels) &&\n'
  printf "        'app' in object.metadata.labels &&\n"
  printf "        object.metadata.labels['app'] == '%s'\n" "$workload"
} > "${REQ_DIR}/${name}.yaml"

# --- Registering it -----------------------------------------------------------

# Adding the line here is what will put the exception in force when this is
# merged. Leaving it out would make the pull request a no-op, which is the
# mistake the reviewer checklist exists to catch - so do it now, and let the
# reviewer see both halves in one diff.
line="  - requests/${name}.yaml"
if grep -qxF "$line" "$KUST"; then
  : # already registered, e.g. the form was edited and this re-ran
elif grep -qxF "  # ${line#  }" "$KUST"; then
  # There is a commented placeholder for it; uncomment that in place.
  awk -v want="  # ${line#  }" -v line="$line" \
    '$0 == want { print line; next } { print }' "$KUST" > "${KUST}.tmp"
  mv "${KUST}.tmp" "$KUST"
else
  printf '%s\n' "$line" >> "$KUST"
fi

printf 'name=%s\n' "$name"
printf 'policies=%s\n' "$(printf '%s' "$selected" | tr '\n' ',' | sed 's/,$//')"
# Anything the reviewer should know that was not worth refusing over.
printf 'notes=%s\n' "$NOTES"
