
.DEFAULT_GOAL := help

DOCKER_OPTS=--rm -v $(PWD):/brokerpak -w /brokerpak
CSB=ghcr.io/gsa/cloud-service-broker:v0.4.1gsa
SECURITY_USER_NAME := $(or $(SECURITY_USER_NAME), user)
SECURITY_USER_PASSWORD := $(or $(SECURITY_USER_PASSWORD), pass)

EDEN_EXEC=eden --client user --client-secret pass --url http://127.0.0.1:8080
SERVICE_NAME=datagov-smtp
PLAN_NAME=base

# Use the env var INSTANCE_NAME for the name of the instance to be created, or
# "instance-$USER" if it was not specified. 
#
# We do this to minimize the chance of people stomping on each other when
# provisioning resources into a shared account, and to make it easy to recognize
# who resources belong to.
#
# We can also use a job ID during CI to avoid collisions from parallel
# invocations, and make it obvious which resources correspond to which CI run.
INSTANCE_NAME ?= instance-$(USER)

CLOUD_BIND_PARAMS="{}"

PREREQUISITES = docker jq eden checkdmarc
K := $(foreach prereq,$(PREREQUISITES),$(if $(shell which $(prereq)),some string,$(error "Missing prerequisite commands $(prereq)")))

check: ## Output variables for sanity-checking
	@echo EDEN_EXEC: $(EDEN_EXEC)
	@echo SERVICE_NAME: $(SERVICE_NAME)
	@echo PLAN_NAME: $(PLAN_NAME)
	@echo CLOUD_PROVISION_PARAMS: $(CLOUD_PROVISION_PARAMS)
	@echo CLOUD_BIND_PARAMS: $(CLOUD_BIND_PARAMS)

clean: demo-down down ## Bring down the broker service if it's up and clean out the database
	@-docker rm -f csb-service-$(SERVICE_NAME)
	@-rm *.brokerpak

# Origin of the subdirectory dependency solution: 
# https://stackoverflow.com/questions/14289513/makefile-rule-that-depends-on-all-files-under-a-directory-including-within-subd#comment19860124_14289872
build: manifest.yml smtp.yml $(shell find terraform) ## Build the brokerpak(s)
	docker run --user $(shell id -u):$(shell id -g) $(DOCKER_OPTS) $(CSB) pak build

# Healthcheck solution from https://stackoverflow.com/a/47722899 
# (Alpine inclues wget, but not curl.)
up: ## Run the broker service with the brokerpak configured. The broker listens on `0.0.0.0:8080`. curl http://127.0.0.1:8080 or visit it in your browser. 
	docker run $(DOCKER_OPTS) \
	-p 8080:8080 \
	-e SECURITY_USER_NAME=$(SECURITY_USER_NAME) \
	-e SECURITY_USER_PASSWORD=$(SECURITY_USER_PASSWORD) \
	-e GSB_DEBUG=true \
	-e "DB_TYPE=sqlite3" \
	-e "DB_PATH=/tmp/csb-db" \
	--env-file .env.secrets \
	--name csb-service-$(SERVICE_NAME) \
	--health-cmd="wget --header=\"X-Broker-API-Version: 2.16\" --no-verbose --tries=1 --spider http://$(SECURITY_USER_NAME):$(SECURITY_USER_PASSWORD)@localhost:8080/v2/catalog || exit 1" \
	--health-interval=2s \
	--health-retries=30 \
	-d \
	--rm \
	$(CSB) serve
	@./bin/docker-wait.sh csb-service-$(SERVICE_NAME)
	@docker ps -l

down: .env.secrets ## Bring the cloud-service-broker service down
	@-docker stop csb-service-$(SERVICE_NAME)

# Normally we would just run `$(CSB) client run-examples` to test the brokerpak.
# However, we may need to run tests between bind and unbind. So, we'll
# provision+bind and unbind+deprovision manually with eden via the "demo-up" and
# "demo-down" targets.
test: demo-up demo-run demo-down ## Execute the brokerpak examples against the running broker

test-supplied: demo-up-supplied demo-run demo-down ## Execute the brokerpak examples against the running broker

demo-up: ## Provision an SMTP instance and output the bound credentials
	@$(EDEN_EXEC) provision -i ${INSTANCE_NAME} -s ${SERVICE_NAME}  -p ${PLAN_NAME} -P '{}'
	@$(EDEN_EXEC) bind -b binding -i ${INSTANCE_NAME}

demo-up-supplied: ## Provision an SMTP instance and output the bound credentials
	@$(EDEN_EXEC) provision -i ${INSTANCE_NAME} -s ${SERVICE_NAME}  -p ${PLAN_NAME} -P '"{ \"domain_from\": \"test.com\" }"'
	@$(EDEN_EXEC) bind -b binding -i ${INSTANCE_NAME}

demo-showcreds: ## Show the bound credentials
	@$(EDEN_EXEC) credentials -b binding -i ${INSTANCE_NAME}

demo-run: SHELL:=/bin/bash
demo-run: ## Run tests on the demo instance
	INSTANCE_NAME=${INSTANCE_NAME} ./test.sh

demo-down: ## Clean up data left over from tests and demos
	@echo "Unbinding and deprovisioning the ${SERVICE_NAME} instance"
	-@$(EDEN_EXEC) unbind -b binding -i ${INSTANCE_NAME} 2>/dev/null
	-@$(EDEN_EXEC) deprovision -i ${INSTANCE_NAME} 2>/dev/null

	@echo "Removing any orphan services from eden"
	-@rm ~/.eden/config  2>/dev/null ; true


all: clean build up test down ## Clean and rebuild, then bring up the server, run the examples, and bring the system down
.PHONY: all clean build up down test demo-up demo-down test-env-up test-env-down

.env.secrets:
	$(error Copy .env.secrets-template to .env.secrets, then edit in your own values)

# Output documentation for top-level targets
# Thanks to https://marmelab.com/blog/2016/02/29/auto-documented-makefile.html
.PHONY: help
help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

