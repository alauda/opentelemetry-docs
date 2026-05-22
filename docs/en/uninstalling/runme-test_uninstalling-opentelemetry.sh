#!/usr/bin/env bash
# Alauda Build of OpenTelemetry v2 卸载文档测试脚本
# 对应文档: docs/en/uninstalling/uninstalling-opentelemetry.mdx
# 覆盖范围: 「Uninstalling via the CLI」+「Deleting OpenTelemetry custom resource definitions」
#           （web console 章节为 UI 操作不可自动化）
#
# 支持参数:
#   --skip-operator-and-crds  跳过删除 Operator subscription 与 OpenTelemetry CRDs
#                              便于跨 suite 场景下保留 Operator 与 CRDs 供其它测试复用

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# 私有辅助：查询并删除 namespace-scoped 资源
# 用法: _delete_namespaced_by_template <kind-名称> <get-runme-块> <delete-runme-块>
# 流程:
#   1. 执行 get-* 块拿到 "kubectl get ... --all-namespaces" 表格输出
#   2. 跳过表头与 "No resources found"，解析每行的 NAMESPACE / NAME
#   3. 用 runme print 取 delete-* 模板，把 <name> / <namespace> 占位替换为真实值后 eval
#   4. 校验输出包含 "deleted" 关键字
#   5. 若 get-* 返回空，幂等地跳过本步骤
_delete_namespaced_by_template() {
    local kind="$1" get_block="$2" delete_block="$3"

    log_info "查询 $kind 资源"
    local list_output
    list_output=$(runme run "$get_block" 2>&1) || {
        log_error "查询 $kind 资源失败: $list_output"
        return 1
    }

    local rows
    rows=$(echo "$list_output" | awk 'NR>1 && $0 !~ /No resources/ && NF >= 2 {print $1, $2}')

    if [ -z "$rows" ]; then
        log_info "没有 $kind 资源，跳过删除"
        return 0
    fi

    local delete_template
    delete_template=$(runme print "$delete_block")
    if [ -z "$delete_template" ]; then
        log_error "无法获取 $kind 删除模板: $delete_block"
        return 1
    fi

    while read -r ns name; do
        if [ -z "$ns" ] || [ -z "$name" ]; then
            continue
        fi
        local cmd="${delete_template//<name>/$name}"
        cmd="${cmd//<namespace>/$ns}"
        log_info "删除 $kind/$name in ns=$ns"
        local output
        output=$(eval "$cmd" 2>&1) || {
            log_error "删除 $kind/$name 失败: $output"
            return 1
        }
        if [[ "$output" != *"deleted"* ]]; then
            log_error "$kind/$name 删除输出未包含 'deleted' 关键字"
            log_error "实际输出: $output"
            return 1
        fi
        log_success "$kind/$name 已删除"
    done <<< "$rows"

    return 0
}

# 测试函数：卸载 Alauda Build of OpenTelemetry v2
test_uninstalling_opentelemetry() {
    log_info "=========================================="
    log_info "开始 Alauda Build of OpenTelemetry v2 卸载测试"
    log_info "=========================================="

    # 步骤 1: 查询并删除所有 Instrumentation
    log_info "步骤 1: 删除 Instrumentation 资源"
    _delete_namespaced_by_template \
        "Instrumentation" \
        "uninstall-otel:get-instrumentation" \
        "uninstall-otel:delete-instrumentation" || return 1

    # 步骤 2: 查询并删除所有 OpenTelemetryCollector
    log_info "步骤 2: 删除 OpenTelemetryCollector 资源"
    _delete_namespaced_by_template \
        "OpenTelemetryCollector" \
        "uninstall-otel:get-collector" \
        "uninstall-otel:delete-collector" || return 1

    # 步骤 3-4: (可选) 删除 Operator subscription 与 CRDs
    # 受 --skip-operator-and-crds 控制：传入时保留 Operator 与 CRDs 以便后续测试复用。
    if [ "${SKIP_OPERATOR_AND_CRDS:-false}" = "true" ]; then
        log_info "步骤 3-4: 跳过删除 OTel Operator subscription 与 CRDs (--skip-operator-and-crds)"
    else
        # 步骤 3: 删除 Operator subscription
        log_info "步骤 3: 删除 OTel Operator subscription"
        local sub_output sub_expected
        sub_output=$(runme run uninstall-otel:delete-subscription 2>&1) || {
            log_error "删除 OTel Operator subscription 失败: $sub_output"
            return 1
        }
        sub_expected=$(runme print uninstall-otel:delete-subscription-output)
        if ! __cmp_contains "$sub_output" "$sub_expected"; then
            log_error "OTel Operator subscription 删除输出校验失败"
            log_error "期待包含: $sub_expected"
            log_error "实际输出: $sub_output"
            return 1
        fi
        log_success "OTel Operator subscription 已删除"

        # 步骤 4: 删除 OpenTelemetry CRDs
        log_info "步骤 4: 删除 OpenTelemetry CRDs"
        runme run uninstall-otel:delete-crds || {
            log_error "删除 OpenTelemetry CRDs 失败"
            return 1
        }
        log_success "OpenTelemetry CRDs 已删除"
    fi

    log_success "=========================================="
    log_success "Alauda Build of OpenTelemetry v2 卸载测试完成"
    log_success "=========================================="
    return 0
}
