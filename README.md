# BR-04: What happens when AI-generated infrastructure reaches production?

AI helps teams build infrastructure faster. Guard AI helps review what reaches production.

This repository is a working demo of that review: one control, end to end. It is the
companion to the GuardAIOps guide *What Happens When AI-Generated Infrastructure Reaches
Production?*

It shows how Guard AI reviews production infrastructure risk before deployment, by
answering one question about a Terraform plan, deterministically, before apply:

> Does this plan destroy or replace a database, a bucket, or another stateful resource
> that holds the only copy of something?

That is **BR-04**. One control, implemented honestly, with its limits written down.

This is a demo of a single control. It is not the Guard AI platform, and nothing here
claims to be a compliance product.

---

## What runs

```
terraform plan -out=tfplan
        |
        v
terraform show -json tfplan > tfplan.json
        |
        v
scripts/check-plan.sh tfplan.json
        |
        +--> OPA evaluates policies/br04.rego   (deterministic, no model, no network)
        |
        +--> exit 0  PASS   pipeline continues to approval and apply
        +--> exit 1  FAIL   BR-04 violation, pull request blocked
        +--> exit 2  ERROR  input unreadable, fail closed, pull request blocked
        +--> exit 3  FAIL   suppression attempt, pull request blocked
```

No language model is in the decision path. The policy is Rego, the engine is OPA, the
same plan always produces the same answer.

---

## Run it

Needs `opa`, `jq`, `make`, `bash`. No AWS account, no credentials, no Terraform, no
cloud calls. Two minutes from clone.

```bash
git clone https://github.com/GuardAI-Platform/br04-plan-guard.git
cd br04-plan-guard

make install-opa          # optional, if opa is not already on PATH (installs to ./bin)
export PATH="$PWD/bin:$PATH"

make test                 # 32 Rego unit tests
make demo-safe            # a plan that passes         -> exit 0
make demo-risky           # two plans that are blocked -> exit 1
make demo-malformed       # unreadable input           -> exit 2
make demo-suppression     # someone tagging past it    -> exit 3
make verify               # the full gate: format, shellcheck, tests, adversarial cases
```

`make verify` is the only target that matters for review. It asserts every exit code in
the table below and fails the build if any of them moves.

---

## The control trace

Every finding traces back through four layers. This is the whole point of the
repository: a finding you cannot trace is a finding nobody acts on.

| Layer | This control |
|---|---|
| **Standard** | Stateful production resources must not be destroyed or replaced by an automated pipeline. |
| **Policy** | A planned `delete`, or a replacement (`delete`+`create` in either order), against a resource type on the designated stateful list is not permitted. No exception path exists in this repository. |
| **Control** | `BR-04`. Reads the plan JSON, reports every managed resource change that matches. Implemented in `policies/br04.rego`. |
| **Guardrail** | `scripts/check-plan.sh` exits non-zero, the GitHub Actions job fails, the pull request is blocked before `terraform apply`. |

Full written specification, including the invariants the tests are written against:
[`SPEC.md`](SPEC.md).

---

## What counts as destructive

Any `actions` array containing `delete`, on a resource type from the designated list:

| Actions in plan | Meaning | BR-04 |
|---|---|---|
| `["delete"]` | destroy | fail |
| `["delete", "create"]` | replacement | fail |
| `["create", "delete"]` | replacement, create first | fail |
| `["update"]` | in place change | pass |
| `["create"]` | new resource | pass |
| `["no-op"]` | unchanged | pass |
| `["read"]` | data source read | pass |
| `["forget"]` | dropped from state, not destroyed | pass, out of scope |

The match is on the action, not on the three known array shapes. An array shape a
future Terraform version emits, or one somebody hand edits, fails rather than passes.

A replacement is the failure mode people miss. Terraform reports it as a routine part
of the plan. It destroys the database and builds an empty one with the same name.

## The designated stateful list

```
aws_db_instance                     azurerm_mssql_database
aws_rds_cluster                     azurerm_storage_account
aws_dynamodb_table                  google_sql_database_instance
aws_s3_bucket                       google_storage_bucket
aws_efs_file_system
aws_elasticache_replication_group
```

**Ten types. This list is not exhaustive and is not claimed to be.** It does not include
Redshift, Neptune, DocumentDB, MSK, OpenSearch, Azure Cosmos DB, Cloud Spanner,
persistent volume claims, or the twenty other things in your estate that hold state.
Adding them is a deliberate act by whoever adopts the control, because the list is the
part that has to match your architecture. A control that guesses what matters to you is
a control you will switch off.

