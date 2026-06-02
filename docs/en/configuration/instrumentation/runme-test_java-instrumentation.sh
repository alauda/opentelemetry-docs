#!/usr/bin/env bash
# Java 自动注入（Java Auto-instrumentation）测试脚本
# 对应文档: docs/en/configuration/instrumentation/java-instrumentation.mdx
#
# 特殊说明：
#   java-instrumentation.mdx 为概念/参考型文档，其 YAML 示例引用 myjavaapp:latest 等占位镜像，
#   无法真正运行，因此不给原文档代码块添加 {name=} 标注、也不用 runme run 测试。
#   本脚本改为部署 / 卸载 mesh-v2-test-suite 集群插件预置的 Java OTel 示例服务，
#   以真实工作负载验证「Operator 自动注入 OpenTelemetry Java agent」这一核心能力。
#
# 前提：USE_MESH_V2_TEST_SUITE_PLUGIN=true（已安装 mesh-v2-test-suite 集群插件，提供
#       cpaas-system/mesh-v2-test-suite-java-otel-demo ConfigMap 与配套镜像）。
#       未设置时本测试以 SKIPPED 退出，不阻断编排。
#
# 部署 / 卸载步骤源自:
#   servicemesh2-docs/charts/mesh-v2-test-suite/templates/java-otel-demo-configmap.yaml

set -e

: "${FRAMEWORK_ROOT:?该脚本需经 docs-runme-tests/run.sh 运行}"

# 加载框架函数库
source "$FRAMEWORK_ROOT/framework/common.sh"
source "$FRAMEWORK_ROOT/framework/verify.sh"

# ── 常量 ──────────────────────────────────────────────────────────────────────
# 示例命名空间（部署 Instrumentation 与示例工作负载）
JAVA_OTEL_DEMO_NS="otelv2-java-demo"
# mesh-v2-test-suite 集群插件所在命名空间（demo ConfigMap 与 manifest 均在此），
# 取自 chart values.yaml 的 global.namespace；可用 MESH_V2_TEST_SUITE_NAMESPACE 覆盖。
MESH_V2_SUITE_NS="${MESH_V2_TEST_SUITE_NAMESPACE:-cpaas-system}"
# 保存 demo 部署清单与监控面板的 ConfigMap 名（mesh-v2-test-suite.name + -java-otel-demo）
JAVA_OTEL_DEMO_CM="mesh-v2-test-suite-java-otel-demo"

# 是否启用 mesh-v2-test-suite 集群插件（本测试的前提）
_use_test_suite_plugin() {
    [ "${USE_MESH_V2_TEST_SUITE_PLUGIN:-false}" = "true" ]
}

# 从 demo ConfigMap 取出指定 data 键内容并执行 kubectl apply。
# 用法: _demo_apply <data-key-with-escaped-dot> [额外的 kubectl apply 参数...]
# 例:   _demo_apply 'java-instrumentation\.yaml' -n "$JAVA_OTEL_DEMO_NS"
#       _demo_apply 'otel-java-http-monitor-dashboard\.yaml'   # 面板 namespace 已内置
_demo_apply() {
    local key="$1"
    shift
    local yaml
    yaml=$(kubectl get cm "$JAVA_OTEL_DEMO_CM" -n "$MESH_V2_SUITE_NS" \
        -o "jsonpath={.data.${key}}" 2>/dev/null) || true
    if [ -z "$yaml" ]; then
        log_error "无法从 ConfigMap ${MESH_V2_SUITE_NS}/${JAVA_OTEL_DEMO_CM} 读取 data.${key}"
        return 1
    fi
    printf '%s\n' "$yaml" | kubectl apply "$@" -f -
}

