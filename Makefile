# Convenience wrappers. Every target is a short command you can also run by
# hand -- see the recipe if you would rather not install make (Windows users
# generally would rather not).

TF := terraform -chdir=terraform

# The interpreter is python3 on Linux and macOS, and python in Git Bash on
# Windows, which ships no python3. Both names also exist on Windows as App
# Execution Alias shims that may not run at all, so each candidate is executed
# rather than merely located. Override with `make PYTHON=/path/to/python`.
PYTHON ?= $(shell for p in python3 python; do if command -v $$p >/dev/null 2>&1 && $$p -c '' >/dev/null 2>&1; then echo $$p; break; fi; done)

.PHONY: help
help:
	@echo "make test        run every test suite"
	@echo "make test-lambda   Ed25519 + Discord handler (python)"
	@echo "make test-session  idle-shutdown state machine (node)"
	@echo "make test-mods     the mod installer (node)"
	@echo "make test-shell    on-instance scripts (bash, stubbed AWS)"
	@echo "make check       test + terraform validate + shell/node syntax"
	@echo "make docs        regenerate docs/configuration.md from variables.tf"
	@echo "make init        terraform init"
	@echo "make plan        terraform plan"
	@echo "make apply       terraform apply"
	@echo "make destroy     terraform destroy (deletes the server)"
	@echo "make fmt         terraform fmt"
	@echo "make commands    register the Discord slash commands"
	@echo "make shell       open a root shell on the instance via SSM"
	@echo "make logs        tail the Lambda logs"
	@echo "make outputs     show the Terraform outputs"

.PHONY: test
test: test-lambda test-session test-mods test-shell

.PHONY: test-lambda
test-lambda:          ## Ed25519 verification and the Discord handler
	$(PYTHON) -m unittest discover -s tests -v

.PHONY: test-session
test-session:         ## the idle-shutdown state machine
	node --test tests/test_session.js

.PHONY: test-mods
test-mods:            ## the Fabric mod installer
	node --test tests/test_mods.js

.PHONY: test-shell
test-shell:           ## the on-instance scripts, against stubbed AWS and systemd
	bash tests/shell/run.sh

.PHONY: docs
docs:                 ## regenerate the configuration reference from variables.tf
	$(PYTHON) scripts/generate_config_docs.py

.PHONY: check
check: test
	$(TF) fmt -recursive
	$(TF) validate
	@for f in server/bin/*.sh server/bin/mc; do bash -n "$$f" || exit 1; done
	@for f in server/bin/*.js; do node --check "$$f" || exit 1; done
	@$(PYTHON) -m py_compile lambda/*.py scripts/*.py
	@$(PYTHON) scripts/generate_config_docs.py --check
	@echo "all checks passed"

.PHONY: init
init:
	$(TF) init

.PHONY: plan
plan:
	$(TF) plan

.PHONY: apply
apply:
	$(TF) apply

.PHONY: destroy
destroy:
	@echo "This deletes the instance, the world volume and the backup bucket."
	$(TF) destroy

.PHONY: fmt
fmt:
	$(TF) fmt -recursive

.PHONY: commands
commands:
	$(PYTHON) scripts/register_commands.py

.PHONY: outputs
outputs:
	$(TF) output

.PHONY: shell
shell:
	@$$($(TF) output -raw shell_command)

.PHONY: logs
logs:
	@$$($(TF) output -raw logs_command)
