# 配置 TLS 安全策略（最低版本与密码套件）

> 状态：草稿（暂放 `.helper/`，未进正式文档目录）。
> 适用版本：Alauda Build of OpenTelemetry v2（Operator ≥ 0.147.0-r0）。
> 能力对标：Red Hat build of OpenTelemetry 3.10 "Cluster TLS profile adherence"（TRACING-5846）。
> 背景分析见 `my-foam/area/observe/otel-v2/cluster-tls-profile-adherence-ACP支持分析.md`。

## 概述

出于安全合规要求（例如禁用 TLS 1.2 以下协议、限制弱密码套件），管理员可以通过环境变量为 Alauda Build of OpenTelemetry v2 配置统一的 TLS 安全策略。策略生效范围分为两层：

1. **Operator 自身的 TLS 服务端**：Webhook 服务（端口 9443，Service `opentelemetry-operator-webhook-service:443`）与 Metrics 服务（端口 8443）；
2. **操作数（Operand）配置**（可选）：Operator 在生成 OpenTelemetry Collector / Jaeger v2 实例配置时，为其中**已启用 TLS 的服务端组件**（如 `otlp` receiver 的 `tls` 块、`health_check` 等 extension）注入 `min_version` 与 `cipher_suites` 默认值。

对操作数的注入遵循以下边界，不会产生破坏性影响：

- **只补默认值，不覆盖显式配置**：用户在 `OpenTelemetryCollector` CR 中已明确写了 `min_version` 或 `cipher_suites` 的组件，Operator 不会改动；
- **不强加 TLS**：未配置 `tls` 块（明文监听）的 receiver 不会被强制开启 TLS；
- **仅约束服务端**：不影响 exporter 等客户端出站连接。

## 环境变量说明

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `TLS_MIN_VERSION` | `VersionTLS12` | 最低 TLS 版本，取值为 Go `crypto/tls` 常量名：`VersionTLS12`、`VersionTLS13` 等 |
| `TLS_CIPHER_SUITES` | Go 默认套件 | 允许的密码套件列表，逗号分隔，取值为 Go/IANA 名称（如 `TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256`）。注意：**TLS 1.3 的密码套件不可配置**（Go 语言限制），`TLS_MIN_VERSION=VersionTLS13` 时本项不生效 |
| `TLS_CONFIGURE_OPERANDS` | `false` | 设为 `"true"` 时，上述策略同时注入操作数配置（见上文边界说明） |
| `TLS_CLUSTER_PROFILE` | `false` | **在 Alauda Container Platform 上禁止启用**，详见下方警告 |

> ⚠️ **警告：`TLS_CLUSTER_PROFILE` 仅适用于 OpenShift**
>
> 该开关让 Operator 从 OpenShift 专有的 `APIServer` CR（`config.openshift.io/v1`）读取集群 TLS profile。ACP 集群没有该 CRD，启用后 Operator 启动即失败并进入 `CrashLoopBackOff`，日志特征：
>
> ```
> ERROR  unable to get TLS profile from cluster
> error: failed to get APIServer "/cluster": ... no matches for config.openshift.io/v1, Resource=
> ```
>
> 从 OpenShift 迁移时，请勿照搬 Red Hat 版 Operator 的 CSV/Subscription 环境变量（Red Hat 的 OpenShift bundle 默认注入 `TLS_CLUSTER_PROFILE=true`）。在 ACP 上应使用 `TLS_MIN_VERSION` + `TLS_CIPHER_SUITES` 静态配置达成等价效果。

## 前提条件

- 已通过 OperatorHub 安装 Alauda Build of OpenTelemetry v2（Operator 位于 `opentelemetry-operator2` 命名空间，OLM 部署）；
- 具备目标集群的 `cluster-admin` 权限（`kubectl` 已指向业务集群）。

## 操作步骤

### 第 1 步：通过 Subscription 注入环境变量

OLM 部署的 Operator 不能直接修改 Deployment（会被 OLM 按 CSV 回滚）。标准做法是配置 Subscription 的 `spec.config.env`，OLM 会将其传播到 CSV 与 Deployment 并触发 Operator 滚动重启：

```bash
kubectl -n opentelemetry-operator2 patch subscription opentelemetry-operator2 \
  --type merge -p '{"spec":{"config":{"env":[
    {"name":"TLS_MIN_VERSION","value":"VersionTLS13"},
    {"name":"TLS_CONFIGURE_OPERANDS","value":"true"}
  ]}}}'
```

等价的 YAML 形式（Subscription 关键片段）：

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-operator2
  namespace: opentelemetry-operator2
spec:
  config:
    env:
    - name: TLS_MIN_VERSION          # 最低 TLS 版本
      value: VersionTLS13
    # - name: TLS_CIPHER_SUITES      # 可选；TLS 1.3 下不生效
    #   value: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
    - name: TLS_CONFIGURE_OPERANDS   # 可选；同时约束 Collector/Jaeger 实例
      value: "true"
```

### 第 2 步：等待 Operator 滚动完成

```bash
kubectl -n opentelemetry-operator2 rollout status \
  deploy/opentelemetry-operator-controller-manager --timeout=120s

