# srsran-operator Makefile
# Heavily inspired by the OAI ran-deployment operator Makefile.

# Image and version settings
IMG ?= docker.io/nephio/srsran-operator:latest
CONTROLLER_GEN ?= $(shell which controller-gen 2>/dev/null || echo go run sigs.k8s.io/controller-tools/cmd/controller-gen@latest)
ENVTEST ?= $(shell which setup-envtest 2>/dev/null || echo go run sigs.k8s.io/controller-runtime/tools/setup-envtest@latest)

# Configurable variables – override on command line if needed.
KIND_WORKER    ?= regional-md-0-7hcxb-z4qv6-q6r67
OPERATOR_NS    ?= srsran
GNB_KUBECONFIG ?= /home/free5gc/regional.kubeconfig
GNB_NS         ?= srsran-gnb
GNB_CLUSTER    ?= regional

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
manifests: ## Generate CRD and ClusterRole RBAC manifests.
	$(CONTROLLER_GEN) crd paths="./api/..." output:crd:artifacts:config=config/crd/bases
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
install: manifests ## Install CRDs into the workload cluster.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) apply -f config/crd/bases/

.PHONY: uninstall
uninstall: manifests ## Uninstall CRDs from the workload cluster.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete --ignore-not-found=$(ignore-not-found) -f config/crd/bases/

.PHONY: deploy
deploy: manifests ## Deploy controller to the workload cluster.
	kubectl --kubeconfig=$(GNB_KUBECONFIG) apply -f config/rbac/
	kubectl --kubeconfig=$(GNB_KUBECONFIG) apply -f config/manager/

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster.
	kubectl delete --ignore-not-found=$(ignore-not-found) -f config/rbac/
	kubectl delete --ignore-not-found=$(ignore-not-found) -f config/manager/

##@ Kind Redeploy

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

# Default: 10MHz mode. Override with: make update-gnb-config BW=20 for 20MHz.
# 10MHz: SRATE=11.52, BW=10, CORESET0=6
# 20MHz: SRATE=23.04, BW=20, CORESET0=12
SRATE ?= 11.52
BW ?= 10
CORESET0 ?= 6
GITEA_BASE     ?= http://nephio:secret@172.18.0.200:3000/nephio/regional.git

update-gnb-config: ## Update srsRAN config in regional.git (default: 10MHz; use BW=20 for 20MHz).
	@# ConfigSync is the single source of truth – direct configmap edits get reverted.
	@# Operator reads from NFConfig (embedded configs), NOT from standalone SrsRANConfig/SrsRANCellConfig CRs!
	@# So we must update: srsranconfig.yaml, srscellconfig.yaml, AND nfconfig.yaml
	@echo "==> Updating srsRAN config: srate=$(SRATE), bandwidth=$(BW)MHz, coreset0=$(CORESET0)..."
	@REPO_DIR=$$(mktemp -d); \
	git clone $(GITEA_BASE) $$REPO_DIR --depth=1 -q; \
	cd $$REPO_DIR; \
	git config user.email "nephio@nephio.org"; \
	git config user.name "Nephio"; \
	SRSRAN_CFG="srsran-gnb/srsranconfig.yaml"; \
	CELL_CFG="srsran-gnb/srscellconfig.yaml"; \
	NF_CFG="srsran-gnb/nfconfig.yaml"; \
	if [ ! -f $$SRSRAN_CFG ]; then \
		echo "  Error: $$SRSRAN_CFG not found in regional.git"; \
		rm -rf $$REPO_DIR; \
		exit 1; \
	fi; \
	sed -i 's|srate: "[^"]*"|srate: "$(SRATE)"|g' $$SRSRAN_CFG; \
	if [ -f $$CELL_CFG ]; then \
		sed -i 's|channelBandwidthMHz: [0-9]*|channelBandwidthMHz: $(BW)|g' $$CELL_CFG; \
		sed -i 's|coreset0Index: [0-9]*|coreset0Index: $(CORESET0)|g' $$CELL_CFG; \
	fi; \
	if [ -f $$NF_CFG ]; then \
		echo "  Also updating nfconfig.yaml (operator reads embedded configs from here)..."; \
		sed -i 's|srate: "[^"]*"|srate: "$(SRATE)"|g' $$NF_CFG; \
		sed -i 's|channelBandwidthMHz: [0-9]*|channelBandwidthMHz: $(BW)|g' $$NF_CFG; \
		sed -i 's|coreset0Index: [0-9]*|coreset0Index: $(CORESET0)|g' $$NF_CFG; \
	fi; \
	if git diff --quiet; then \
		echo "  regional.git already has desired config – nothing to commit."; \
	else \
		echo "  Changed:"; \
		git diff --no-color | head -40; \
		git add -A; \
		git commit -m "chore: update srsRAN to $(BW)MHz (srate=$(SRATE), coreset0=$(CORESET0))"; \
		git push -q && echo "  ✓ Pushed config to regional.git"; \
	fi; \
	rm -rf $$REPO_DIR
	@echo "==> Waiting 30s for ConfigSync to apply changes..."
	@sleep 30
	@echo "==> Forcing operator to regenerate gNB ConfigMaps..."
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete configmap \
		gnb-$(GNB_CLUSTER)-cucp-config \
		gnb-$(GNB_CLUSTER)-cuup-config \
		gnb-$(GNB_CLUSTER)-du-config \
		-n $(GNB_NS) --ignore-not-found
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete deployment \
		gnb-$(GNB_CLUSTER)-cucp \
		gnb-$(GNB_CLUSTER)-cuup \
		gnb-$(GNB_CLUSTER)-du \
		-n $(GNB_NS) --ignore-not-found
	kubectl --kubeconfig=$(GNB_KUBECONFIG) annotate nfdeployment \
		gnb-$(GNB_CLUSTER) -n $(GNB_NS) \
		config-update="$$(date +%s)" --overwrite
	@echo "==> Waiting 20s for operator to recreate resources..."
	@sleep 20
	@echo "==> Verifying new config in DU ConfigMap:"
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get configmap gnb-$(GNB_CLUSTER)-du-config -n $(GNB_NS) \
		-o jsonpath='{.data.gnb-config\.yml}' 2>/dev/null | \
		grep -E "srate:|channel_bandwidth|coreset0" || echo "  ConfigMap not ready yet"

