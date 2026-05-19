# Alauda Build of OpenTelemetry → Alauda Build of OpenTelemetry v2 迁移方案

## 1. 背景与目标

### 1.1 背景

`Alauda Build of OpenTelemetry`（以下简称 v1）基于上游 OpenTelemetry Operator/Collector `0.108.0` 构建，由 OLM 部署的 Operator 名为 `opentelemetry-operator`。`Alauda Build of OpenTelemetry v2`（以下简称 v2）基于 `0.147.0` 构建，OLM Operator 名为 `opentelemetry-operator2`。两者管理相同的 CRD（`OpenTelemetryCollector`、`Instrumentation`），由于 OLM 限制——**同一个 CRD 的所属 Operator 在集群中只能存在一个**——v1 与 v2 不能在同一个 Kubernetes 集群中并存，必须以 "卸载 v1 → 安装 v2" 的方式完成迁移。

此外，v2 在 Java 自动注入方面发生了显著变化：v1 由 Alauda 提供定制的 Java OTel Agent 注入镜像，用户不需要在 `Instrumentation.spec.java.image` 字段中显式声明镜像；v2 不再随 Operator 提供 Java Agent 镜像，用户必须自行提供（开源镜像或自建镜像）。

### 1.2 迁移目标

- 在保证用户业务可用的前提下，将集群中的 OpenTelemetry 平台由 v1 替换为 v2。
- 完成 Operator、`OpenTelemetryCollector`、`Instrumentation` 等所有相关资源的版本切换。
- Java 自动注入业务正常切换到自托管的 Java Agent 镜像，链路与指标采集恢复正常。
- 提供完整的回滚预案。

### 1.3 适用范围

- 仅使用独立 Collector 的场景。
- 与 ACP `Observability → Tracing` 集成的场景（参考 `acp-docs/docs/en/observability/tracing/installation.mdx`）。
- 与 Service Mesh 集成的场景（参考 `servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`）。

### 1.4 版本对照

| 项目 | v1（旧） | v2（新） |
| :--- | :--- | :--- |
| OpenTelemetry Operator/Collector 版本 | 0.108.0 | 0.147.0 |
| OLM Package / Subscription 名称 | `opentelemetry-operator` | `opentelemetry-operator2` |
| 推荐 Operator 命名空间 | `opentelemetry-operator` | `opentelemetry-operator2` |
| 默认订阅 channel | `alpha` | `stable` |
| `OpenTelemetryCollector` API 版本 | `opentelemetry.io/v1beta1` | `opentelemetry.io/v1beta1` |
| `Instrumentation` API 版本 | `opentelemetry.io/v1alpha1` | `opentelemetry.io/v1alpha1` |
| Java Agent 注入镜像 | Alauda 内置（无需配置 `spec.java.image`） | 用户自备（必须配置 `spec.java.image`） |
| Collector 与 Operator 是否允许同命名空间 | 允许（v1 文档示例常将 Collector 部署至 `cpaas-system`） | **不允许**，Collector 必须独立命名空间 |
| 与 ASM 的兼容性 | 与 ASM v1 兼容 | 与 ASM v1 不兼容；仅与 ASM v2 兼容 |

## 2. 关键差异与影响分析

### 2.1 OLM 部署冲突（最重要的约束）

`opentelemetry-operator`（v1）与 `opentelemetry-operator2`（v2）虽然 Subscription/CSV 名称不同，但都声明 `opentelemetrycollectors.opentelemetry.io` 与 `instrumentations.opentelemetry.io` 两个 CRD 的 Owner。OLM 检测到 CRD Owner 冲突时会拒绝安装第二个 Operator。

**影响**：v2 必须在 v1 完全卸载（Subscription、CSV 均删除）后才能安装。CRD 本身**不需要也不应该删除**——保留 CRD 对历史资源备份的反序列化、回滚都有价值，且 v2 Operator 在安装时会重新认领并升级 CRD。