Anything not on the list is not evaluated. `examples/risky-bucket-delete.json` destroys
an EC2 instance alongside the bucket and the table, and BR-04 says nothing about the
EC2 instance. That is correct behaviour, not a gap being papered over.

---

## Exit codes

| Code | Result | When |
|---|---|---|
| 0 | PASS | Input valid, no violation, no suppression attempt |
| 1 | FAIL | One or more BR-04 violations |
| 2 | ERROR | Missing file, unparseable JSON, missing `resource_changes`, malformed element, missing tool |
| 3 | FAIL | A suppression attempt was detected |

Precedence: `2` > `3` > `1` > `0`.

`2` outranks everything because an input the control cannot read proves nothing. A
guardrail that treats an unreadable plan as a pass is worse than no guardrail, because
now you trust it.

`3` outranks `1` because someone trying to silence the control is a worse finding than
the deletion they were trying to push through.

## There is no suppression mechanism

No ignore file, no skip flag, no exception tag, no environment variable. Nothing in
this repository turns a violation into a pass.

The policy does detect attempts to invent one. A tag whose key contains `guardai`,
`guard_ai`, `br04` or `br-04` together with `ignore`, `skip`, `suppress`, `exempt`,
`bypass` or `override` is reported as a suppression attempt and exits 3, above the
violation it was meant to hide. See `examples/suppression-attempt.json`.

If a BR-04 finding is genuinely wrong for your estate, the fix is to change the
designated list in `policies/br04.rego` in a reviewed commit, where the change is
visible to everyone. Not a tag on one resource that nobody reads again.

---

## Security note on plan JSON

`terraform show -json` can expose sensitive values. Resource attributes that were
marked sensitive appear in the plan file in plain text unless the provider redacts
them, and plan files routinely contain database names, endpoints, account identifiers,
CIDR ranges and occasionally secrets pulled in from variables or data sources.

Consequences:

- Do not commit real plan JSON to a repository.
- Do not upload real plan JSON to a third party service, this repository's issues, a
  pastebin, or a model API.
- Treat `tfplan.json` as a credential. Write it to the runner workspace, evaluate it,
  delete it. Do not publish it as a build artifact without reviewing what is in it.
- BR-04 runs locally and needs no network. Keep it that way.

Every plan in `examples/` is synthetic, hand written for this repository, and marked
with a `_synthetic` field. None of it came from a real account.

---

## Wiring it into your own pipeline

```yaml
- name: Terraform plan
  run: |
    terraform plan -out=tfplan
    terraform show -json tfplan > tfplan.json

- name: BR-04
  run: scripts/check-plan.sh tfplan.json    # non-zero blocks the pull request
```

Then make the job a required status check on your protected branch, otherwise the
guardrail is advice rather than a guardrail.

Two things to change before this is useful to you:

1. The designated stateful list in `policies/br04.rego`.
2. Whether the control should apply to every workspace or only production. This
   repository evaluates every plan it is given and does not inspect workspace names,
   because workspace naming is not standard enough to guess. Gate it in your workflow.

---

## What this repository does not do

The guide lists twelve checks. This repository automates **one** of them, because one
is what a saved plan can prove on its own. The rest need evidence that does not exist
in plan JSON:

| Not automated here | Why |
|---|---|
| IAM effective permissions | Needs policy simulation against live accounts, including SCPs, boundaries and identity centre assignments |
| Backup existence and restore success | Needs the backup system, and a restore that actually completed |
| Live exposure of running resources | Needs the cloud control plane, not a plan |
| Drift between state and reality | Needs a refresh against live infrastructure |
| Blast radius of a module across environments | Needs the dependency graph and the state files for each environment |

Anything claiming to check those from a plan file alone is guessing. This one does not
guess, which is the only reason its answer is worth anything.

---

## Repository layout

```
SPEC.md                              written before the code, tests assert against it
policies/br04.rego                   the control
policies/br04_test.rego              32 unit tests, written before the control
examples/safe-plan.json              in place update, passes
examples/risky-rds-replacement.json  RDS replacement, exit 1
examples/risky-bucket-delete.json    bucket and table destroy, exit 1
examples/malformed-plan.json         valid JSON, unusable plan, exit 2
examples/not-json.txt                unparseable, exit 2
examples/suppression-attempt.json    tagged to bypass, exit 3
scripts/check-plan.sh                the guardrail wrapper
.github/workflows/test.yml           CI: verify, plus the blocking job
Makefile                             test, demos, verify
```

## License

MIT. See [`LICENSE`](LICENSE).

---

Built by IronRim as a companion to the GuardAIOps guide
*What Happens When AI-Generated Infrastructure Reaches Production?*
