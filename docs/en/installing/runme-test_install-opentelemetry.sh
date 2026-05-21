#!/usr/bin/env bash
# Alauda Build of OpenTelemetry v2 Operator 安装文档测试脚本
# 对应文档: docs/en/installing/install-opentelemetry.mdx
# 覆盖范围: 「Installing the Alauda Build of OpenTelemetry v2 Operator」章节

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 测试函数：安装 Alauda Build of OpenTelemetry v2 Operator
# 通过通用 install_operator 覆盖 install-otel:* 全套代码块：
#   check-packagemanifest-versions / confirm-catalogsource(+output) /
#   create-namespace-opentelemetry-operator2 / create-subscription-opentelemetry-operator2 /
#   wait-installplan-pending / approve-installplan-manual / wait-csv-succeeded / check-csv-status
test_install_opentelemetry() {
    log_info "=========================================="
    log_info "开始 Alauda Build of OpenTelemetry v2 Operator 安装测试"
    log_info "=========================================="

    install_operator \
        "opentelemetry-operator2" \
        "opentelemetry-operator2" \
        "$PKG_OPENTELEMETRY_OPERATOR2_URL" \
        "install-otel" || {
        log_error "Alauda Build of OpenTelemetry v2 Operator 安装失败"
        return 1
    }

    log_success "=========================================="
    log_success "Alauda Build of OpenTelemetry v2 Operator 安装测试完成"
    log_success "=========================================="
    return 0
}