### 2.2 Java 自动注入镜像变化

| 维度 | v1 | v2 |
| :--- | :--- | :--- |
| Java Agent 镜像来源 | Alauda 随 Operator 镜像提供 | 不再提供，需用户配置 |
| `Instrumentation.spec.java.image` | 通常留空，由 Operator 注入 Alauda 默认镜像 | **必填**（除非 Operator/Webhook 中显式声明默认值，本项目文档约定用户显式提供） |

迁移示例（参考 `docs/en/configuration/instrumentation/java.mdx`）：

```yaml
spec:
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1
```

如客户环境是离线/内网部署，需提前将 `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:<tag>` 镜像同步到内部镜像仓库（例如 `registry.acme.local/otel/autoinstrumentation-java:2.26.1`），并在 `spec.java.image` 中引用。

**注意**：`Instrumentation` 资源被 Operator 注入到业务 Pod 后，注入的 init container、`JAVA_TOOL_OPTIONS` 环境变量等不会随 `Instrumentation` 资源更新而自动同步到既有 Pod，需要重启业务 Pod（重新创建）才能让新版镜像生效。

### 2.3 Collector 与 Operator 命名空间关系

v2 文档强制约定 Collector 与 Operator **必须不同命名空间**：

> Do not deploy the OpenTelemetry Collector in the same namespace as the Operator. Create a separate namespace for the Collector instance.（来源：`docs/en/installing/install-opentelemetry.mdx`）

而 v1 实际部署中（如 ACP Tracing 场景）经常出现 Operator 在 `opentelemetry-operator` 命名空间、Collector 在 `cpaas-system` 命名空间，本身已经满足"不同命名空间"。但若集群历史上将 Collector 与 v1 Operator 部署在同一命名空间，迁移到 v2 时必须重新规划 Collector 的命名空间。

迁移建议：
- ACP Tracing 场景：Collector 仍部署在 `cpaas-system`，Operator 部署在 `opentelemetry-operator2`，无变更。
- Service Mesh 场景：Collector 仍部署在 `istio-system`，Operator 部署在 `opentelemetry-operator2`，无变更。**前置条件：必须使用 ASM v2，否则不允许并存。**
- 独立 Collector 场景：建议为 Collector 创建独立命名空间，例如 `opentelemetry-collector`。

### 2.4 与 Alauda Service Mesh 的兼容性

v2 文档明确指出：

> Do not install `Alauda Service Mesh` and `Alauda Build of OpenTelemetry v2` in the same Kubernetes cluster, as this will result in functional conflicts.

如集群中存在 ASM v1（`Alauda Service Mesh`），迁移 OpenTelemetry 至 v2 之前必须先迁移 ASM 至 ASM v2，否则会导致功能冲突。

### 2.5 Collector 配置兼容性

v0.108 → v0.147 跨多个上游版本，部分 receiver/processor/exporter 的字段、connector 名称、telemetry 配置可能存在差异：

- v2 仅支持 release notes 中列出的 14 个 receivers / 14 个 processors / 8 个 exporters / 4 个 connectors / 8 个 extensions（参考 `docs/en/about/release-notes/v2-0-0.mdx`），需要逐项核对原 Collector 配置中是否使用了 v2 不支持的组件。
- 配置语法层面，建议在迁移期间将原 Collector 配置在测试环境中先用 v2 校验一遍，以暴露潜在的不兼容字段。
  - 可使用 `spec.config.service.telemetry.metrics` 字段作为例子，两个版本配置不同。

### 2.6 资源名称、SA、RBAC 的影响

v1 部署文档（如 ACP Tracing 安装脚本）会创建：

- `ServiceAccount/otel-collector`（在 `cpaas-system`）
- `ClusterRoleBinding/otel-collector:cpaas-system:cluster-admin`
- `ServiceMonitor/otel-collector`、`ServiceMonitor/otel-collector-monitoring`

迁移到 v2 时：

