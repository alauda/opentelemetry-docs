#!/usr/bin/env bash
# 「不使用 Sidecar 注入发送遥测数据」文档测试脚本
# 对应文档: docs/en/configuration/send-telemetry-data/without-sidecar.mdx
# 覆盖范围:「Procedure」章节步骤 1（no-sidecar:deploy-collector）——
#   以 deployment 模式部署带 k8s_attributes 处理器的 OpenTelemetry Collector，
#   用于验证 Operator「自动创建集群级 RBAC」在 k8s_attributes 场景下确实生效。
#
# 说明:
#   - 文档步骤 2（示例应用 my-app）使用 myapp:latest 占位镜像不可运行，不在测试范围内，
#     故该代码块不加 {name=} 标注；
#   - 文档未包含 observability 命名空间的创建与清理步骤，由本脚本负责（命名空间由本脚本
#     创建时会打上标签，cleanup 仅删除带该标签的命名空间，避免误删环境上同名命名空间）；
#   - exporter endpoint "<jaeger-instance-name>-collector:4317" 为占位值，不影响 Collector
#     的部署与启动（无遥测数据流入时不会触发导出），保持原样不做替换。
#
# 前置:
#   1. 已执行 rbac-resources 测试（授予 Operator 管理集群级 RBAC 的权限）；
#   2. 已安装 Alauda Build of OpenTelemetry v2 Operator。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# ── 常量 ──────────────────────────────────────────────────────────────────────
# Collector 命名空间与实例名（与文档代码块中的 CR 保持一致）
NO_SIDECAR_NS="observability"
NO_SIDECAR_COLLECTOR="otel"
# Collector 相关资源的标签选择器（Operator 为其管理的所有对象统一打的标签）
NO_SIDECAR_POD_SELECTOR="app.kubernetes.io/managed-by=opentelemetry-operator"
# Operator 为该 Collector 自动生成的集群级 RBAC 的选择器（对应 opentelemetry-operator
# internal/manifests/manifestutils.SelectorLabels），cleanup 用于兜底清理
NO_SIDECAR_RBAC_SELECTOR="app.kubernetes.io/managed-by=opentelemetry-operator,app.kubernetes.io/instance=${NO_SIDECAR_NS}.${NO_SIDECAR_COLLECTOR},app.kubernetes.io/component=opentelemetry-collector"
# 标记命名空间由本测试创建，cleanup 据此判断是否可以删除命名空间
NO_SIDECAR_NS_LABEL="runme-test/created-by=without-sidecar"
# 部署成功后观察 Collector 日志的时长（秒），期间日志中不得出现 error 关键词
NO_SIDECAR_LOG_WATCH_SECONDS="${NO_SIDECAR_LOG_WATCH_SECONDS:-30}"

# 失败时输出诊断信息，便于定位 RBAC / 配置问题
_no_sidecar_dump_diagnostics() {
    log_warn "--- Pod 状态 ---"
    kubectl get pods -n "$NO_SIDECAR_NS" -o wide 2>&1 || true
    log_warn "--- OpenTelemetryCollector 状态 ---"
    kubectl get opentelemetrycollector "$NO_SIDECAR_COLLECTOR" -n "$NO_SIDECAR_NS" \
        -o jsonpath='{.status}' 2>&1 || true
    echo ""
    log_warn "--- Collector 日志（最后 50 行）---"
    kubectl logs -n "$NO_SIDECAR_NS" -l "$NO_SIDECAR_POD_SELECTOR" \
        --all-containers --tail=50 --prefix 2>&1 || true
}