.PHONY: reconcile-gnb-config
reconcile-gnb-config: ## Force operator to regenerate gNB ConfigMaps after updating SrsRANConfig/SrsRANCellConfig CRs.
	@echo "==> Deleting stale gNB ConfigMaps (operator will regenerate from updated CRs)..."
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete configmap \
		gnb-$(GNB_CLUSTER)-cucp-config \
		gnb-$(GNB_CLUSTER)-cuup-config \
		gnb-$(GNB_CLUSTER)-du-config \
		-n $(GNB_NS) --ignore-not-found
	@echo "==> Deleting stale gNB Deployments (operator will recreate with new ConfigMaps)..."
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete deployment \
		gnb-$(GNB_CLUSTER)-cucp \
		gnb-$(GNB_CLUSTER)-cuup \
		gnb-$(GNB_CLUSTER)-du \
		-n $(GNB_NS) --ignore-not-found
	@echo "==> Annotating NFDeployment to trigger operator reconcile..."
	kubectl --kubeconfig=$(GNB_KUBECONFIG) annotate nfdeployment \
		gnb-$(GNB_CLUSTER) -n $(GNB_NS) \
		config-update="$$(date +%s)" --overwrite
	@echo "==> Waiting 20s for operator to recreate resources..."
	@sleep 20
	@echo "==> Verifying new ConfigMap values..."
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get configmap gnb-$(GNB_CLUSTER)-du-config -n $(GNB_NS) \
		-o jsonpath='{.data.gnb-config\.yml}' 2>/dev/null | \
		grep -E "srate:|channel_bandwidth_MHz:|coreset0_index:" || echo "  ConfigMap not ready yet"
	@echo "==> Deployment status:"
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get deployment -n $(GNB_NS) \
		-l app.kubernetes.io/name=gnb 2>/dev/null || echo "  Deployments not ready yet"

# create-gw1:
# 	sudo docker exec regional-md-0-d55dw-lx5gd-sp69g sh -c "ip link add n6-gw link eth1.4 type macvlan mode bridge 2>/dev/null || true; ip addr add 10.0.1.254/8 dev n6-gw 2>/dev/null || true; ip link set n6-gw up"

##@ N6 Test Interfaces (UPF-based)

