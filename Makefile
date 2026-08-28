# Convenience wrappers. Every target is a short command you can also run by
# hand -- see the recipe if you would rather not install make (Windows users
# generally would rather not).

TF := terraform -chdir=terraform

.PHONY: help
help:
	@echo "make test        run every test suite"
	@echo "make test-lambda   Ed25519 + Discord handler (python)"
	@echo "make test-session  idle-shutdown state machine (node)"
	@echo "make test-mods     the mod installer (node)"
	@echo "make test-shell    on-instance scripts (bash, stubbed AWS)"
	@echo "make check       test + terraform validate + shell/node syntax"
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
	python -m unittest discover -s tests -v

.PHONY: test-session
test-session:         ## the idle-shutdown state machine
	node --test tests/test_session.js

.PHONY: test-mods
test-mods:            ## the Fabric mod installer
	node --test tests/test_mods.js

.PHONY: test-shell
test-shell:           ## the on-instance scripts, against stubbed AWS and systemd
	bash tests/shell/run.sh

.PHONY: check
check: test
	$(TF) fmt -recursive
	$(TF) validate
	@for f in server/bin/*.sh server/bin/mc; do bash -n "$$f" || exit 1; done
	@for f in server/bin/*.js; do node --check "$$f" || exit 1; done
	@python -m py_compile lambda/*.py scripts/*.py
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
	python scripts/register_commands.py

.PHONY: outputs
outputs:
	$(TF) output

.PHONY: shell
shell:
	@$$($(TF) output -raw shell_command)

.PHONY: logs
logs:
	@$$($(TF) output -raw logs_command)
