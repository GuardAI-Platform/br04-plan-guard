# BR-04: no deletion or replacement of a designated stateful resource.
#
# Standard  Stateful production resources must not be destroyed or replaced by an
#           automated pipeline.
# Policy    A planned delete, or a replacement (delete+create in either order), against
#           a resource type on the designated stateful list is not permitted. No
#           exception path exists in this repository.
# Control   BR-04. Reads a Terraform plan in JSON form, reports every managed resource
#           change that matches.
# Guardrail scripts/check-plan.sh exits non-zero, the CI job fails, the pull request is
#           blocked before terraform apply.
#
# Input: the output of `terraform show -json <planfile>`.
# The policy reads the plan only. No cloud calls, no credentials, no network.

package guardai.br04

control_id := "BR-04"

# The designated stateful list. Deliberately small, hand maintained, NOT exhaustive.
# Anything absent from this set is not evaluated by BR-04.
stateful_resource_types := {
	"aws_db_instance",
	"aws_rds_cluster",
	"aws_dynamodb_table",
	"aws_s3_bucket",
	"aws_efs_file_system",
	"aws_elasticache_replication_group",
	"azurerm_mssql_database",
	"azurerm_storage_account",
	"google_sql_database_instance",
	"google_storage_bucket",
}

# The action arrays Terraform emits for a destroy and for a replacement. Documentation
# of the canonical cases. The rule below does not depend on this list being complete.
canonical_destructive_action_sets := {
	["delete"],
	["delete", "create"],
	["create", "delete"],
}

# Any planned action array carrying a delete destroys the existing object, whatever
# else is in the array. Matching on the action rather than on a list of known array
# shapes means a shape nobody anticipated fails rather than passes.
destructive(actions) if {
	some a in actions
	a == "delete"
}

# ----------------------------------------------------------------------------
# input validation: everything that cannot be validated fails closed
# ----------------------------------------------------------------------------

# Indirection through a rule, not `not is_object(input)` directly: when no input
# document is supplied at all, a builtin call on `input` is undefined and its
# negation does not fire. Negating an undefined rule does.
input_is_object if is_object(input)

input_errors contains msg if {
	not input_is_object
	msg := "plan input is missing or is not a JSON object"
}

input_errors contains msg if {
	input_is_object
	object.get(input, "resource_changes", null) == null
	msg := "plan input has no resource_changes key"
}

input_errors contains msg if {
	input_is_object
	rcs := object.get(input, "resource_changes", null)
	rcs != null
	not is_array(rcs)
	msg := "resource_changes is not an array"
}

input_errors contains msg if {
	input_is_object
	is_array(input.resource_changes)
	some i, rc in input.resource_changes
	not valid_change(rc)
	msg := sprintf("resource_changes[%v] is malformed: needs object with string address, type, mode and change.actions as a list of strings", [i])
}

valid_change(rc) if {
	is_object(rc)
	is_string(rc.address)
	is_string(rc.type)
	is_string(rc.mode)
	is_array(rc.change.actions)
	every a in rc.change.actions {
		is_string(a)
	}
}

input_valid if {
	count(input_errors) == 0
}

# ----------------------------------------------------------------------------
# violations
# ----------------------------------------------------------------------------

violations contains v if {
	input_valid
	some rc in input.resource_changes
	rc.mode == "managed"
	stateful_resource_types[rc.type]
	destructive(rc.change.actions)

	v := {
		"code": control_id,
		"address": rc.address,
		"type": rc.type,
		"actions": rc.change.actions,
		"message": sprintf(
			"%s: %s (%s) is planned for %s. Designated stateful resource; destroy and replace are not permitted from the pipeline.",
			[control_id, rc.address, rc.type, concat("+", rc.change.actions)],
		),
	}
}

# ----------------------------------------------------------------------------
# suppression attempts
#
# This repository has no suppression mechanism. This rule exists so that inventing
# one is a louder failure than the finding it was meant to hide.
# ----------------------------------------------------------------------------

suppression_key_scopes := {"guardai", "guard_ai", "br04", "br-04"}

suppression_key_markers := {"ignore", "skip", "suppress", "exempt", "bypass", "override"}

suppression_attempts contains s if {
	input_valid
	some rc in input.resource_changes
	some source in ["tags", "tags_all"]
	tags := object.get(rc, ["change", "after", source], {})
	is_object(tags)
	some k, _ in tags
	suppression_key(lower(k))

	s := {
		"code": "BR-04-SUPPRESSION",
		"address": rc.address,
		"tag": k,
		"message": sprintf(
			"BR-04-SUPPRESSION: %s carries tag %q. Suppression of a BR-04 finding is rejected, always.",
			[rc.address, k],
		),
	}
}

suppression_key(k) if {
	some scope in suppression_key_scopes
	contains(k, scope)
	some marker in suppression_key_markers
	contains(k, marker)
}

# ----------------------------------------------------------------------------
# decision
#
# Precedence: 2 (unevaluable) > 3 (suppression) > 1 (violation) > 0 (pass).
# ----------------------------------------------------------------------------

exit_code := 2 if {
	not input_valid
}

exit_code := 3 if {
	input_valid
	count(suppression_attempts) > 0
}

exit_code := 1 if {
	input_valid
	count(suppression_attempts) == 0
	count(violations) > 0
}

exit_code := 0 if {
	input_valid
	count(suppression_attempts) == 0
	count(violations) == 0
}

result := "ERROR" if exit_code == 2

result := "FAIL" if exit_code == 3

result := "FAIL" if exit_code == 1

result := "PASS" if exit_code == 0

decision := {
	"control": control_id,
	"result": result,
	"exit_code": exit_code,
	"input_errors": input_errors,
	"suppression_attempts": suppression_attempts,
	"violations": violations,
	"evaluated_resource_types": stateful_resource_types,
}