.PHONY: upf-iperf-setup
upf-iperf-setup: ## Add secondary IPs and routes to UPF for iperf3 testing
	KUBECONFIG=$(GNB_KUBECONFIG) kubectl exec -n free5gc-upf $$(KUBECONFIG=$(GNB_KUBECONFIG) kubectl get pod -n free5gc-upf -l name=upf-regional -o jsonpath='{.items[0].metadata.name}') -- \
		sh -c "ip addr add 10.0.1.254/8 dev n6 2>/dev/null || true; ip addr add 10.0.1.253/8 dev n6 2>/dev/null || true; ip route add 10.0.2.0/24 dev upfgtp 2>/dev/null || true; ip route add 10.0.3.0/24 dev upfgtp 2>/dev/null || true"

.PHONY: iperf-server-ue1
iperf-server-ue1: ## Run iperf3 server on UPF listening on 10.0.1.254 (for UE1)
	@UPF_CID=$$(sudo docker exec $(KIND_WORKER) crictl ps | grep upf-regional | awk '{print $$1}') && \
	UPF_PID=$$(sudo docker exec $(KIND_WORKER) crictl inspect $$UPF_CID | grep '"pid":' | head -1 | tr -dc '0-9') && \
	sudo docker exec -t $(KIND_WORKER) nsenter -t $$UPF_PID -n iperf3 -s -B 10.0.1.254

.PHONY: iperf-server-ue2
iperf-server-ue2: ## Run iperf3 server on UPF listening on 10.0.1.253 (for UE2)
	@UPF_CID=$$(sudo docker exec $(KIND_WORKER) crictl ps | grep upf-regional | awk '{print $$1}') && \
	UPF_PID=$$(sudo docker exec $(KIND_WORKER) crictl inspect $$UPF_CID | grep '"pid":' | head -1 | tr -dc '0-9') && \
	sudo docker exec -t $(KIND_WORKER) nsenter -t $$UPF_PID -n iperf3 -s -B 10.0.1.253

.PHONY: iperf-clean
iperf-clean: ## Kill iperf3 server processes in Kind worker
	@for PID in $$(sudo docker exec $(KIND_WORKER) ps aux | grep 'iperf3 -s' | grep -v grep | awk '{print $$2}'); do \
		sudo docker exec $(KIND_WORKER) kill -9 $$PID 2>/dev/null || true; \
	done
	@echo "iperf3 processes cleaned"

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

##@ DU Slicing Configuration

.PHONY: update-git-slicing
update-git-slicing: ## Update regional.git with slicing config (eMBB + URLLC). Operator will pick it up.
	@# Updates srscellconfig.yaml and nfconfig.yaml in regional.git to include slicing.
	@# After ConfigSync applies, delete ConfigMaps to force operator reconcile.
	@echo "==> Updating regional.git with slicing configuration..."
	@REPO_DIR=$$(mktemp -d); \
	git clone $(GITEA_BASE) $$REPO_DIR --depth=1 -q; \
	cd $$REPO_DIR; \
	git config user.email "nephio@nephio.org"; \
	git config user.name "Nephio"; \
	CELL_CFG="srsran-gnb/srscellconfig.yaml"; \
	NF_CFG="srsran-gnb/nfconfig.yaml"; \
	if grep -q "^  slicing:" $$CELL_CFG 2>/dev/null; then \
		echo "  srscellconfig.yaml already has slicing config."; \
	else \
		echo "  Adding slicing to srscellconfig.yaml..."; \
		sed -i '/slicing:/d' $$CELL_CFG 2>/dev/null || true; \
		printf '  slicing:\n    - sst: 1\n      sd: 66051\n      schedCfg:\n        minPrbPolicyRatio: 0\n        maxPrbPolicyRatio: 50\n        priority: 10\n    - sst: 1\n      sd: 1122867\n      schedCfg:\n        minPrbPolicyRatio: 0\n        maxPrbPolicyRatio: 100\n        priority: 200\n' >> $$CELL_CFG; \
	fi; \
	if [ -f $$NF_CFG ]; then \
		if grep -q "slicing:" $$NF_CFG; then \
			echo "  nfconfig.yaml already has slicing config."; \
		else \
			echo "  Adding slicing to nfconfig.yaml (embedded SrsRANCellConfig)..."; \
			sed -i '/puschMcsTable: qam64/a\      slicing:\n        - sst: 1\n          sd: 66051\n          schedCfg:\n            minPrbPolicyRatio: 0\n            maxPrbPolicyRatio: 50\n            priority: 10\n        - sst: 1\n          sd: 1122867\n          schedCfg:\n            minPrbPolicyRatio: 0\n            maxPrbPolicyRatio: 100\n            priority: 200' $$NF_CFG; \
		fi; \
	fi; \
	if git diff --quiet; then \
		echo "  regional.git already has slicing config – nothing to commit."; \
	else \
		echo "  Changed:"; \
		git diff --no-color | head -60; \
		git add -A; \
		git commit -m "feat: add network slicing config (eMBB sd=66051, URLLC sd=1122867)"; \
		git push -q && echo "  ✓ Pushed slicing config to regional.git"; \
	fi; \
	rm -rf $$REPO_DIR
	@echo "==> Waiting 30s for ConfigSync to apply changes..."
	@sleep 30
	@echo "==> Forcing operator to regenerate gNB ConfigMaps..."
	kubectl --kubeconfig=$(GNB_KUBECONFIG) delete configmap \
		gnb-$(GNB_CLUSTER)-du-config \
		-n $(GNB_NS) --ignore-not-found
	kubectl --kubeconfig=$(GNB_KUBECONFIG) annotate nfdeployment \
		gnb-$(GNB_CLUSTER) -n $(GNB_NS) \
		config-update="$$(date +%s)" --overwrite
	@echo "==> Waiting 20s for operator to recreate DU ConfigMap..."
	@sleep 20
	@echo "==> Verifying slicing in DU ConfigMap:"
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get configmap gnb-$(GNB_CLUSTER)-du-config -n $(GNB_NS) \
		-o jsonpath='{.data.gnb-config\.yml}' 2>/dev/null | grep -A 15 "slicing:" || echo "  Slicing not found yet - operator may still be reconciling"

