# =============================================================================
# Multi-Site HA Platform: one-command entry points.
# Run `make help` for the list. Every target is safe to run repeatedly.
# =============================================================================
SHELL        := /bin/bash
ROOT         := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export ANSIBLE_CONFIG := $(ROOT)/ansible/ansible.cfg
export KUBECONFIG     := $(ROOT)/build/kubeconfig
EXTRA_VARS   := $(if $(wildcard $(ROOT)/config/lab.yml),-e @$(ROOT)/config/lab.yml,)
PLAYBOOK     := ansible-playbook $(EXTRA_VARS)
PB           := $(ROOT)/ansible/playbooks

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

.PHONY: bootstrap
bootstrap: ## One-time host setup (installs Docker, kubectl, WireGuard tools; asks for sudo password)
	$(PLAYBOOK) -K $(PB)/00-host-setup.yml
	@echo ">>> If Docker was just installed, log out and back in (or run 'newgrp docker') so your user can use it."

.PHONY: preflight
preflight: ## Check the host is ready (no changes made)
	@$(ROOT)/scripts/preflight.sh
