.PHONY: help install test spec coverage lint lint-fix docs build verify clean console tag

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

tag: ## Tag a release and push it. Usage: make tag [VERSION=x.y.z] [FORCE=1]
	@set -e; \
	git diff --cached --quiet || { echo "Error: 索引中已有暂存改动，请先提交或 git reset"; exit 1; }; \
	git fetch --tags --quiet; \
	CURRENT=$$(ruby -Ilib -rpangram/version -e 'print Pangram::VERSION'); \
	if [ -n "$(VERSION)" ]; then \
		NEW_VERSION=$$(echo "$(VERSION)" | sed 's/^v//'); \
	elif git rev-parse -q --verify "refs/tags/v$$CURRENT" >/dev/null; then \
		NEW_VERSION=$$(ruby -e 'a = ARGV[0].split("."); a[2] = a[2].to_i + 1; print a.join(".")' "$$CURRENT"); \
	else \
		NEW_VERSION=$$CURRENT; \
	fi; \
	echo "$$NEW_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "Error: 非法版本号 $$NEW_VERSION"; exit 1; }; \
	NEW_TAG="v$$NEW_VERSION"; \
	if git rev-parse -q --verify "refs/tags/$$NEW_TAG" >/dev/null; then \
		[ -n "$(FORCE)" ] || { echo "Error: $$NEW_TAG 已存在。RubyGems 同版本不可重复发布，确认要重来请加 FORCE=1"; exit 1; }; \
		echo "FORCE: 删除已存在的 $$NEW_TAG ..."; \
		git tag -d "$$NEW_TAG"; \
		git push origin --delete "$$NEW_TAG" || true; \
	fi; \
	grep -q "^## \[$$NEW_VERSION\]" CHANGELOG.md || { echo "Error: CHANGELOG.md 缺少 ## [$$NEW_VERSION] 条目"; exit 1; }; \
	echo "Updating version to $$NEW_VERSION ..."; \
	ruby -pi -e "sub(/VERSION = .*/, \"VERSION = '$$NEW_VERSION'\")" lib/pangram/version.rb; \
	bundle install --quiet; \
	git add lib/pangram/version.rb Gemfile.lock; \
	git diff --cached --quiet || git commit -m "Release $$NEW_TAG"; \
	git tag "$$NEW_TAG"; \
	echo "Pushing $$NEW_TAG ..."; \
	git push origin HEAD && git push origin "$$NEW_TAG"; \
	echo "Done! Tagged and pushed $$NEW_TAG"