- v2 会自动创建 SA 与 ClusterRoleBinding SA / RoleBinding / ClusterRoleBinding 与 ServiceMonitor

## 3. 迁移前置准备

### 3.1 清单与盘点

```bash
# 1. 当前 v1 Operator 状态
kubectl get subscription -A | grep opentelemetry
kubectl get csv -A | grep -i opentelemetry

# 2. 列出所有 OpenTelemetryCollector 与 Instrumentation 资源
kubectl get opentelemetrycollector -A
kubectl get instrumentation -A

# 3. 找出所有使用自动注入注解的工作负载（确认影响面）
kubectl get pods -A -o json \
  | jq -r '.items[] | select(.metadata.annotations["instrumentation.opentelemetry.io/inject-java"]) | "\(.metadata.namespace)/\(.metadata.name)"'
```

### 3.2 资源备份

```bash
# 备份所有 OpenTelemetryCollector
mkdir -p ./otel-v1-backup
kubectl get opentelemetrycollector -A -o yaml > ./otel-v1-backup/collectors.yaml

# 备份所有 Instrumentation
kubectl get instrumentation -A -o yaml > ./otel-v1-backup/instrumentations.yaml

# 备份 Operator Subscription / CSV / OperatorGroup
kubectl get subscription -n opentelemetry-operator opentelemetry-operator -o yaml > ./otel-v1-backup/subscription.yaml || true
kubectl get csv -n opentelemetry-operator -o yaml > ./otel-v1-backup/csv.yaml || true

# 备份相关 RBAC（按实际使用的命名空间调整）
kubectl get sa otel-collector -n cpaas-system -o yaml > ./otel-v1-backup/sa.yaml || true
kubectl get clusterrolebinding otel-collector:cpaas-system:cluster-admin -o yaml > ./otel-v1-backup/crb.yaml || true

# 备份 ServiceMonitor
kubectl get servicemonitor -n cpaas-system -l "monitoring=services" -o yaml > ./otel-v1-backup/servicemonitors.yaml || true
```

> 备份的 YAML 仅作为回滚与配置参考，迁移到 v2 时应当根据 v2 规范重新构造，而不是 `kubectl apply -f` 原样恢复。

### 3.3 Java Agent 镜像准备

#### 3.3.1 选型

| 选项 | 适用场景 | 备注 |
| :--- | :--- | :--- |
| 上游开源镜像 `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:<tag>` | 公网可达环境 | 推荐选择与 Operator 版本对应的稳定 tag（例如 `2.26.1`） |
| 自构建/同步至私有仓库 | 离线、内网、对镜像供应链有合规要求 | 需要在 `Instrumentation.spec.java.image` 中替换为内部仓库路径 |

注意：由于 otel java agent 的版本由 1.x 升级到了 2.x，需要用户关注生成的 metrics 的变化。

#### 3.3.2 同步到私有仓库示例

不需要该步骤，默认用户有同步镜像的能力。

### 3.4 兼容性核对

- 对集群中所有 `OpenTelemetryCollector.spec.config` 字段，逐项核对 receivers / processors / exporters / connectors / extensions 是否在 v2 release notes 支持列表内。

### 3.5 停机窗口与数据连续性约定

- 卸载 v1 Collector 至 v2 Collector 重新就绪期间，OTLP/Jaeger/Zipkin 端点不可用，业务 Pod 上报的链路与指标会暂时丢失（业务自身不会失败，因为 OTel SDK 会缓冲并丢弃溢出数据）。
- 与业务方约定一段维护时间窗口，建议安排在低峰期。

## 4. 迁移执行步骤

### 4.1 步骤总览

