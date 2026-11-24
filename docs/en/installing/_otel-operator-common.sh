#!/usr/bin/env bash
# OTel Operator 就绪等待（供 runme-test_*.sh source，不单独执行）
#
# 「CSV Succeeded / Deployment Available」不代表 Operator 已能干活，还差两件事：
#   1. webhook 真正可达：重启后 Service 后端要几秒才生效，期间建 CR 会
#      connection refused（ACP-58979 Case 1 / ACP-58980）。
#   2. 拿到 leader lease：卸载时 OLM 先删 ServiceAccount，Operator 释放 lease
#      报 Unauthorized，lease 残留；重装后新 Pod 要等它过期（leaseDuration 137s
#      + retryPeriod 26s 抖动，实测 149~175s）才开始 reconcile。期间 webhook
#      照常放行，但 Collector 迟迟不出 Deployment（ACP-58979 Case 2）。
# 依赖：framework/common.sh 的 log_* 函数。

OTEL_OPERATOR_NS="${OTEL_OPERATOR_NS:-opentelemetry-operator2}"
OTEL_OPERATOR_POD_SELECTOR="app.kubernetes.io/name=opentelemetry-operator"
# lease 名取自 operator 源码 internal/operator/setup.go 的 LeaderElectionID
OTEL_OPERATOR_LEASE="9f7554c3.opentelemetry.io"

# 输出 Running、Ready 且未在删除中的 Operator Pod 名（每行一个）
_otel_operator_ready_pods() {
    kubectl -n "$OTEL_OPERATOR_NS" get pod -l "$OTEL_OPERATOR_POD_SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.deletionTimestamp}{"|"}{.status.phase}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | awk -F'|' '$2 == "" && $3 == "Running" && $4 == "True" { print $1 }'
}

# Operator Pod 全部就绪：至少一个就绪，且不存在未就绪或删除中的 Pod
_otel_operator_pods_settled() {
    local total ready
    total=$(kubectl -n "$OTEL_OPERATOR_NS" get pod -l "$OTEL_OPERATOR_POD_SELECTOR" \
        -o name 2>/dev/null | grep -c .)
    ready=$(_otel_operator_ready_pods | grep -c .)
    [ "$ready" -gt 0 ] && [ "$ready" -eq "$total" ]
}

# 经 apiserver 走一遍 mutating + validating webhook（server 端 dry-run，不落库）
_otel_operator_webhook_serving() {
    kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: webhook-probe
  namespace: ${OTEL_OPERATOR_NS}
spec:
  mode: deployment
  config:
    receivers:
      otlp:
        protocols:
          grpc: {}
    exporters:
      debug: {}
    service:
      pipelines:
        traces:
          receivers: [otlp]
          exporters: [debug]
EOF
}

# lease 持有者是当前就绪的 Operator Pod（holderIdentity 形如 <pod>_<uuid>）
_otel_operator_leader_ready() {
    local holder
    holder=$(kubectl -n "$OTEL_OPERATOR_NS" get lease "$OTEL_OPERATOR_LEASE" \
        -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    [ -n "$holder" ] || return 1
    _otel_operator_ready_pods | grep -qx "${holder%%_*}"
}

# 等 Operator 可用：Pod 就绪 → webhook 可达 → 拿到 leader lease
# 用法: otel_wait_operator_ready [timeout_seconds]（默认 360，覆盖 lease 最坏 ~194s）
otel_wait_operator_ready() {
    local timeout="${1:-360}"
    local start=$SECONDS deadline=$((SECONDS + timeout))
    local stage step next_log
    for stage in pods webhook leader; do
        next_log=$((SECONDS + 30))
        case "$stage" in
            pods)    step="_otel_operator_pods_settled";   log_info "等待 OTel Operator Pod 就绪" ;;
            webhook) step="_otel_operator_webhook_serving"; log_info "等待 OTel Operator webhook 可达（server 端 dry-run）" ;;
            leader)  step="_otel_operator_leader_ready";   log_info "等待 OTel Operator 拿到 leader lease ${OTEL_OPERATOR_LEASE}（卸载后重装需等残留 lease 过期，约 2~3 分钟）" ;;
        esac
        until "$step"; do
            if [ "$SECONDS" -ge "$deadline" ]; then
                log_error "等待 OTel Operator 就绪超时（${timeout}s，卡在 ${stage}）"
                kubectl -n "$OTEL_OPERATOR_NS" get pod -l "$OTEL_OPERATOR_POD_SELECTOR" -o wide 2>&1 || true
                kubectl -n "$OTEL_OPERATOR_NS" get lease "$OTEL_OPERATOR_LEASE" \
                    -o jsonpath='holder={.spec.holderIdentity} renewTime={.spec.renewTime}{"\n"}' 2>&1 || true
                return 1
            fi
            if [ "$SECONDS" -ge "$next_log" ]; then
                log_info "  仍在等待 ${stage}（已 $((SECONDS - start))s）"
                next_log=$((SECONDS + 30))
            fi
            sleep 3
        done
    done
    log_success "OTel Operator 已就绪（用时 $((SECONDS - start))s）"
}
