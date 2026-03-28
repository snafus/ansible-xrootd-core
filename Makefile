# ansible-xrootd-core — local development targets
# Usage: make <target>

.DEFAULT_GOAL := help
.PHONY: help install lint syntax-check molecule molecule-converge molecule-verify clean ci

# Colours for output
BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[32m
CYAN  := \033[36m

help:
	@echo ""
	@echo "$(BOLD)ansible-xrootd-core — available targets$(RESET)"
	@echo ""
	@echo "  $(CYAN)install$(RESET)           Install Python deps and Ansible collections"
	@echo "  $(CYAN)lint$(RESET)              Run yamllint and ansible-lint"
	@echo "  $(CYAN)syntax-check$(RESET)      Run --syntax-check on all playbooks"
	@echo "  $(CYAN)molecule$(RESET)          Full molecule test (create → converge → verify → destroy)"
	@echo "  $(CYAN)molecule-converge$(RESET) Converge only (keep container for debugging)"
	@echo "  $(CYAN)molecule-verify$(RESET)   Verify only (against existing converged container)"
	@echo "  $(CYAN)ci$(RESET)               Run the full local CI sequence: lint → syntax-check → molecule"
	@echo "  $(CYAN)clean$(RESET)             Destroy molecule containers and remove cache"
	@echo ""

# ── Setup ───────────────────────────────────────────────────────────────────

install:
	@echo "$(BOLD)Installing Python dependencies...$(RESET)"
	pip install -r dev-requirements.txt
	@echo "$(BOLD)Installing Ansible collections...$(RESET)"
	ansible-galaxy collection install -r requirements.yml
	@echo "$(GREEN)Done.$(RESET)"

# ── Linting ─────────────────────────────────────────────────────────────────

lint:
	@echo "$(BOLD)Running yamllint...$(RESET)"
	yamllint .
	@echo "$(BOLD)Running ansible-lint...$(RESET)"
	ansible-lint
	@echo "$(GREEN)Lint passed.$(RESET)"

# ── Syntax check ────────────────────────────────────────────────────────────

syntax-check:
	@echo "$(BOLD)Syntax check: site.yml$(RESET)"
	ansible-playbook site.yml --syntax-check -i tests/inventory/hosts.yml
	@echo "$(BOLD)Syntax check: playbooks/certificates.yml$(RESET)"
	ansible-playbook playbooks/certificates.yml --syntax-check -i tests/inventory/hosts.yml
	@echo "$(GREEN)Syntax check passed.$(RESET)"

# ── Molecule ────────────────────────────────────────────────────────────────

molecule:
	@echo "$(BOLD)Running molecule test (Rocky 9)...$(RESET)"
	molecule test

molecule-converge:
	@echo "$(BOLD)Molecule converge (container kept running)...$(RESET)"
	molecule converge

molecule-verify:
	@echo "$(BOLD)Molecule verify...$(RESET)"
	molecule verify

# ── Full local CI ───────────────────────────────────────────────────────────

ci: lint syntax-check molecule
	@echo "$(GREEN)$(BOLD)All checks passed.$(RESET)"

# ── Cleanup ─────────────────────────────────────────────────────────────────

clean:
	@echo "$(BOLD)Destroying molecule containers...$(RESET)"
	molecule destroy || true
	rm -rf molecule/default/.cache
	@echo "$(GREEN)Clean.$(RESET)"