```
[Step 1] 删除 v1 Instrumentation
    ↓
[Step 2] 删除 v1 OpenTelemetryCollector（链路采集中断点开始）
    ↓
[Step 3] 卸载 v1 Operator（Subscription + CSV）
    ↓
[Step 4] 安装 v2 Operator（参考 docs/en/installing/install-opentelemetry.mdx）
    ↓
[Step 5] 重建 OpenTelemetryCollector
    ↓
[Step 6] 重建 Instrumentation（增加 spec.java.image）
    ↓
[Step 7] 滚动重启业务 Pod，触发新版 Java Agent 注入（链路采集恢复点）
    ↓
[Step 8] 验证 + 清理
```

### 4.2 步骤明细

#### Step 1：删除 v1 `Instrumentation`

```bash
# 列出所有 Instrumentation
kubectl get instrumentation -A

# 删除（按实际命名空间与名称替换）
kubectl -n cpaas-system delete instrumentation acp-common-java
# 其它命名空间同理...
```

> 删除 Instrumentation 不会影响已经被注入的业务 Pod 立即采集，仅影响后续重启时的注入。

#### Step 2：删除 v1 `OpenTelemetryCollector`

```bash
kubectl get opentelemetrycollector -A

kubectl -n cpaas-system delete opentelemetrycollector otel
# 其它命名空间同理...
```

> 此步骤会立即终止 OTel Collector 服务，业务侧 OTLP 上报开始失败。

#### Step 3：卸载 v1 Operator

参考 v1 安装文档（`acp-docs/docs/en/observability/tracing/installation.mdx`）的卸载章节：

```bash
# 删除 Subscription
kubectl delete subscription opentelemetry-operator -n opentelemetry-operator

# 删除 CSV（防止 OLM 自动重建）
CSV=$(kubectl get csv -n opentelemetry-operator -o name | grep -i opentelemetry-operator)
[ -n "$CSV" ] && kubectl -n opentelemetry-operator delete "$CSV"

# 检查 Operator Deployment 是否已经清理
kubectl -n opentelemetry-operator get deployment

# 注意：CRD 不删除！v2 Operator 会接管现有 CRD
# 如确实需要清理，请确认所有 CR 已经删除：
# kubectl get crds -oname | grep opentelemetry.io
```

清理 v1 部署在 `cpaas-system` 的相关 RBAC：

```bash
kubectl -n cpaas-system delete servicemonitor otel-collector-monitoring otel-collector
kubectl -n cpaas-system delete sa otel-collector
kubectl delete clusterrolebinding otel-collector:cpaas-system:cluster-admin
```

**等待 v1 Operator 完全卸载**（重要，否则下一步安装 v2 时 OLM 会因 CRD Owner 冲突拒绝）：

```bash
# 确认无 v1 OpenTelemetry Operator 相关 CSV
kubectl get csv -A | grep opentelemetry-operator
# 期望输出为空
```

#### Step 4：安装 v2 Operator

完整步骤参考 `docs/en/installing/install-opentelemetry.mdx` 的 "Installing the Alauda Build of OpenTelemetry v2 Operator"。关键命令：

```bash
# 创建 Operator 命名空间
kubectl get namespace opentelemetry-operator2 || kubectl create namespace opentelemetry-operator2

# 创建 Subscription
kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  annotations:
    cpaas.io/target-namespaces: ""
  labels:
    catalog: platform
  name: opentelemetry-operator2
  namespace: opentelemetry-operator2
spec:
  channel: stable
  installPlanApproval: Manual
  name: opentelemetry-operator2
  source: platform
  sourceNamespace: cpaas-system
  startingCSV: opentelemetry-operator2.v0.146.0-r0
EOF

# 等待 InstallPlan 待审批
kubectl -n opentelemetry-operator2 wait --for=condition=InstallPlanPending subscription opentelemetry-operator2 --timeout=2m

# 审批 InstallPlan
PLAN="$(kubectl -n opentelemetry-operator2 get subscription opentelemetry-operator2 -o jsonpath='{.status.installPlanRef.name}')"
kubectl -n opentelemetry-operator2 patch installplan "$PLAN" --type=json -p='[{"op": "replace", "path": "/spec/approved", "value": true}]'

# 等待 CSV Succeeded
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded csv --all -n opentelemetry-operator2 --timeout=3m
```

