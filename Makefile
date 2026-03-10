# srsran-operator Makefile
# Heavily inspired by the OAI ran-deployment operator Makefile.

# Image and version settings
IMG ?= docker.io/nephio/srsran-operator:latest
CONTROLLER_GEN ?= $(shell which controller-gen 2>/dev/null || echo go run sigs.k8s.io/controller-tools/cmd/controller-gen@latest)
ENVTEST ?= $(shell which setup-envtest 2>/dev/null || echo go run sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
GOBIN=$(shell go env GOBIN)
ifeq ($(GOBIN),)
GOBIN=$(shell go env GOPATH)/bin
endif

# Setting SHELL to bash allows bash commands to be used in recipes.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", $$2 } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: ## Generate ClusterRole RBAC manifests.
	$(CONTROLLER_GEN) rbac:roleName=srsran-operator-role paths="./..." output:rbac:artifacts:config=config/rbac

.PHONY: generate
generate: ## Generate DeepCopy methods.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./api/..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: fmt vet ## Run unit tests.
	go test ./internal/controller/... -v -count=1

.PHONY: lint
lint: ## Run golangci-lint (requires golangci-lint installed).
	golangci-lint run ./...

##@ Build

.PHONY: build
build: fmt vet ## Build manager binary.
	go build -o bin/manager ./cmd/main.go

.PHONY: run
run: fmt vet ## Run manager from your host (requires kubeconfig).
	go run ./cmd/main.go

.PHONY: docker-build
docker-build: ## Build container image.
	docker build -t $(IMG) .

.PHONY: docker-push
docker-push: ## Push container image.
	docker push $(IMG)

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	kubectl apply -f config/crd/bases/

.PHONY: uninstall
uninstall: manifests ## Uninstall CRDs from the K8s cluster.
	kubectl delete --ignore-not-found=$(ignore-not-found) -f config/crd/bases/

.PHONY: deploy
deploy: manifests ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	kubectl apply -f config/rbac/
	kubectl apply -f config/manager/

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster.
	kubectl delete --ignore-not-found=$(ignore-not-found) -f config/rbac/
	kubectl delete --ignore-not-found=$(ignore-not-found) -f config/manager/

##@ Kind Redeploy

# Configurable variables – override on command line if needed.
KIND_WORKER    ?= regional-md-0-d55dw-lx5gd-sp69g
OPERATOR_NS    ?= srsran
GNB_KUBECONFIG ?= /home/free5gc/regional.kubeconfig
GNB_NS         ?= srsran-gnb
GNB_CLUSTER    ?= regional

.PHONY: build-linux
build-linux: ## Build the manager binary for linux/amd64 (no CGO).
	CGO_ENABLED=0 GOOS=linux go build -o manager ./cmd/main.go

.PHONY: docker-build-sudo
docker-build-sudo: ## Build the container image using sudo docker.
	sudo docker build -t $(IMG) .

.PHONY: kind-load
kind-load: ## Save the image and import it into the kind worker node via ctr.
	sudo docker save $(IMG) | \
		sudo docker exec -i $(KIND_WORKER) ctr -n k8s.io images import -

.PHONY: restart-operator
restart-operator: ## Rollout-restart the srsran-operator deployment and wait for it.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout restart \
		deployment/srsran-operator -n $(OPERATOR_NS)
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout status \
		deployment/srsran-operator -n $(OPERATOR_NS) --timeout=60s

.PHONY: restart-gnb
restart-gnb: ## Rollout-restart all three gNB deployments and wait for them.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout restart \
		deployment/gnb-$(GNB_CLUSTER)-cucp \
		deployment/gnb-$(GNB_CLUSTER)-cuup \
		deployment/gnb-$(GNB_CLUSTER)-du \
		-n $(GNB_NS)
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout status \
		deployment/gnb-$(GNB_CLUSTER)-cucp -n $(GNB_NS) --timeout=120s
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout status \
		deployment/gnb-$(GNB_CLUSTER)-cuup -n $(GNB_NS) --timeout=120s
	kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout status \
		deployment/gnb-$(GNB_CLUSTER)-du   -n $(GNB_NS) --timeout=120s

.PHONY: restart-all
restart-all: build-linux docker-build-sudo kind-load restart-operator ## Full redeploy: build → docker → kind load → restart operator → restart gnb.
	@echo "Waiting 15s for operator to fully start and reconcile..."
	sleep 15
	$(MAKE) restart-gnb

##@ srsRAN gNB Scale

.PHONY: gnb-down
gnb-down: ## Scale down CU-CP, CU-UP, DU deployments to 0.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) scale deployment \
		gnb-$(GNB_CLUSTER)-cucp \
		gnb-$(GNB_CLUSTER)-cuup \
		gnb-$(GNB_CLUSTER)-du \
		--replicas=0 -n $(GNB_NS)

.PHONY: gnb-up
gnb-up: ## Scale up CU-CP, CU-UP, DU deployments to 1 (init containers handle ordering).
	kubectl --kubeconfig=$(GNB_KUBECONFIG) scale deployment \
		gnb-$(GNB_CLUSTER)-cucp \
		gnb-$(GNB_CLUSTER)-cuup \
		gnb-$(GNB_CLUSTER)-du \
		--replicas=1 -n $(GNB_NS)

du-down: ## Scale down CU-CP, CU-UP, DU deployments to 0.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) scale deployment \
		gnb-$(GNB_CLUSTER)-du \
		--replicas=0 -n $(GNB_NS)

cp-down: ## Scale down CU-CP, CU-UP, DU deployments to 0.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) scale deployment \
		gnb-$(GNB_CLUSTER)-cucp \
		--replicas=0 -n $(GNB_NS)

up-down: ## Scale down CU-CP, CU-UP, DU deployments to 0.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) scale deployment \
		gnb-$(GNB_CLUSTER)-cuup \
		--replicas=0 -n $(GNB_NS)