# 测试函数：部署 Java OTel 示例服务并验证自动注入
# 对应 java-otel-demo-configmap.yaml 第 17 行之后的部署步骤。
test_java_instrumentation() {
    log_info "=========================================="
    log_info "开始 Java 自动注入示例服务测试"
    log_info "=========================================="

    # 步骤 0: 前提校验（USE_MESH_V2_TEST_SUITE_PLUGIN=true）
    if ! _use_test_suite_plugin; then
        log_warn "SKIPPED: 未设置 USE_MESH_V2_TEST_SUITE_PLUGIN=true，跳过 Java OTel demo 测试"
        return 0
    fi

    # 步骤 0.1: 校验 demo ConfigMap 存在
    log_info "步骤 0.1: 校验集群插件 ConfigMap ${MESH_V2_SUITE_NS}/${JAVA_OTEL_DEMO_CM}"
    if ! kubectl get cm "$JAVA_OTEL_DEMO_CM" -n "$MESH_V2_SUITE_NS" >/dev/null 2>&1; then
        log_error "未找到 ConfigMap ${MESH_V2_SUITE_NS}/${JAVA_OTEL_DEMO_CM}"
        log_error "请确认已在当前集群安装 mesh-v2-test-suite 集群插件 (charts/mesh-v2-test-suite/)"
        return 1
    fi

    # 步骤 1: 创建示例命名空间（已存在则跳过）
    log_info "步骤 1: 创建示例命名空间 $JAVA_OTEL_DEMO_NS"
    kubectl get ns "$JAVA_OTEL_DEMO_NS" >/dev/null 2>&1 \
        || kubectl create ns "$JAVA_OTEL_DEMO_NS" || {
            log_error "创建命名空间 $JAVA_OTEL_DEMO_NS 失败"
            return 1
        }

    # 步骤 2: 部署 Instrumentation（OTel javaagent 注入配置）
    log_info "步骤 2: 部署 Instrumentation"
    _demo_apply 'java-instrumentation\.yaml' -n "$JAVA_OTEL_DEMO_NS" || {
        log_error "部署 Instrumentation 失败"
        return 1
    }

    # 步骤 3: 部署示例工作负载（consumer / provider / asm-client）
    log_info "步骤 3: 部署示例工作负载"
    _demo_apply 'java-otel-test-service\.yaml' -n "$JAVA_OTEL_DEMO_NS" || {
        log_error "部署示例工作负载失败"
        return 1
    }

    # 步骤 4: 创建自定义监控面板（HTTP / JVM MonitorDashboard，namespace 已内置 cpaas-system）
    log_info "步骤 4: 创建自定义监控面板"
    _demo_apply 'otel-java-http-monitor-dashboard\.yaml' || {
        log_error "创建 HTTP MonitorDashboard 失败"
        return 1
    }
    _demo_apply 'otel-java-jvm-monitor-dashboard\.yaml' || {
        log_error "创建 JVM MonitorDashboard 失败"
        return 1
    }

    # 步骤 5: 等待三个示例 Deployment 就绪
    log_info "步骤 5: 等待示例工作负载就绪"
    local dep
    for dep in otel-demo-consumer-for-test otel-demo-provider-for-test asm-client; do
        _wait_for_deployment "$JAVA_OTEL_DEMO_NS" "$dep" || {
            log_error "等待 Deployment $dep 就绪失败"
            return 1
        }
    done

    # 步骤 6: 校验 OTel Java agent 已被自动注入
    # Operator 通过 mutating webhook 注入 opentelemetry-auto-instrumentation init container，
    # 并在应用容器写入 JAVA_TOOL_OPTIONS=-javaagent:...（见 java-instrumentation.mdx）。
    # consumer pod JSON 含动态值（pod 名后缀等），用 __cmp_lines 断言关键子串。
    log_info "步骤 6: 校验 Java agent 自动注入"
    local pod_json
    pod_json=$(kubectl get pods -n "$JAVA_OTEL_DEMO_NS" \
        -l app.kubernetes.io/name=consumer-demo -o json 2>&1)
    if ! __cmp_lines "$pod_json" "$(cat <<'EOF'
+ opentelemetry-auto-instrumentation
+ -javaagent
EOF
)"; then
        log_error "未检测到 OTel Java agent 注入（缺少 init container 或 JAVA_TOOL_OPTIONS -javaagent）"
        log_error "consumer pod JSON: $pod_json"
        return 1
    fi
    log_success "Java agent 自动注入校验通过"

    log_success "=========================================="
    log_success "Java 自动注入示例服务测试完成，所有验证通过！"
    log_success "=========================================="
    return 0
}

# 清理函数：卸载 Java OTel 示例服务（与部署顺序相反）
# 对应 java-otel-demo-configmap.yaml 第 30 行之后的卸载步骤。
cleanup_java_instrumentation() {
    log_info "=========================================="
    log_info "清理 Java 自动注入示例服务测试资源"
    log_info "=========================================="

    # 步骤 0: 前提校验（未启用插件则测试已跳过，无资源可清理）
    if ! _use_test_suite_plugin; then
        log_warn "SKIPPED: 未设置 USE_MESH_V2_TEST_SUITE_PLUGIN=true，跳过 Java OTel demo 清理"
        return 0
    fi

    # 步骤 1: 删除自定义监控面板（按名删除，容忍资源已不存在；CRD 缺失仍判失败）
    log_info "步骤 1: 删除自定义监控面板"
    kubectl delete monitordashboard otel-java-http otel-java-jvm \
        -n "$MESH_V2_SUITE_NS" --ignore-not-found=true || {
        log_error "删除自定义监控面板失败"
        return 1
    }

    # 步骤 2: 删除示例命名空间（连同 Instrumentation 与所有工作负载一并清理）
    log_info "步骤 2: 删除示例命名空间 $JAVA_OTEL_DEMO_NS"
    kubectl delete ns "$JAVA_OTEL_DEMO_NS" --ignore-not-found=true || {
        log_error "删除命名空间 $JAVA_OTEL_DEMO_NS 失败"
        return 1
    }

    log_success "测试资源清理完成"
    return 0
}