> `startingCSV` 应根据实际可用版本调整：`kubectl get packagemanifest opentelemetry-operator2 -o json | jq -r '.status.channels'` 查询。

#### Step 5：重建 `OpenTelemetryCollector`

##### 5.1 创建 Collector 命名空间

```bash
# 独立 Collector 场景
kubectl get namespace opentelemetry-collector || kubectl create namespace opentelemetry-collector

# ACP Tracing 场景：继续使用 cpaas-system（前提：Operator 不在 cpaas-system，本方案中 Operator 在 opentelemetry-operator2）
# Service Mesh v2 场景：继续使用 istio-system
```

##### 5.2 应用 Collector 资源

以 ACP Tracing 场景为例（基于备份的 v1 配置转换而来），关键改动是确认 receivers/processors/exporters 在 v2 支持列表内。资源 YAML：

让用户调整到 ../distributed-tracing-docs/docs/en/installing/installing-distributed-tracing.mdx 的 "## Deploying the OpenTelemetry Collector" 章节查看。

#### Step 6：重建 `Instrumentation`（重点：增加 `spec.java.image`）

以 ACP Tracing 场景为例：

```yaml
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: acp-common-java
  namespace: cpaas-system
spec:
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1   # 必填，v2 不再提供默认镜像
  exporter:
    endpoint: http://otel-collector.cpaas-system:4317
  env:
    - name: OTEL_TRACES_EXPORTER
      value: otlp
    - name: OTEL_METRICS_EXPORTER
      value: otlp
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: http://otel-collector.cpaas-system:4317
  sampler:
    type: parentbased_traceidratio
    argument: "1"
```

要点：

1. **`spec.java.image` 必填**：选择 3.3 节准备好的镜像。
2. 字段保留与 v1 完全一致，确保业务侧 Pod 注解、`SERVICE_NAME`、`SERVICE_NAMESPACE` 环境变量无需修改。
3. 多个命名空间各自有独立 `Instrumentation` 时，对每个资源都执行同样的迁移。

#### Step 7：滚动重启业务 Pod

由于 v1 Operator 已经卸载，已经被注入旧版 Agent 的业务 Pod 实际上已经无法正常上报（Collector 已经替换）。需要触发滚动重启，让 Mutating Webhook 重新注入新 Agent 镜像与环境变量。

```bash
# 找出受影响的 Deployment（以 inject-java 注解作为线索）
kubectl get deploy -A -o json | jq -r '
  .items[]
  | select(.spec.template.metadata.annotations["instrumentation.opentelemetry.io/inject-java"])
  | "\(.metadata.namespace) \(.metadata.name)"'

# 滚动重启（按命名空间/Deployment 替换）
kubectl -n <namespace> rollout restart deployment/<name>
kubectl -n <namespace> rollout status deployment/<name>
```

> 如果业务 Pod 数量众多且需要节奏控制，建议分批滚动重启，并按业务关键性排序。

#### Step 8：验证

```bash
# 1. v2 Operator 健康
kubectl -n opentelemetry-operator2 get csv,deploy

# 2. Collector 健康
kubectl get opentelemetrycollector -A
kubectl -n <collector-ns> get pod -l app.kubernetes.io/managed-by=opentelemetry-operator

# 3. Instrumentation 资源生效
kubectl get instrumentation -A

# 4. 业务 Pod 中是否包含新版 Agent init container
kubectl -n <ns> get pod <pod> -o jsonpath='{.spec.initContainers[*].image}'
# 期望输出：包含 spec.java.image 中配置的镜像

# 5. 业务 Pod 内 JAVA_TOOL_OPTIONS 环境变量
kubectl -n <ns> exec <pod> -- env | grep -E '^(JAVA_TOOL_OPTIONS|OTEL_)'

# 6. 链路数据：访问 Jaeger UI / 平台 Tracing 页面，发起测试请求并验证最新链路出现
```

