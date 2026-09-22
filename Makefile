SHELL := /bin/bash
OPA_VERSION := 1.20.2
CHECK := scripts/check-plan.sh

.DEFAULT_GOAL := help

# expect,<code>,<file>  runs the guardrail and asserts the exit code
define expect
	@out=$$(mktemp); \
	printf '  %-38s expect %s  ' "$(2)" "$(1)"; \
	$(CHECK) "$(2)" >"$$out" 2>&1; rc=$$?; \
	if [ "$$rc" -eq "$(1)" ]; then \
		printf 'got %s  OK\n' "$$rc"; rm -f "$$out"; \
	else \
		printf 'got %s  FAILED\n' "$$rc"; cat "$$out"; rm -f "$$out"; exit 1; \
	fi
endef

.PHONY: help
help:
	@echo "make test              run the Rego unit tests"
	@echo "make demo-safe         evaluate a safe plan   (expect exit 0)"
	@echo "make demo-risky        evaluate risky plans   (expect exit 1)"
	@echo "make demo-malformed    evaluate a bad input   (expect exit 2)"
	@echo "make demo-suppression  evaluate a suppression attempt (expect exit 3)"
	@echo "make adversarial       all six adversarial cases with asserted exit codes"
	@echo "make verify            format check + tests + adversarial. The full gate."
	@echo "make fmt               rewrite Rego files in canonical format"
	@echo "make install-opa       install OPA $(OPA_VERSION) to ./bin"

.PHONY: tools
tools:
	@command -v opa >/dev/null || { echo "opa not on PATH. run: make install-opa"; exit 2; }
	@command -v jq  >/dev/null || { echo "jq not on PATH."; exit 2; }

.PHONY: install-opa
install-opa:
	@mkdir -p bin
	curl -sSL -o bin/opa https://openpolicyagent.org/downloads/v$(OPA_VERSION)/opa_linux_amd64_static
	chmod +x bin/opa
	@echo "installed: $$(pwd)/bin/opa"
	@bin/opa version

.PHONY: test
test: tools
	opa test policies/ -v

.PHONY: fmt
fmt: tools
	opa fmt --write policies/

.PHONY: fmt-check
fmt-check: tools
	opa fmt --fail --list policies/

.PHONY: demo-safe
demo-safe: tools
	$(CHECK) examples/safe-plan.json

.PHONY: demo-risky
demo-risky: tools
	-@$(CHECK) examples/risky-rds-replacement.json
	@echo
	-@$(CHECK) examples/risky-bucket-delete.json

.PHONY: demo-malformed
demo-malformed: tools
	-@$(CHECK) examples/malformed-plan.json

.PHONY: demo-suppression
demo-suppression: tools
	-@$(CHECK) examples/suppression-attempt.json

.PHONY: adversarial
adversarial: tools
	@echo "adversarial cases"
	$(call expect,1,examples/risky-bucket-delete.json)
	$(call expect,1,examples/risky-rds-replacement.json)
	$(call expect,0,examples/safe-plan.json)
	$(call expect,2,examples/malformed-plan.json)
	$(call expect,2,examples/not-json.txt)
	$(call expect,2,examples/no-such-plan.json)
	$(call expect,3,examples/suppression-attempt.json)
	@printf '  %-38s expect 2  ' "(no argument)"; \
	$(CHECK) >/dev/null 2>&1; rc=$$?; \
	if [ "$$rc" -eq 2 ]; then printf 'got %s  OK\n' "$$rc"; else printf 'got %s  FAILED\n' "$$rc"; exit 1; fi

.PHONY: lint
lint:
	@if command -v shellcheck >/dev/null; then shellcheck scripts/check-plan.sh && echo "shellcheck clean"; \
	else echo "shellcheck not installed, skipped"; fi

.PHONY: verify
verify: fmt-check lint test adversarial
	@echo
	@echo "VERIFY OK: format clean, unit tests pass, all adversarial exit codes as specified."
