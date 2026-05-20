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

当 Alauda Build of OpenTelemetry 发布新版本时，使用 `hack/update-otel-version.sh` 批量更新 `./docs/en/` 下所有 `.mdx` 文档中出现的旧版本号。

### 用法

```bash
./hack/update-otel-version.sh <旧版本> <新版本>
```

版本号格式为 `X.Y.Z-rN`，例如 `0.146.0-r0`。

### 操作步骤

1. 确认新版本号（例如 `0.147.0-r0`）。
2. 在仓库根目录执行脚本：

   ```bash
   ./hack/update-otel-version.sh 0.146.0-r0 0.147.0-r0
   ```

   脚本会自动查找 `./docs/en/` 下所有包含旧版本号的 `.mdx` 文件，并将其中的旧版本号全部替换为新版本号；运行结束后会输出被修改的文件列表。

3. 使用 `git diff` 检查改动是否符合预期：

   ```bash
   git diff docs/en/
   ```

4. 本地运行 `yarn dev` 预览相关页面，确认渲染无异常。
5. 确认无误后提交改动并发起 PR。

> 提示：若想新增其它需要随版本一起更新的文件类型或目录，可直接编辑 `hack/update-otel-version.sh` 中的 `grep -r --include='*.mdx'` 与 `DOCS_DIR` 配置。
