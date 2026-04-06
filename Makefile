.DEFAULT_GOAL := help
.PHONY: up down status validate clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: ## Bootstrap full platform (Kind + ArgoCD + all components)
	@./bootstrap/bootstrap.sh

down: ## Delete the Kind cluster
	@kind delete cluster --name novadeploy 2>/dev/null || true
	@echo "Cluster deleted."

status: ## Show cluster, ArgoCD apps, and pod status
	@echo "=== Cluster ===" && kubectl cluster-info 2>/dev/null || echo "No cluster"
	@echo "\n=== ArgoCD Apps ===" && kubectl get applications -n argocd 2>/dev/null || true
	@echo "\n=== Pods (all namespaces) ===" && kubectl get pods -A --sort-by=.metadata.namespace 2>/dev/null || true

validate: ## Run manifest validation checks (YAML, kustomize, secrets, policies)
	@./ci/validate.sh

clean: down ## Delete cluster and clean up
	@echo "Done."
