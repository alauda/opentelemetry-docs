#!/usr/bin/env bash
#
# 更新 ./docs/en/ 下所有 .mdx 文档中的 OpenTelemetry Java 自动插桩镜像版本。
#
# 兼容 macOS（BSD sed/grep、bash 3.2）和 Linux（GNU sed/grep）。
#
# 用法：
#   ./hack/update-java-autoinstrumentation-version.sh <旧版本> <新版本>
#
# 示例：
#   ./hack/update-java-autoinstrumentation-version.sh 2.26.1 2.29.0

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "用法：$0 <旧版本> <新版本>" >&2
  echo "示例：$0 2.26.1 2.29.0" >&2
  exit 1
fi

OLD_VERSION="$1"
NEW_VERSION="$2"

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+$'
if ! [[ "$OLD_VERSION" =~ $VERSION_RE ]]; then
  echo "错误：旧版本 '$OLD_VERSION' 不符合 X.Y.Z 格式" >&2
  exit 1
fi
if ! [[ "$NEW_VERSION" =~ $VERSION_RE ]]; then
  echo "错误：新版本 '$NEW_VERSION' 不符合 X.Y.Z 格式" >&2
  exit 1
fi

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  echo "新旧版本相同，无需更新。"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$REPO_ROOT/docs/en"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "错误：文档目录不存在：$DOCS_DIR" >&2
  exit 1
fi

IMAGE_NAME='autoinstrumentation-java'
OLD_IMAGE_TAG="${IMAGE_NAME}:${OLD_VERSION}"
NEW_IMAGE_TAG="${IMAGE_NAME}:${NEW_VERSION}"

# 版本号仅包含数字和点，因此只需转义点号即可用于正则表达式。
OLD_VERSION_RE="${OLD_VERSION//./\\.}"
TARGET_RE="${IMAGE_NAME}:${OLD_VERSION_RE}([^[:alnum:]_.-]|$)"

# 收集包含目标镜像的文件（兼容 bash 3.2，不使用 mapfile）。
FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FILES+=("$line")
done < <(grep -rlE --include='*.mdx' "$TARGET_RE" "$DOCS_DIR" || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "docs/en/ 下没有 .mdx 文件包含 '$OLD_IMAGE_TAG'，无需更新。"
  exit 0
fi

echo "正在更新 ${#FILES[@]} 个文件：$OLD_IMAGE_TAG -> $NEW_IMAGE_TAG"
for file in "${FILES[@]}"; do
  # sed -i.bak 是 BSD sed 和 GNU sed 都支持的原地编辑形式。
  sed -i.bak \
    -e "s|${IMAGE_NAME}:${OLD_VERSION_RE}\\([^[:alnum:]_.-]\\)|${NEW_IMAGE_TAG}\\1|g" \
    -e "s|${IMAGE_NAME}:${OLD_VERSION_RE}$|${NEW_IMAGE_TAG}|g" \
    "$file"
  rm -f "${file}.bak"
  echo "  已更新：${file#${REPO_ROOT}/}"
done

echo "更新完成。"
