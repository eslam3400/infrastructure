# Run Compose with secrets injected from Infisical.
#
#   make up
#   make verify
#   make logs SERVICE=postgres
#   make up FILE=compose.local.yaml
#   make dc ARGS="ps -a"
#
# .env holds only the machine identity bootstrap values and must be mode 600.

SHELL := /bin/sh
FILE    ?= compose.yaml
ENV     ?= dev
SECRETS ?= DOMAIN POSTGRES_PASSWORD REDIS_PASSWORD

# Load .env, exchange the machine identity for a short-lived token, and drop
# the long-lived client secret from the child environment.
BOOTSTRAP = [ -f .env ] || { echo "missing .env: cp .env.example .env && chmod 600 .env" >&2; exit 1; }; \
	set -eu; \
	set -a; . ./.env; set +a; \
	INFISICAL_TOKEN=$$(infisical login --method=universal-auth \
	  --client-id="$$INFISICAL_UNIVERSAL_AUTH_CLIENT_ID" \
	  --client-secret="$$INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET" \
	  --silent --plain); \
	export INFISICAL_TOKEN; \
	unset INFISICAL_UNIVERSAL_AUTH_CLIENT_ID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET;

RUN = $(BOOTSTRAP) exec infisical run \
	--projectId="$$INFISICAL_PROJECT_ID" \
	--env="$${INFISICAL_ENVIRONMENT:-$(ENV)}" --

COMPOSE = $(RUN) docker compose -f $(FILE)

.DEFAULT_GOAL := help
.PHONY: help verify up down restart ps logs build config shell dc

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F': *## ' '{printf "  %-12s %s\n", $$1, $$2}'

verify: ## Check Infisical injection without Docker (SECRETS="A B")
	@$(RUN) sh -c 'for k in $(SECRETS); do \
	  v=$$(printenv "$$k" || true); \
	  [ -n "$$v" ] && echo "$$k: set" || echo "$$k: MISSING"; \
	done; echo "(values not printed)"'

up: ## Start the stack
	@$(COMPOSE) up -d

down: ## Stop and remove the stack
	@$(COMPOSE) down

restart: ## Recreate containers
	@$(COMPOSE) up -d --force-recreate

ps: ## Container status
	@$(COMPOSE) ps

logs: ## Follow logs (SERVICE=name to filter)
	@$(COMPOSE) logs -f $(SERVICE)

build: ## Build images
	@$(COMPOSE) build

config: ## Render and validate the resolved config
	@$(COMPOSE) config

shell: ## Shell into the sandbox
	@$(COMPOSE) exec sandbox bash

dc: ## Raw compose command (make dc ARGS="pull")
	@$(COMPOSE) $(ARGS)