## 5. 不同部署场景的特殊处理

### 5.1 独立 Collector 场景

直接按 `docs/en/installing/install-opentelemetry.mdx` 的最小示例部署，命名空间建议 `opentelemetry-collector`，与 Operator 命名空间隔离。

### 5.2 ACP `Observability → Tracing` 集成场景

- Operator 命名空间从 `opentelemetry-operator` 迁至 `opentelemetry-operator2`。
- Collector 仍部署在 `cpaas-system`，资源名称、SA、ClusterRoleBinding、ServiceMonitor 全部保留，避免依赖该 endpoint 的下游服务（Jaeger、Prometheus、平台 UI）感知到端点变更。
- `Instrumentation.metadata.name = acp-common-java` 需要保留，业务侧的 `instrumentation.opentelemetry.io/inject-java: cpaas-system/acp-common-java` 注解保持不变。
- **唯一显著差异**：`Instrumentation.spec.java.image` 必须显式声明。

### 5.3 与 Service Mesh v2 集成场景

前置条件：集群已经使用 `Alauda Service Mesh v2`（不能与 ASM v1 共存）。

- Collector 仍部署在 `istio-system`，与 v1 时机制一致。
- `Istio` 资源中 `meshConfig.extensionProviders[].opentelemetry.service` 配置的服务名 `otel-collector.istio-system.svc.cluster.local` 不变。
- `Telemetry` 资源无需调整。
- ASM v1 → ASM v2 的迁移在本文档之外，需要先完成。

## 6. 验证清单（Acceptance Criteria）

- [ ] `kubectl get csv -A | grep opentelemetry` 仅显示 v2 Operator，状态为 `Succeeded`。
- [ ] 集群中不存在名为 `opentelemetry-operator` 的 Subscription / CSV / Deployment。
- [ ] `kubectl get opentelemetrycollector -A` 列出预期的实例，`READY` 列为 `<n>/<n>`，`VERSION` 为 0.146.x（或对应 r 版）。
- [ ] `kubectl get instrumentation -A` 列出预期资源，`spec.java.image` 已配置。
- [ ] 业务 Pod 重启后，`spec.initContainers` 中存在 `opentelemetry-auto-instrumentation-java`（或同义）init container，且镜像与 `Instrumentation.spec.java.image` 一致。
- [ ] 业务发出请求后，下游存储（Jaeger / Elasticsearch）能查询到最新 trace。
- [ ] Prometheus 数据源中可查询到 `otelcol_*` 指标，并且 ServiceMonitor 抓取无错误。

## 7. 回滚方案

迁移过程中或迁移完成后短期内若发现问题，可回滚至 v1：

1. 删除 v2 资源：
   ```bash
   kubectl delete instrumentation -A --all
   kubectl delete opentelemetrycollector -A --all
   kubectl delete subscription opentelemetry-operator2 -n opentelemetry-operator2
   kubectl delete csv -n opentelemetry-operator2 -l operators.coreos.com/opentelemetry-operator2.opentelemetry-operator2 --all || \
     kubectl delete csv -n opentelemetry-operator2 --all
   ```
2. 等待 v2 Operator Deployment 与所有 CSV 清理完成（确认无 OpenTelemetry Operator）。
3. 按 `acp-docs/docs/en/observability/tracing/installation.mdx` 重新安装 v1 Operator。
4. 使用 3.2 节备份的 YAML 重建 `OpenTelemetryCollector`、`Instrumentation`、SA、ClusterRoleBinding、ServiceMonitor。
5. 滚动重启业务 Pod 重新触发 v1 Java Agent 注入。

> 回滚的关键点同样是 OLM CRD 互斥：必须先彻底卸载 v2，才能安装 v1。

## 8. 风险与对策