# 测试函数：部署 deployment 模式 Collector 并验证 k8s_attributes 无 RBAC 报错
test_without_sidecar() {
    log_info "=========================================="
    log_info "开始 不使用 Sidecar 注入发送遥测数据 测试"
    log_info "=========================================="

    # 步骤 1: 创建 observability 命名空间（文档未包含该步骤，由测试脚本负责）
    log_info "步骤 1: 创建命名空间 $NO_SIDECAR_NS"
    if kubectl get namespace "$NO_SIDECAR_NS" >/dev/null 2>&1; then
        log_info "命名空间 $NO_SIDECAR_NS 已存在，复用"
    else
        kubectl create namespace "$NO_SIDECAR_NS" || {
            log_error "创建命名空间 $NO_SIDECAR_NS 失败"
            return 1
        }
        # 打标签标明由本测试创建，供 cleanup 判断是否可删除
        kubectl label namespace "$NO_SIDECAR_NS" "$NO_SIDECAR_NS_LABEL" --overwrite || {
            log_error "标记命名空间 $NO_SIDECAR_NS 失败"
            return 1
        }
    fi

    # 步骤 2: 以 deployment 模式部署 Collector（processors 含 k8s_attributes）
    # 注意: 文档该代码块的语言标记是 yaml，runme run 对 yaml 块只回显内容不执行（且返回 0），
    #       因此改用 runme print 取出命令内容后 eval 执行。
    log_info "步骤 2: 部署 OpenTelemetryCollector（deployment 模式，含 k8s_attributes 处理器）"
    local deploy_cmd
    deploy_cmd=$(runme print no-sidecar:deploy-collector) || {
        log_error "获取代码块内容失败: no-sidecar:deploy-collector"
        return 1
    }
    if [ -z "$deploy_cmd" ]; then
        log_error "代码块内容为空: no-sidecar:deploy-collector"
        return 1
    fi

    local deploy_output
    deploy_output=$(eval "$deploy_cmd" 2>&1) || {
        log_error "部署 OpenTelemetryCollector 失败"
        log_error "若为 admission webhook 拒绝，请确认已按 installing/rbac-resources.mdx 授予"
        log_error "Operator 管理集群级 RBAC 的权限，且提交资源的用户本身持有对应权限"
        log_error "输出: $deploy_output"
        return 1
    }
    log_info "输出: $deploy_output"

    # 步骤 3: 等待 Collector 就绪
    log_info "步骤 3: 等待 OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/$NO_SIDECAR_COLLECTOR" \
        -n "$NO_SIDECAR_NS" \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        _no_sidecar_dump_diagnostics
        return 1
    }

    log_info "等待 Collector Pod Ready"
    kubectl wait --for=condition=Ready pod -l "$NO_SIDECAR_POD_SELECTOR" \
        -n "$NO_SIDECAR_NS" --timeout=3m || {
        log_error "等待 Collector Pod Ready 失败"
        _no_sidecar_dump_diagnostics
        return 1
    }
    log_success "Collector 部署成功"

    # 步骤 4: 观察日志，确认无 error 关键词
    # k8s_attributes 处理器缺少集群级 RBAC 时，Collector 会在启动后持续输出 list/watch
    # 被拒绝（forbidden）的错误日志，此处以此作为核心断言。
    log_info "步骤 4: 观察 Collector 日志 ${NO_SIDECAR_LOG_WATCH_SECONDS}s，确认无 error 关键词"
    sleep "$NO_SIDECAR_LOG_WATCH_SECONDS"

    local logs
    logs=$(kubectl logs -n "$NO_SIDECAR_NS" -l "$NO_SIDECAR_POD_SELECTOR" \
        --all-containers --tail=-1 --prefix 2>&1) || {
        log_error "获取 Collector 日志失败"
        log_error "输出: $logs"
        return 1
    }
    if [ -z "$logs" ]; then
        log_error "Collector 日志为空，无法完成观察（正常启动的 Collector 至少会输出启动日志）"
        _no_sidecar_dump_diagnostics
        return 1
    fi

    # 观察窗口内不得发生容器重启：重启会重置日志，可能掩盖启动期的错误
    local restart_total
    restart_total=$(kubectl get pods -n "$NO_SIDECAR_NS" -l "$NO_SIDECAR_POD_SELECTOR" \
        -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null \
        | awk '{s=0; for (i=1; i<=NF; i++) s+=$i; print s+0}')
    if [ "${restart_total:-0}" -ne 0 ]; then
        log_error "观察期内 Collector 容器发生了 ${restart_total} 次重启"
        _no_sidecar_dump_diagnostics
        return 1
    fi

    # error 关键词不区分大小写：统一转小写后断言不包含
    local logs_lower
    logs_lower=$(printf '%s' "$logs" | tr '[:upper:]' '[:lower:]')
    if ! __cmp_not_contains "$logs_lower" "error"; then
        log_error "Collector 日志中检测到 error 关键词（k8s_attributes 处理器缺少集群级 RBAC 时的典型现象）"
        log_error "匹配行（最多 20 行）:"
        printf '%s\n' "$logs" | grep -i "error" | head -n 20 >&2
        return 1
    fi
    log_success "Collector 日志 ${NO_SIDECAR_LOG_WATCH_SECONDS}s 内无 error 关键词"

    log_success "=========================================="
    log_success "不使用 Sidecar 注入发送遥测数据 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 清理函数：删除 Collector 与 observability 命名空间
# 注意: 启用自动 RBAC 后 Operator 会给 Collector 加 finalizer，并在删除时回收自动生成的
#       集群级 RBAC，因此本清理必须在卸载 Operator、回收 rbac-resources 授权之前执行。
cleanup_without_sidecar() {
    log_info "=========================================="
    log_info "清理 不使用 Sidecar 注入发送遥测数据 测试资源"
    log_info "=========================================="

    # 步骤 1: 删除 OpenTelemetryCollector
    log_info "步骤 1: 删除 OpenTelemetryCollector $NO_SIDECAR_COLLECTOR"
    kubectl delete opentelemetrycollector "$NO_SIDECAR_COLLECTOR" -n "$NO_SIDECAR_NS" \
        --ignore-not-found=true --timeout=120s || {
        log_error "删除 OpenTelemetryCollector 失败（Operator 异常时 finalizer 可能未被摘除）"
        return 1
    }

    # 步骤 2: 兜底清理 Operator 为该 Collector 自动生成的集群级 RBAC
    # 正常情况下 Operator 的 finalizer 已回收，此处按其选择器标签补删，防止残留集群级资源。
    log_info "步骤 2: 兜底清理 Operator 自动生成的集群级 RBAC"
    kubectl delete clusterrole,clusterrolebinding -l "$NO_SIDECAR_RBAC_SELECTOR" \
        --ignore-not-found=true || {
        log_error "清理自动生成的集群级 RBAC 失败"
        return 1
    }

    # 步骤 3: 删除命名空间（仅删除由本测试创建的命名空间）
    log_info "步骤 3: 删除命名空间 $NO_SIDECAR_NS"
    if kubectl get namespace -l "$NO_SIDECAR_NS_LABEL" -o name 2>/dev/null \
        | grep -qx "namespace/$NO_SIDECAR_NS"; then
        kubectl delete namespace "$NO_SIDECAR_NS" --ignore-not-found=true --timeout=180s || {
            log_error "删除命名空间 $NO_SIDECAR_NS 失败"
            return 1
        }
    else
        log_warn "命名空间 $NO_SIDECAR_NS 不存在或非本测试创建（无 $NO_SIDECAR_NS_LABEL 标签），保留不删除"
    fi

    log_success "测试资源清理完成"
    return 0
}
