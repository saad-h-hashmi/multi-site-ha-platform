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

# ---------------------------------------------------------------- deployment
.PHONY: deploy
deploy: ## Deploy EVERYTHING (network, services, Kubernetes, app, monitoring)
	$(PLAYBOOK) $(PB)/site.yml

.PHONY: network
network: ## Create/update the three-site network (routers + WireGuard + firewall)
	$(PLAYBOOK) $(PB)/10-network.yml

.PHONY: services
services: ## Create/update lab DNS, image registry and the edge load balancer
	$(PLAYBOOK) $(PB)/20-services.yml

.PHONY: kubernetes
kubernetes: ## Create/update the K3s cluster (3 servers + 3 agents)
	$(PLAYBOOK) $(PB)/30-kubernetes.yml

.PHONY: app
app: ## Build, push and deploy the SitePulse application
	$(PLAYBOOK) $(PB)/40-application.yml

.PHONY: monitoring
monitoring: ## Deploy Prometheus and kube-state-metrics
	$(PLAYBOOK) $(PB)/50-monitoring.yml

# ---------------------------------------------------------------- operations
.PHONY: health
health: ## Quick health summary of network, Kubernetes, etcd and the app
	@$(ROOT)/scripts/health.sh

.PHONY: net-status
net-status: ## Show routes, WireGuard tunnels and firewall counters for each site
	@$(ROOT)/scripts/net-status.sh

.PHONY: kubeconfig
kubeconfig: ## Print the export command for kubectl access
	@echo "export KUBECONFIG=$(ROOT)/build/kubeconfig"

.PHONY: backup
backup: ## Back up etcd, application data and secrets into backups/<timestamp>/
	@$(ROOT)/scripts/backup.sh

.PHONY: restore-data
restore-data: ## Restore application data from the newest backup (online, safe)
	@$(ROOT)/scripts/restore.sh data

.PHONY: restore-etcd
restore-etcd: ## Roll the whole cluster back to the newest etcd snapshot (asks first)
	@$(ROOT)/scripts/restore.sh etcd

# ---------------------------------------------------------------- testing
.PHONY: test
test: ## Run the non-destructive tests (network + platform)
	@$(ROOT)/tests/test_network.sh; n=$$?; $(ROOT)/tests/test_platform.sh; p=$$?; exit $$((n|p))

.PHONY: test-failover
test-failover: ## Run the HA failure tests (breaks things on purpose, then restores them)
	@$(ROOT)/tests/test_failover.sh

.PHONY: test-rebuild
test-rebuild: ## Destroy and rebuild everything from code, then run all tests (~15 min)
	@$(ROOT)/tests/test_rebuild.sh

# ---------------------------------------------------------------- lifecycle
.PHONY: rebuild
rebuild: ## Destroy the lab and deploy it again from code (keeps .secrets/)
	ASSUME_YES=1 $(ROOT)/scripts/destroy.sh
	$(MAKE) deploy

.PHONY: clean
clean: ## Remove all lab containers, networks and volumes (asks first; keeps images and secrets)
	@$(ROOT)/scripts/destroy.sh

.PHONY: clean-all
clean-all: ## clean + remove generated secrets and downloaded images
	@$(ROOT)/scripts/destroy.sh --secrets --images

.PHONY: submission
submission: ## Regenerate the submission/ package from docs, diagrams and evidence
	@$(ROOT)/scripts/build-diagrams-doc.sh
	@$(ROOT)/scripts/build-submission.sh
