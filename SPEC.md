# BR-04 specification

Written before any implementation. This file is the contract the tests are written
against. If behaviour and this file disagree, one of them is a bug.

## 1. Control trace

| Layer | Statement |
|---|---|
| **Standard** | Stateful production resources must not be destroyed or replaced by an automated pipeline. |
| **Policy** | For any Terraform plan targeting a production workspace, a planned action of `delete`, or a replacement (`delete`+`create` in either order), against a resource type on the designated stateful list is not permitted. There is no exception path in this repository. |
| **Control** | `BR-04` reads a saved Terraform plan in JSON form and reports every managed resource change whose type is on the stateful list and whose action set is destructive. |
| **Guardrail** | `check-plan.sh` exits non-zero. The CI job fails. The pull request is blocked before `terraform apply` runs. |

## 2. Scope

In scope: what a Terraform plan JSON file can prove on its own.

Out of scope, and not faked anywhere in this repository:

- IAM effective permissions (needs policy simulation against live accounts)
- Backup existence and restore success (needs the backup system and a real restore)
- Live exposure of an already-running resource (needs the cloud control plane)
- Drift between state and reality (needs a refresh against live infrastructure)
- Anything about resources not present in this plan

## 3. Input

A single file: the output of `terraform show -json <planfile>`.

The control reads only `input.resource_changes[]` and, of each element:

- `address` (string)
- `type` (string)
- `mode` (string)
- `change.actions` (array of strings)
- `change.after.tags` and `change.after.tags_all` (objects, optional, used only for
  suppression detection)

Everything else in the plan is ignored.

## 4. Designated stateful resource types

This list is deliberately small and hand maintained. It is not exhaustive and is not
claimed to be. Extending it is a deliberate act by whoever adopts the control.

```
aws_db_instance
aws_rds_cluster
aws_dynamodb_table
aws_s3_bucket
aws_efs_file_system
aws_elasticache_replication_group
azurerm_mssql_database
azurerm_storage_account
google_sql_database_instance
google_storage_bucket
```

Ten types. Anything not on this list is not evaluated by BR-04, including stateful
resources that plainly should be on it. That is a known limitation, stated in the
README, not a hidden one.

## 5. Decision rules

Let `rc` be an element of `resource_changes`.

`rc.change.actions` is **destructive** when it contains the string `delete`. Terraform
emits three such arrays today:

```
["delete"]                destroy
["delete", "create"]      replacement
["create", "delete"]      replacement, create before destroy
```

The rule matches on the action, not on this list of array shapes, so an array shape
nobody anticipated fails rather than passes.

`["update"]`, `["create"]`, `["no-op"]`, `["read"]` are not destructive.

`["forget"]` (a `removed` block dropping a resource from state without destroying it)
is not destructive for BR-04 purposes. It is a different failure mode, an abandoned
resource rather than a deleted one, and it is out of scope here.

A **violation** is produced when all of the following hold:

1. the input passed validation (section 6)
2. `rc.mode == "managed"`
3. `rc.type` is in the stateful list
4. `rc.change.actions` is destructive

A **suppression attempt** is produced when the input passed validation and a resource
change carries a tag key which, lowercased, contains one of `guardai`, `guard_ai`,
`br04`, `br-04` and also contains one of `ignore`, `skip`, `suppress`, `exempt`,
`bypass`, `override`.

This repository has no suppression mechanism. The detection exists so that an attempt
to invent one is a louder failure than the finding it was trying to hide.

## 6. Fail closed

The input is rejected, with no policy evaluation attempted, when:

- no input is supplied
- the input is not a JSON object
- `resource_changes` is absent or null
- `resource_changes` is not an array
- any element of `resource_changes` is not an object, or is missing `address`,
  `type`, `mode`, or `change.actions` with the expected types

Unparseable JSON and a missing file are rejected by the wrapper script before OPA is
invoked.

There is no code path that turns a rejected input into a pass.

## 7. Exit codes

| Code | Meaning |
|---|---|
| 0 | PASS. Input valid, no violation, no suppression attempt. |
| 1 | FAIL. One or more BR-04 violations. |
| 2 | ERROR. Input or environment could not be evaluated. Fail closed. |
| 3 | FAIL. A suppression attempt was detected. |

Precedence when more than one condition holds: `2` > `3` > `1` > `0`.

`2` outranks everything because an unevaluable input proves nothing. `3` outranks `1`
because someone trying to silence the control is a worse finding than the deletion it
would have hidden.

## 8. Invariants

1. The decision is made by OPA evaluating Rego. No language model is in the path.
2. Given the same plan JSON, the same policy version returns the same result. No
   network access, no clock, no randomness in the policy.
3. There is no flag, tag, environment variable, comment, or file that turns a
   violation into a pass.
4. An input that cannot be validated fails. It never passes.
5. Every finding carries the control ID `BR-04` and the resource address it came from.
6. The policy reads the plan only. It never touches a cloud account and needs no
   credentials.