.PHONY: fix-du-slicing
fix-du-slicing: ## [DEPRECATED] Patch DU ConfigMap directly. Use update-git-slicing instead.
	@# Operator template doesn't include slicing; patch ConfigMap directly.
	@# Note: This patch is lost when operator recreates ConfigMap. Run after reconcile.
	@echo "==> Patching DU ConfigMap with slicing configuration..."
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get configmap gnb-$(GNB_CLUSTER)-du-config -n $(GNB_NS) -o yaml > /tmp/du-cm.yaml 2>/dev/null || \
		{ echo "  Error: DU ConfigMap not found"; exit 1; }
	@if grep -q "slicing:" /tmp/du-cm.yaml; then \
		echo "  DU ConfigMap already has slicing config – nothing to patch."; \
		rm -f /tmp/du-cm.yaml; \
	else \
		echo "  Adding slicing config (eMBB sd=66051/0x010203, URLLC sd=1122867/0x112233)..."; \
		awk '/pusch:/{p=1} p && /mcs_table: qam64/{print; print "      slicing:"; print "        - # Slice 1: eMBB"; print "          sst: 1"; print "          sd: 66051"; print "          sched_cfg:"; print "            min_prb_policy_ratio: 0"; print "            max_prb_policy_ratio: 50"; print "            priority: 10"; print "        - # Slice 2: URLLC"; print "          sst: 1"; print "          sd: 1122867"; print "          sched_cfg:"; print "            min_prb_policy_ratio: 0"; print "            max_prb_policy_ratio: 100"; print "            priority: 200"; p=0; next} {print}' /tmp/du-cm.yaml > /tmp/du-cm-patched.yaml && mv /tmp/du-cm-patched.yaml /tmp/du-cm.yaml; \
		kubectl --kubeconfig=$(GNB_KUBECONFIG) apply -f /tmp/du-cm.yaml; \
		rm -f /tmp/du-cm.yaml; \
		echo "  ✓ Patched DU ConfigMap. Restarting DU pod..."; \
		kubectl --kubeconfig=$(GNB_KUBECONFIG) rollout restart deployment gnb-$(GNB_CLUSTER)-du -n $(GNB_NS); \
		echo "  ✓ DU restart triggered. Wait ~30s then verify with: make verify-du-slicing"; \
	fi

.PHONY: verify-du-slicing
verify-du-slicing: ## Verify DU ConfigMap has slicing configuration.
	@echo "==> DU slicing configuration:"
	@kubectl --kubeconfig=$(GNB_KUBECONFIG) get configmap gnb-$(GNB_CLUSTER)-du-config -n $(GNB_NS) \
		-o jsonpath='{.data.gnb-config\.yml}' 2>/dev/null | grep -A 20 "slicing:" || echo "  No slicing config found in DU ConfigMap"