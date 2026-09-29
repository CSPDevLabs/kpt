# kpt package validation (Epic 9)
YQ ?= yq

.PHONY: test test-recipes help
help: ## List targets
	@grep -E '^[a-zA-Z0-9_.-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

test: test-recipes ## Run all package validation (alias)

test-recipes: ## Validate BNG and DIA recipe packages (no cluster)
	@chmod +x test/validate-recipes.sh
	@YQ="$(YQ)" ./test/validate-recipes.sh
