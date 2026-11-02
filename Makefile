NVIM ?= nvim

.PHONY: install reinstall update-vendor test lint format

install: ## download the pinned browser libraries into vendor/
	$(NVIM) --clean -l build.lua

reinstall:
	$(NVIM) --clean -l build.lua --force

update-vendor: ## bump vendor.json to the latest versions (PKGS="marked mermaid@12.2.0" to pick)
	$(NVIM) --clean -l scripts/update-vendor.lua $(PKGS)

test: install ## smoke test: serve a temporary project and request every route
	$(NVIM) --clean -l scripts/smoke.lua

lint:
	stylua --check lua plugin build.lua scripts
	selene lua plugin build.lua scripts

format:
	stylua lua plugin build.lua scripts