# 确认环境变量已生效
kubectl -n opentelemetry-operator2 get deploy opentelemetry-operator-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].env}' | tr ',' '\n' | grep -A1 TLS
```

### 第 3 步（可选）：为操作数中启用 TLS 的组件确认注入效果

`TLS_CONFIGURE_OPERANDS=true` 只对**配置了 `tls` 块**的服务端组件生效。例如以下 receiver 配置：

```yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
spec:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
            tls:                       # 已启用 TLS 的服务端，会被注入策略默认值
              cert_file: /certs/tls.crt
              key_file: /certs/tls.key
```

Operator 生成的 ConfigMap 中该 receiver 会被补充（值格式自动转换为 Collector 约定的 `"1.3"` 形式）：

```yaml
tls:
  cert_file: /certs/tls.crt
  key_file: /certs/tls.key
  min_version: "1.3"
```

而未配置 `tls` 块的明文 receiver 保持原样（不会被强制开启 TLS）。

## 验证

以 `TLS_MIN_VERSION=VersionTLS13` 为例，从集群内节点探测 Operator webhook 的协议协商行为：

```bash
WEBHOOK_IP=$(kubectl -n opentelemetry-operator2 get svc opentelemetry-operator-webhook-service \
  -o jsonpath='{.spec.clusterIP}')

# TLS 1.2 握手应被拒绝（alert protocol version）
echo | openssl s_client -connect ${WEBHOOK_IP}:443 -tls1_2 2>&1 | grep -E 'Protocol|alert'
# 预期输出包含：SSL alert number 70（tlsv1 alert protocol version）

# TLS 1.3 握手应成功
echo | openssl s_client -connect ${WEBHOOK_IP}:443 -tls1_3 2>&1 | grep -E 'Protocol|Cipher is'
# 预期输出：Protocol : TLSv1.3
```

> 以上行为已在 ACP v4.3.1 + Operator 0.147.0-r0 真实环境验证（2026-07-08）。

## 恢复默认配置

移除 Subscription 中的 `spec.config` 即可回到默认策略（最低 TLS 1.2、Go 默认密码套件）：

```bash
kubectl -n opentelemetry-operator2 patch subscription opentelemetry-operator2 \
  --type json -p '[{"op":"remove","path":"/spec/config"}]'
```

> 注意：OLM 将 CSV 的干净状态同步回 Deployment 可能有数分钟延迟。若需立即生效，可在 CSV 恢复干净后删除 Operator Deployment，由 OLM 按 CSV 立即重建：
>
> ```bash
> # 先确认 CSV 中已无 TLS_ 环境变量，再执行
> kubectl -n opentelemetry-operator2 delete deploy opentelemetry-operator-controller-manager
> ```

## 已知限制与注意事项

1. **`TLS_CLUSTER_PROFILE` 不可用**：见上文警告。若未来 ACP 提供平台级 TLS 策略配置，将另行评估自动读取能力。
2. **TLS 1.3 密码套件不可配置**：Go 标准库限制，`min_version` 为 1.3 时 `cipher_suites` 被忽略，属预期行为。
3. **配置变更会重启 Operator**：Subscription `spec.config` 变化触发 Operator Pod 滚动，期间 webhook 短暂不可用（新建/变更 CR 的请求可能失败重试），已运行的 Collector 实例不受影响。
4. **TargetAllocator 场景暂缓启用操作数注入**：当前版本（0.147.0 基线）缺少上游 #4950 修复——`TLS_CONFIGURE_OPERANDS=true` 叠加 TargetAllocator（Prometheus 指标采集场景）时可能触发 Deployment 无限 reconcile。链路追踪场景（无 TargetAllocator）不受影响；该修复已随上游 0.149.0 发布，待 Operator 基线升级（≥0.152.0，对齐 Red Hat 3.10）后此限制解除。
5. **客户端连接不受约束**：本策略只约束 Operator 与操作数的 TLS **服务端**。exporter 出站连接的 TLS 版本请在各 exporter 的 `tls` 配置中单独指定。

## 参考

- Red Hat build of OpenTelemetry 3.10 Release Notes — Cluster TLS profile adherence（TRACING-5846）
- Red Hat 官方使用文档（本篇的对标源）：[Managing the Operator — Cluster TLS profile / Configuring the Operator](https://docs.redhat.com/en/documentation/red_hat_build_of_opentelemetry/3.10/html-single/managing_the_operator/index)。注意其中 `TLS_CLUSTER_PROFILE`/`TLS_CONFIGURE_OPERANDS` "默认启用"仅指 OpenShift bundle；"禁用时可通过 `TLS_MIN_VERSION`/`TLS_CIPHER_SUITES` 手动配置"即本篇在 ACP 上采用的路径
- 上游实现：open-telemetry/opentelemetry-operator PR #4669（0.146.0 引入）、#4680、#4871、#4939、#4950（后续修复）
- OpenShift TLS security profiles（`APIServer` CR `tlsSecurityProfile`，Old/Intermediate/Modern/Custom）
