#!/usr/bin/env bash
#
# BR-04 guardrail. Evaluates a saved Terraform plan in JSON form against
# policies/br04.rego and exits with the control's decision.
#
#   0  PASS    no violation
#   1  FAIL    BR-04 violation
#   2  ERROR   input or environment could not be evaluated, fail closed
#   3  FAIL    suppression attempt detected
#
# No AWS credentials, no cloud calls, no network. The plan file is read locally.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
POLICY_DIR="${BR04_POLICY_DIR:-${REPO_ROOT}/policies}"
QUERY="data.guardai.br04.decision"

# Codes 0, 1 and 3 come from the policy decision. Only the fail closed code is
# raised by this script on its own.
EXIT_ERROR=2

err() { printf '%s\n' "$*" >&2; }

usage() {
	cat >&2 <<'EOF'
usage: check-plan.sh <plan.json>

  <plan.json>  output of: terraform show -json <planfile>

Exit codes: 0 pass, 1 BR-04 violation, 2 input or environment error, 3 suppression attempt.
EOF
}

if [ "$#" -ne 1 ]; then
	usage
	exit "${EXIT_ERROR}"
fi

case "$1" in
-h | --help)
	usage
	exit "${EXIT_ERROR}"
	;;
esac

PLAN="$1"

for tool in opa jq; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		err "BR-04 ERROR: ${tool} is not on PATH."
		err "  opa: https://www.openpolicyagent.org/docs/latest/#running-opa"
		err "  jq:  https://jqlang.github.io/jq/download/"
		exit "${EXIT_ERROR}"
	fi
done

if [ ! -f "${PLAN}" ]; then
	err "BR-04 ERROR: plan file not found: ${PLAN}"
	exit "${EXIT_ERROR}"
fi

if [ ! -r "${PLAN}" ]; then
	err "BR-04 ERROR: plan file is not readable: ${PLAN}"
	exit "${EXIT_ERROR}"
fi

if ! jq empty "${PLAN}" >/dev/null 2>&1; then
	err "BR-04 ERROR: plan file is not valid JSON: ${PLAN}"
	exit "${EXIT_ERROR}"
fi

if [ ! -d "${POLICY_DIR}" ]; then
	err "BR-04 ERROR: policy directory not found: ${POLICY_DIR}"
	exit "${EXIT_ERROR}"
fi

DECISION="$(opa eval --format json --data "${POLICY_DIR}" --input "${PLAN}" "${QUERY}" 2>&1)"
OPA_RC=$?

if [ "${OPA_RC}" -ne 0 ]; then
	err "BR-04 ERROR: opa eval failed (exit ${OPA_RC})"
	err "${DECISION}"
	exit "${EXIT_ERROR}"
fi

RESULT="$(printf '%s' "${DECISION}" | jq -e '.result[0].expressions[0].value' 2>/dev/null)"
if [ -z "${RESULT}" ]; then
	err "BR-04 ERROR: policy returned no decision for ${QUERY}"
	exit "${EXIT_ERROR}"
fi

CODE="$(printf '%s' "${RESULT}" | jq -r '.exit_code // empty')"
case "${CODE}" in
0 | 1 | 2 | 3) ;;
*)
	err "BR-04 ERROR: policy returned no usable exit_code"
	exit "${EXIT_ERROR}"
	;;
esac

VERDICT="$(printf '%s' "${RESULT}" | jq -r '.result')"

printf 'BR-04  deletion or replacement of a designated stateful resource\n'
printf 'plan   %s\n\n' "${PLAN}"

printf '%s' "${RESULT}" | jq -r '.input_errors[]? | "  input error: " + .'
printf '%s' "${RESULT}" | jq -r '.suppression_attempts[]? | "  " + .message'
printf '%s' "${RESULT}" | jq -r '.violations[]? | "  " + .message'

printf '\n%s (exit %s)\n' "${VERDICT}" "${CODE}"

case "${CODE}" in
0) printf 'No designated stateful resource is destroyed or replaced by this plan.\n' ;;
1) printf 'Blocked before apply. Migrate the data or split the change, then plan again.\n' ;;
2) printf 'Fail closed. An input the control cannot read is never a pass.\n' ;;
3) printf 'Suppression of a BR-04 finding is rejected, always. Remove the tag.\n' ;;
esac

exit "${CODE}"
