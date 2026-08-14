.PHONY: help install test spec coverage lint lint-fix docs build verify clean console

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

install: ## Install gem dependencies
	bundle install

spec: ## Run the RSpec test suite
	bundle exec rake spec

test: spec ## Alias for spec

coverage: spec ## Generate the test coverage report
	@echo "Coverage report: coverage/index.html"

lint: ## Run RuboCop
	bundle exec rubocop

lint-fix: ## Run RuboCop with safe and unsafe auto-corrections
	bundle exec rubocop -A

docs: ## Generate YARD API documentation in doc/
	bundle exec yard doc --output-dir doc

build: ## Build the gem in pkg/
	bundle exec rake build

verify: spec lint docs build ## Run all release checks

clean: ## Remove generated artifacts
	rm -rf .yardoc coverage doc pkg .rspec_status

console: ## Start IRB with Pangram loaded
	bundle exec irb -Ilib -rpangram
