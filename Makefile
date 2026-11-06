# Red Hat build of Kueue 1.5 — reserved-spot GPU demo
#
# TOTAL_GPUS must match the nominalQuota in
# cluster-config/02-clusterqueue-serving.yaml.
TOTAL_GPUS ?= 8
export TOTAL_GPUS

.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install the operator + Kueue CR + queues
	./scripts/install.sh

.PHONY: config
config: ## Apply only the queue configuration (operator already installed)
	SKIP_OPERATOR=1 ./scripts/install.sh

.PHONY: fake-gpus
fake-gpus: ## Advertise $(TOTAL_GPUS) simulated nvidia.com/gpu on worker nodes
	./scripts/fake-gpus.sh

.PHONY: unfake-gpus
unfake-gpus: ## Remove the simulated GPUs
	./scripts/fake-gpus.sh --remove

.PHONY: demo
demo: ## Run the guided demo (Enter between steps)
	./scripts/demo.sh

.PHONY: demo-auto
demo-auto: ## Run the demo without stopping
	AUTO=1 ./scripts/demo.sh

.PHONY: watch
watch: ## Live dashboard (run in a second terminal)
	./scripts/watch.sh

.PHONY: status
status: ## One-shot snapshot
	./scripts/status.sh

.PHONY: night-mode
night-mode: ## Install the day/night lendingLimit CronJobs
	oc apply -f cluster-config/optional/night-mode.yaml

.PHONY: reset
reset: ## Delete demo workloads, keep the queues
	./scripts/reset.sh

.PHONY: clean
clean: ## Remove everything, including the operator
	./scripts/uninstall.sh

.PHONY: lint
lint: ## Validate shell syntax, and YAML if PyYAML is available
	@for f in scripts/*.sh; do bash -n $$f && echo "  ok  $$f" || exit 1; done
	@if python3 -c "import yaml" 2>/dev/null; then \
	  for f in $$(find install cluster-config workloads -name '*.yaml'); do \
	    python3 -c "import sys,yaml;list(yaml.safe_load_all(open(sys.argv[1])))" $$f \
	      && echo "  ok  $$f" || exit 1; \
	  done; \
	else \
	  echo "  -- PyYAML not installed, skipping YAML parse (try 'make dry-run' against a cluster)"; \
	fi

.PHONY: dry-run
dry-run: ## Server-side validate every manifest against the cluster
	oc apply --dry-run=server -f install/01-operator.yaml
	oc apply --dry-run=server -f cluster-config/
	oc apply --dry-run=server -f cluster-config/optional/
	oc apply --dry-run=server -f workloads/serving/
	oc create --dry-run=server -f workloads/batch/job-nightly-sweep.yaml
	oc create --dry-run=server -f workloads/batch/job-bulk-eval.yaml
	oc create --dry-run=server -f workloads/batch/job-interactive-finetune.yaml
	oc apply --dry-run=server -f workloads/batch/cronjob-nightly-sweep.yaml
