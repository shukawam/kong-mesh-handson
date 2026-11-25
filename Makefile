CLUSTER_NAME   ?= kong-mesh
KIND_CONFIG    ?= kind/cluster.yaml
# kind のノードイメージは kind バージョンごとに検証済みのダイジェストが異なるため、固定したい場合のみ指定する
KIND_NODE_IMAGE ?=
KUBE_CONTEXT    = kind-$(CLUSTER_NAME)

ifneq ($(KIND_NODE_IMAGE),)
KIND_IMAGE_FLAG = --image $(KIND_NODE_IMAGE)
endif

.DEFAULT_GOAL := help

.PHONY: help
help: ## ターゲット一覧を表示
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: check-tools
check-tools: ## 必要な CLI (docker, kind, kubectl, helm) が揃っているか確認
	@for t in docker kind kubectl helm; do \
		command -v $$t >/dev/null 2>&1 || { echo "missing: $$t (brew install $$t)"; exit 1; }; \
	done
	@docker info >/dev/null 2>&1 || { echo "docker daemon is not running"; exit 1; }
	@echo "all tools available"

.PHONY: install-tools
install-tools: ## Homebrew で kind をインストール (未導入のものだけ)
	@command -v kind >/dev/null 2>&1 || brew install kind
	@command -v kubectl >/dev/null 2>&1 || brew install kubectl
	@command -v helm >/dev/null 2>&1 || brew install helm

.PHONY: cluster-up
cluster-up: check-tools ## kind クラスタを作成 (既存なら何もしない)
	@if kind get clusters 2>/dev/null | grep -qx "$(CLUSTER_NAME)"; then \
		echo "cluster '$(CLUSTER_NAME)' already exists"; \
	else \
		kind create cluster --name $(CLUSTER_NAME) --config $(KIND_CONFIG) $(KIND_IMAGE_FLAG); \
	fi
	@kubectl config use-context $(KUBE_CONTEXT)

.PHONY: cluster-down
cluster-down: ## kind クラスタを削除
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: cluster-recreate
cluster-recreate: cluster-down cluster-up ## kind クラスタを作り直す

.PHONY: cluster-status
cluster-status: ## ノードと Pod の状態を表示
	kubectl --context $(KUBE_CONTEXT) get nodes -o wide
	kubectl --context $(KUBE_CONTEXT) get pods -A

.PHONY: wait-ready
wait-ready: ## 全ノードが Ready になるまで待機
	kubectl --context $(KUBE_CONTEXT) wait --for=condition=Ready nodes --all --timeout=180s

# ---- Kong Mesh (Konnect zone) ----
MESH_CHART_VERSION ?= 2.14.6
MESH_NAMESPACE     ?= kong-mesh-system
MESH_VALUES        ?= mesh/values.yaml
-include .env
export

.PHONY: mesh-install
mesh-install: ## .env の Zone 情報 (トークン / CP ID / リージョン / ゾーン名) で Zone CP を helm でインストール/更新
	@for v in MESH_ZONE_NAME KONNECT_ZONE_TOKEN KONNECT_CP_ID KONNECT_REGION; do \
		test -n "$$(printenv $$v)" || { echo "$$v is not set (see .env.example)"; exit 1; }; \
	done
	helm repo add kong-mesh https://kong.github.io/kong-mesh-charts >/dev/null 2>&1 || true
	helm repo update kong-mesh >/dev/null
	kubectl --context $(KUBE_CONTEXT) create namespace $(MESH_NAMESPACE) --dry-run=client -o yaml | kubectl --context $(KUBE_CONTEXT) apply -f -
	kubectl --context $(KUBE_CONTEXT) -n $(MESH_NAMESPACE) create secret generic cp-token --from-literal=token="$(KONNECT_ZONE_TOKEN)" --dry-run=client -o yaml | kubectl --context $(KUBE_CONTEXT) apply -f -
	helm --kube-context $(KUBE_CONTEXT) upgrade --install kong-mesh kong-mesh/kong-mesh -n $(MESH_NAMESPACE) --version $(MESH_CHART_VERSION) --reset-values -f $(MESH_VALUES) \
		--set kuma.controlPlane.zone=$(MESH_ZONE_NAME) \
		--set kuma.controlPlane.kdsGlobalAddress=grpcs://$(KONNECT_REGION).mesh.sync.konghq.com:443 \
		--set kuma.controlPlane.konnect.cpId=$(KONNECT_CP_ID) \
		--wait --timeout 5m

.PHONY: mesh-uninstall
mesh-uninstall: ## Zone CP を削除
	helm --kube-context $(KUBE_CONTEXT) uninstall kong-mesh -n $(MESH_NAMESPACE) || true
	kubectl --context $(KUBE_CONTEXT) delete namespace $(MESH_NAMESPACE) --ignore-not-found

.PHONY: mesh-status
mesh-status: ## Zone CP の Pod と Konnect への KDS 接続エラー件数を表示
	kubectl --context $(KUBE_CONTEXT) get pods -n $(MESH_NAMESPACE)
	@echo "KDS errors (last 10m): $$(kubectl --context $(KUBE_CONTEXT) logs -n $(MESH_NAMESPACE) deploy/kong-mesh-control-plane --since=10m | grep -cE 'RST_STREAM|component terminated' || true)"

.PHONY: mesh-gui
mesh-gui: ## Zone CP の GUI を http://localhost:5681/gui で公開 (Ctrl+C で終了)
	kubectl --context $(KUBE_CONTEXT) -n $(MESH_NAMESPACE) port-forward svc/kong-mesh-control-plane 5681:5681

# ---- Demo app (Bookinfo) ----
DEMO_NAMESPACE ?= bookinfo

.PHONY: demo-install
demo-install: ## Bookinfo を sidecar なし (メッシュ外) でデプロイ
	kubectl --context $(KUBE_CONTEXT) apply -f demo/namespace.yaml
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) apply -f demo/bookinfo.yaml
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) wait --for=condition=Available deploy --all --timeout=600s

# sidecar は Pod 作成時の webhook でしか注入されないので、ラベル付与後に既存 Pod を作り直す必要がある
.PHONY: demo-join
demo-join: ## Bookinfo を default Mesh に参加させる (注入ラベル付与 + 再起動、Konnect 側に default Mesh が必要)
	@kubectl --context $(KUBE_CONTEXT) get mesh default >/dev/null 2>&1 || { echo "Mesh 'default' is not synced to this zone. Create it in Konnect > Service Mesh > Meshes first."; exit 1; }
	kubectl --context $(KUBE_CONTEXT) label namespace $(DEMO_NAMESPACE) kuma.io/sidecar-injection=enabled --overwrite
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) rollout restart deploy
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) rollout status deploy --timeout=600s

.PHONY: demo-uninstall
demo-uninstall: ## Bookinfo を削除
	kubectl --context $(KUBE_CONTEXT) delete namespace $(DEMO_NAMESPACE) --ignore-not-found

.PHONY: demo-status
demo-status: ## Bookinfo の Pod (sidecar 込みの READY 数) を表示
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) get pods -o wide

.PHONY: demo-check
demo-check: ## productpage を COUNT 回 (既定 10) 呼び、reviews のバージョン・所要時間・ratings の取得結果を表示
	@KUBE_CONTEXT=$(KUBE_CONTEXT) DEMO_NAMESPACE=$(DEMO_NAMESPACE) ./demo/check.sh

.PHONY: demo-open
demo-open: ## productpage を http://localhost:9080/productpage で公開 (Ctrl+C で終了)
	kubectl --context $(KUBE_CONTEXT) -n $(DEMO_NAMESPACE) port-forward svc/productpage 9080:9080
