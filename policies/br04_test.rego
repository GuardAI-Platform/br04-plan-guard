# Tests for BR-04. Written before policies/br04.rego exists.
# Every test asserts against the single public rule: data.guardai.br04.decision

package guardai.br04_test

import data.guardai.br04

# ----------------------------------------------------------------------------
# fixture builders
# ----------------------------------------------------------------------------

plan(changes) := {
	"format_version": "1.2",
	"terraform_version": "1.9.5",
	"resource_changes": changes,
}

managed(addr, typ, actions) := {
	"address": addr,
	"mode": "managed",
	"type": typ,
	"name": "example",
	"provider_name": "registry.terraform.io/hashicorp/aws",
	"change": {
		"actions": actions,
		"before": {},
		"after": {},
	},
}

tagged(addr, typ, actions, tags) := object.union(
	managed(addr, typ, actions),
	{"change": {
		"actions": actions,
		"before": {},
		"after": {"tags": tags},
	}},
)

# ----------------------------------------------------------------------------
# destructive actions on designated stateful types must fail
# ----------------------------------------------------------------------------

test_delete_of_stateful_db_fails if {
	d := br04.decision with input as plan([managed("aws_db_instance.orders", "aws_db_instance", ["delete"])])
	d.exit_code == 1
	d.result == "FAIL"
	count(d.violations) == 1
}

test_replacement_delete_then_create_fails if {
	d := br04.decision with input as plan([managed("aws_db_instance.orders", "aws_db_instance", ["delete", "create"])])
	d.exit_code == 1
	count(d.violations) == 1
}

test_replacement_create_then_delete_fails if {
	d := br04.decision with input as plan([managed("aws_rds_cluster.core", "aws_rds_cluster", ["create", "delete"])])
	d.exit_code == 1
	count(d.violations) == 1
}

test_bucket_delete_fails if {
	d := br04.decision with input as plan([managed("aws_s3_bucket.audit", "aws_s3_bucket", ["delete"])])
	d.exit_code == 1
}

test_every_designated_type_is_caught if {
	every t in br04.stateful_resource_types {
		br04.decision.exit_code == 1 with input as plan([managed(sprintf("%s.x", [t]), t, ["delete"])])
	}
}

# Terraform emits ["delete"], ["delete","create"] and ["create","delete"] today. Any
# other action array carrying a delete on a designated stateful type must also fail,
# rather than passing because it was not on a list of known shapes.
test_unrecognised_action_set_containing_delete_fails if {
	d := br04.decision with input as plan([managed("aws_s3_bucket.audit", "aws_s3_bucket", ["delete", "create", "delete"])])
	d.exit_code == 1
	count(d.violations) == 1
}

# "forget" removes a resource from state without destroying it. Different failure mode,
# out of BR-04 scope, documented in SPEC.md section 2.
test_forget_action_is_out_of_scope if {
	br04.decision.exit_code == 0 with input as plan([managed("aws_s3_bucket.audit", "aws_s3_bucket", ["forget"])])
}

test_violation_carries_control_id_and_address if {
	d := br04.decision with input as plan([managed("aws_dynamodb_table.sessions", "aws_dynamodb_table", ["delete", "create"])])
	some v in d.violations
	v.code == "BR-04"
	v.address == "aws_dynamodb_table.sessions"
	v.type == "aws_dynamodb_table"
	v.actions == ["delete", "create"]
}

test_multiple_violations_are_all_reported if {
	d := br04.decision with input as plan([
		managed("aws_db_instance.orders", "aws_db_instance", ["delete"]),
		managed("aws_s3_bucket.audit", "aws_s3_bucket", ["delete", "create"]),
		managed("aws_instance.web", "aws_instance", ["delete"]),
	])
	d.exit_code == 1
	count(d.violations) == 2
}

# ----------------------------------------------------------------------------
# safe changes must pass
# ----------------------------------------------------------------------------

test_in_place_update_of_stateful_db_passes if {
	d := br04.decision with input as plan([managed("aws_db_instance.orders", "aws_db_instance", ["update"])])
	d.exit_code == 0
	d.result == "PASS"
	count(d.violations) == 0
}

test_create_of_stateful_db_passes if {
	br04.decision.exit_code == 0 with input as plan([managed("aws_db_instance.orders", "aws_db_instance", ["create"])])
}

test_no_op_passes if {
	br04.decision.exit_code == 0 with input as plan([managed("aws_db_instance.orders", "aws_db_instance", ["no-op"])])
}

