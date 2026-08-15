#!/usr/bin/env bash
# Alauda Build of OpenTelemetry v2「自动创建 RBAC 资源」文档测试脚本
# 对应文档: docs/en/installing/rbac-resources.mdx
# 覆盖范围:
#   1.「Procedure」章节: rbac:create-clusterrole / rbac:create-clusterrolebinding /
#      rbac:restart-operator（文档标注为可选步骤）
#   2.「Removing the RBAC resources」章节: rbac:cleanup
#
# 说明:
#   - 本文档为 Operator 自动创建集群级 RBAC 的前置授权，应在安装 Operator 之前执行：
#     Operator 启动时即可探测到该权限，无需再重启（对应文档步骤 3 的 tip）。
#   - 该授权是 without-sidecar 文档中 k8s_attributes 处理器能被 Operator 自动生成
#     ClusterRole / ClusterRoleBinding 的前提，编排中两者配套使用。

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# Operator 所在命名空间（与文档 ClusterRoleBinding subject、重启命令保持一致）
RBAC_OPERATOR_NS="opentelemetry-operator2"

# 测试函数：授予 Operator 管理集群级 RBAC 资源的权限
test_rbac_resources() {
    log_info "=========================================="
    log_info "开始 自动创建 RBAC 资源 测试"
    log_info "=========================================="

    # 步骤 1: 创建 ClusterRole
    log_info "步骤 1: 创建 ClusterRole generate-processors-rbac"
    local cr_output
    cr_output=$(runme run rbac:create-clusterrole 2>&1) || {
        log_error "创建 ClusterRole 失败"
        log_error "输出: $cr_output"
        return 1
    }
    log_info "输出: $cr_output"

    # 步骤 2: 创建 ClusterRoleBinding
    log_info "步骤 2: 创建 ClusterRoleBinding generate-processors-rbac"
    local crb_output
    crb_output=$(runme run rbac:create-clusterrolebinding 2>&1) || {
        log_error "创建 ClusterRoleBinding 失败"
        log_error "输出: $crb_output"
        return 1
    }
    log_info "输出: $crb_output"

    # 步骤 3:（可选）重启 Operator 使新 RBAC 权限生效
    # 文档 tip: 仅当 Operator 已在运行时才需要执行；在安装 Operator 之前创建 RBAC 时可跳过。
    # 编排中本测试先于 install-opentelemetry 执行，此时 Operator 通常尚未安装，
    # 命名空间不存在导致该命令报错时按「空操作」处理。
    log_info "步骤 3: 重启 Operator 使 RBAC 权限生效（文档标注为可选步骤）"
    local restart_output
    if restart_output=$(runme run rbac:restart-operator 2>&1); then
        log_info "输出: $restart_output"
    else
        if kubectl get namespace "$RBAC_OPERATOR_NS" >/dev/null 2>&1; then
            log_error "重启 Operator 失败"
            log_error "输出: $restart_output"
            return 1
        fi
        log_info "命名空间 $RBAC_OPERATOR_NS 不存在（Operator 尚未安装），该可选步骤为空操作"
    fi

    # Operator 已安装时等待其重新就绪，避免后续测试踩到尚未恢复的 admission webhook
    local operator_deploys
    operator_deploys=$(kubectl -n "$RBAC_OPERATOR_NS" get deployment -o name 2>/dev/null || true)
    if [ -n "$operator_deploys" ]; then
        log_info "等待 Operator Deployment 重新可用: $(echo "$operator_deploys" | tr '\n' ' ')"
        kubectl -n "$RBAC_OPERATOR_NS" wait --for=condition=Available deployment --all --timeout=3m || {
            log_error "等待 Operator 重新就绪失败"
            return 1
        }
    fi

    log_success "=========================================="
    log_success "自动创建 RBAC 资源 测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 清理函数：回收授予 Operator 的集群级 RBAC 管理权限
# 注意: 必须在依赖自动 RBAC 的 OpenTelemetryCollector 全部删除之后执行，
#       否则 Operator 无法回收其为这些 Collector 生成的集群级 RBAC（见文档 warning）。
cleanup_rbac_resources() {
    log_info "=========================================="
    log_info "清理 自动创建 RBAC 资源 测试资源"
    log_info "=========================================="

    runme run rbac:cleanup || {
        log_error "清理 RBAC 资源失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