| 风险 | 触发条件 | 对策 |
| :--- | :--- | :--- |
| OLM 拒绝安装 v2，提示 CRD owner 冲突 | v1 CSV 未完全清理 | 等待 CSV 删除完成；若仍残留，删除 `kubectl get csv -A | grep opentelemetry-operator` 中所有 v1 CSV |
| v2 Collector 启动失败，Pod 处于 `CrashLoopBackOff` | 配置中包含 v2 不支持的 receiver/processor 等 | 检查 Collector pod 日志；参考 `docs/en/about/release-notes/v2-0-0.mdx` 中的支持列表，删除/替换不支持组件 |
| 业务 Pod 重启后无 init container | Mutating Webhook 未就绪、Instrumentation 不存在或注解引用错误 | 检查 webhook 配置 `kubectl get mutatingwebhookconfigurations`；核对 `instrumentation.opentelemetry.io/inject-java` 注解值；确认目标 Instrumentation 存在 |
| 业务 Pod 启动后无 trace | `OTEL_EXPORTER_OTLP_ENDPOINT` 错误、Collector 未就绪、防火墙阻断 4317/4318 | 在业务 Pod 内 `nc -vz <collector-svc> 4317`；检查 NetworkPolicy；查看 Collector Pod 日志 |

## 9. 时间评估（参考）

| 阶段 | 估算时长 |
| :--- | :--- |
| 准备（盘点、备份、镜像准备） | 0.5 ~ 1 工作日 |
| 测试环境演练 | 0.5 ~ 1 工作日 |
| 生产执行（含业务滚动重启） | 1 ~ 2 小时（按业务规模可延长） |
| 监控与回滚预留 | 完成后 24 小时观察期 |

## 10. 附录

### 10.1 关键参考文档

- v2 安装：`docs/en/installing/install-opentelemetry.mdx`
- v2 卸载：`docs/en/uninstalling/uninstalling-opentelemetry.mdx`
- v2 Java 注入配置：`docs/en/configuration/instrumentation/java.mdx`
- v2 Instrumentation 通用配置：`docs/en/configuration/instrumentation/instrumentation-options.mdx`
- v2 Release Notes（支持组件清单）：`docs/en/about/release-notes/v2-0-0.mdx`
- v1 安装/卸载与 ACP Tracing 集成：`acp-docs/docs/en/observability/tracing/installation.mdx`
- v1 Java 自动注入业务侧适配：`acp-docs/docs/en/observability/tracing/how_to/java_auto_tracing.mdx`
- Service Mesh 集成：`servicemesh2-docs/docs/en/integration/observability/distributed-tracing-and-mesh.mdx`

### 10.2 字段差异速查

| 字段 | v1 取值 | v2 取值 |
| :--- | :--- | :--- |
| `Instrumentation.spec.java.image` | 通常省略 | **必填**，例如 `ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:2.26.1` |
| `Subscription.metadata.name` | `opentelemetry-operator` | `opentelemetry-operator2` |
| `Subscription.spec.name` | `opentelemetry-operator` | `opentelemetry-operator2` |
| `Subscription.spec.channel` | `alpha` | `stable` |
| Operator namespace | `opentelemetry-operator` | `opentelemetry-operator2` |

### 10.3 Mermaid 流程图

```mermaid
flowchart TD
    A[盘点 / 备份 / 镜像准备] --> B[删除 v1 Instrumentation]
    B --> C[删除 v1 OpenTelemetryCollector]
    C --> D[卸载 v1 Operator (Subscription + CSV)]
    D --> E{CRD 上游 Owner 已经清空?}
    E -- 否 --> D
    E -- 是 --> F[安装 v2 Operator (opentelemetry-operator2)]
    F --> G[创建 Collector 命名空间 / RBAC]
    G --> H[应用 v2 OpenTelemetryCollector]
    H --> I[应用 v2 Instrumentation (spec.java.image)]
    I --> J[滚动重启业务 Pod]
    J --> K[验证]
    K -- 通过 --> L[完成]
    K -- 不通过 --> M[执行回滚]
```