test_read_passes if {
	br04.decision.exit_code == 0 with input as plan([managed("aws_s3_bucket.audit", "aws_s3_bucket", ["read"])])
}

test_delete_of_non_stateful_type_passes if {
	br04.decision.exit_code == 0 with input as plan([managed("aws_instance.web", "aws_instance", ["delete", "create"])])
}

test_data_source_is_not_evaluated if {
	rc := object.union(
		managed("data.aws_s3_bucket.audit", "aws_s3_bucket", ["delete"]),
		{"mode": "data"},
	)
	br04.decision.exit_code == 0 with input as plan([rc])
}

test_empty_plan_passes if {
	br04.decision.exit_code == 0 with input as plan([])
}

# ----------------------------------------------------------------------------
# fail closed on bad input
# ----------------------------------------------------------------------------

test_undefined_input_fails_closed if {
	br04.decision.exit_code == 2
	br04.decision.result == "ERROR"
}

test_non_object_input_fails_closed if {
	br04.decision.exit_code == 2 with input as "this is not a plan"
}

test_missing_resource_changes_fails_closed if {
	br04.decision.exit_code == 2 with input as {"format_version": "1.2"}
}

test_null_resource_changes_fails_closed if {
	br04.decision.exit_code == 2 with input as {"resource_changes": null}
}

test_resource_changes_not_array_fails_closed if {
	br04.decision.exit_code == 2 with input as {"resource_changes": {"aws_db_instance.orders": ["delete"]}}
}

test_element_not_object_fails_closed if {
	br04.decision.exit_code == 2 with input as plan(["aws_db_instance.orders"])
}

test_element_missing_actions_fails_closed if {
	rc := {"address": "aws_db_instance.orders", "mode": "managed", "type": "aws_db_instance", "change": {"before": {}}}
	br04.decision.exit_code == 2 with input as plan([rc])
}

test_element_missing_type_fails_closed if {
	rc := {"address": "aws_db_instance.orders", "mode": "managed", "change": {"actions": ["delete"]}}
	br04.decision.exit_code == 2 with input as plan([rc])
}

test_actions_not_a_list_of_strings_fails_closed if {
	rc := {
		"address": "aws_db_instance.orders",
		"mode": "managed",
		"type": "aws_db_instance",
		"change": {"actions": [{"op": "delete"}]},
	}
	br04.decision.exit_code == 2 with input as plan([rc])
}

test_malformed_input_produces_no_violations if {
	d := br04.decision with input as {"format_version": "1.2"}
	count(d.violations) == 0
	count(d.input_errors) > 0
}

test_one_bad_element_fails_the_whole_plan if {
	d := br04.decision with input as plan([
		managed("aws_instance.web", "aws_instance", ["update"]),
		"not-an-object",
	])
	d.exit_code == 2
}

# ----------------------------------------------------------------------------
# suppression attempts
# ----------------------------------------------------------------------------

test_suppression_tag_is_rejected if {
	rc := tagged("aws_db_instance.orders", "aws_db_instance", ["update"], {"guardai_ignore": "BR-04"})
	d := br04.decision with input as plan([rc])
	d.exit_code == 3
	count(d.suppression_attempts) == 1
}

test_suppression_outranks_violation if {
	rc := tagged("aws_db_instance.orders", "aws_db_instance", ["delete"], {"br04-skip": "true"})
	d := br04.decision with input as plan([rc])
	d.exit_code == 3
}

test_suppression_in_tags_all_is_rejected if {
	rc := {
		"address": "aws_s3_bucket.audit",
		"mode": "managed",
		"type": "aws_s3_bucket",
		"change": {
			"actions": ["update"],
			"before": {},
			"after": {"tags_all": {"GuardAI-Exempt": "yes"}},
		},
	}
	br04.decision.exit_code == 3 with input as plan([rc])
}

test_ordinary_tags_are_ignored if {
	rc := tagged("aws_db_instance.orders", "aws_db_instance", ["update"], {
		"Name": "orders-prod",
		"Environment": "production",
		"ignore-me": "not a guardai key",
	})
	br04.decision.exit_code == 0 with input as plan([rc])
}

test_malformed_input_outranks_suppression if {
	rc := tagged("aws_db_instance.orders", "aws_db_instance", ["delete"], {"guardai_bypass": "1"})
	d := br04.decision with input as {"resource_changes": [rc, "not-an-object"]}
	d.exit_code == 2
}
