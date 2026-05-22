#!/usr/bin/env bash
# Alauda Build of OpenTelemetry v2 安装文档测试脚本
# 对应文档: docs/en/installing/install-opentelemetry.mdx
# 覆盖范围:
#   1. 「Installing the Alauda Build of OpenTelemetry v2 Operator」章节（CLI 安装）
#   2. 「Deploying the OpenTelemetry Collector」章节（CLI 部署）

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 测试函数：安装 Operator + 部署 OpenTelemetry Collector
# 第一阶段通过通用 install_operator 覆盖 install-otel:* 全套 Operator 安装代码块：
#   check-packagemanifest-versions / confirm-catalogsource(+output) /
#   create-namespace-opentelemetry-operator2 / create-subscription-opentelemetry-operator2 /
#   wait-installplan-pending / approve-installplan-manual / wait-csv-succeeded / check-csv-status
# 第二阶段覆盖 Collector 相关代码块：
#   create-namespace-opentelemetry-collector / deploy-collector /
#   wait-collector-ready / check-collector-pods(+output)
test_install_opentelemetry() {
    log_info "=========================================="
    log_info "开始 Alauda Build of OpenTelemetry v2 安装测试"
    log_info "=========================================="

    # 步骤 1: 安装 Operator
    log_info "阶段 1: 安装 Alauda Build of OpenTelemetry v2 Operator"
    install_operator \
        "opentelemetry-operator2" \
        "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" \
        "install-otel" || {
        log_error "Alauda Build of OpenTelemetry v2 Operator 安装失败"
        return 1
    }

    # 步骤 2: 创建 Collector 命名空间
    log_info "阶段 2.1: 创建 Collector 命名空间"
    _create_namespace_safe \
        "install-otel:create-namespace-opentelemetry-collector" \
        "opentelemetry-collector" || {
        log_error "创建 opentelemetry-collector 命名空间失败"
        return 1
    }

    # 步骤 3: 部署 OpenTelemetryCollector CR
    log_info "阶段 2.2: 部署 OpenTelemetryCollector CR"
    runme run install-otel:deploy-collector || {
        log_error "部署 OpenTelemetryCollector CR 失败"
        return 1
    }

    log_info "等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1"
    kubectl wait "opentelemetrycollector/otel" \
        -n opentelemetry-collector \
        --for=jsonpath='{.status.scale.statusReplicas}'=1/1 \
        --timeout=180s || {
        log_error "等待 otel OpenTelemetryCollector status.scale.statusReplicas=1/1 失败"
        return 1
    }

    # 步骤 4: 等待 Collector Pod Ready
    log_info "阶段 2.3: 等待 Collector Pod Ready"
    runme run install-otel:wait-collector-ready || {
        log_error "等待 Collector Pod Ready 失败"
        return 1
    }

    # 步骤 5: 验证 Collector Pod 在跑（输出含动态 pod 名后缀和 AGE，使用 __cmp_lines）
    log_info "阶段 2.4: 验证 Collector Pod 状态"
    local output
    output=$(runme run install-otel:check-collector-pods 2>&1)

    if ! __cmp_lines "$output" "$(cat <<'EOF'
+ otel-collector
+ 1/1
+ Running
EOF
    )"; then
        log_error "Collector Pod 状态验证失败"
        log_error "实际输出: $output"
        return 1
    fi
    log_success "Collector Pod 状态验证通过"

    log_success "=========================================="
    log_success "Alauda Build of OpenTelemetry v2 安装测试完成（Operator + Collector）"
    log_success "=========================================="
    return 0
}
