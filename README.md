# opentelemetry-docs

Documentation for Alauda Build of OpenTelemetry v2

## Documentation Dependencies

- Ensure that [Node.js](https://nodejs.org/en/) and [npm](https://www.npmjs.com/) are installed locally
- Use `yarn` to install dependencies

```bash
$ yarn install
```

- It's recommended to use [Visual Studio Code](https://code.visualstudio.com/) editor and install the [MDX](https://marketplace.visualstudio.com/items?itemName=unifiedjs.vscode-mdx) extension for document writing

## Documentation Quick Start

- `yarn dev`: Start the local development server, file modifications will update in real-time. (**Note:** Left navigation bar related modifications require restarting the service)
- `yarn build`: Build production environment code, static files will be generated in the `dist` directory after build completion
- `yarn serve`: Preview the built static files locally

## OTel 版本更新

当 Alauda Build of OpenTelemetry 发布新版本时，使用 `hack/update-otel-version.sh` 批量更新 `./docs/en/` 下所有 `.mdx` 文档中出现的旧版本号。脚本同时适用于 Operator 版本与 Collector 版本。

### 用法

```bash
./hack/update-otel-version.sh [选项] <旧版本> <新版本>
```

选项：

| 选项 | 说明 |
| --- | --- |
| `-n`, `--dry-run` | 只列出将要发生的替换（含文件名与行号），不写入文件 |
| `-h`, `--help` | 显示帮助 |

版本号格式为 `X.Y.Z`，可带后缀，例如 `0.158.0`、`0.147.0-r0`、`0.156.0-rc.2`。

脚本按完整版本号做边界匹配，因此 Operator 版本与 Collector 版本可以独立更新，互不干扰：用 `0.158.0` 替换时不会命中 `0.158.0-r1`，用 `0.156.0` 替换时也不会命中 `0.156.0-rc.2`。

### 操作步骤

1. 确认新的 Operator 版本（例如 `0.156.0-rc.2`）与 Collector 版本（例如 `0.158.0`）。
2. 在仓库根目录先预览要改哪些地方：

   ```bash
   ./hack/update-otel-version.sh --dry-run 0.147.0-r0 0.156.0-rc.2
   ```

3. 确认无误后分别执行 Operator 与 Collector 版本的替换：

   ```bash
   # Operator 版本
   ./hack/update-otel-version.sh 0.147.0-r0 0.156.0-rc.2
   # Collector 版本
   ./hack/update-otel-version.sh 0.147.0 0.158.0
   ```

   脚本会自动查找 `./docs/en/` 下所有包含旧版本号的 `.mdx` 文件，并将其中的旧版本号全部替换为新版本号；运行结束后会输出被修改的文件列表。

4. 使用 `git diff` 检查改动是否符合预期：

   ```bash
   git diff docs/en/
   ```

5. 本地运行 `yarn dev` 预览相关页面，确认渲染无异常。
6. 确认无误后提交改动并发起 PR。

> 提示：若想新增其它需要随版本一起更新的文件类型或目录，可直接编辑 `hack/update-otel-version.sh` 中的 `grep -r --include='*.mdx'` 与 `DOCS_DIR` 配置。

## Java 自动插桩镜像版本更新

使用 `hack/update-java-autoinstrumentation-version.sh` 批量更新 `./docs/en/` 下所有 `.mdx` 文档中的 `autoinstrumentation-java` 镜像版本。脚本支持官方 GHCR 镜像以及自建或镜像仓库地址。

### 用法

```bash
./hack/update-java-autoinstrumentation-version.sh <旧版本> <新版本>
```

例如，将镜像版本从 `2.26.1` 更新为 `2.29.0`：

```bash
./hack/update-java-autoinstrumentation-version.sh 2.26.1 2.29.0
```
