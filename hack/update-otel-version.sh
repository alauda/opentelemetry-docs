#!/usr/bin/env bash
#
# 批量更新 ./docs/en/ 下所有 .mdx 文档中出现的版本号。
#
# 同时适用于 Operator 版本（形如 0.156.0-rc.2、0.147.0-r0）与
# Collector 版本（形如 0.158.0）。
#
# 兼容 macOS（BSD sed/grep、bash 3.2）和 Linux（GNU sed/grep）。
#
# 用法：
#   ./hack/update-otel-version.sh [选项] <旧版本> <新版本>
#
# 选项：
#   -n, --dry-run   只列出将要发生的替换，不写入文件
#   -h, --help      显示帮助
#
# 示例：
#   # 更新 Operator 版本
#   ./hack/update-otel-version.sh 0.147.0-r0 0.156.0-rc.2
#   # 更新 Collector 版本
#   ./hack/update-otel-version.sh 0.147.0 0.158.0
#   # 先预览再执行
#   ./hack/update-otel-version.sh --dry-run 0.147.0 0.158.0

set -euo pipefail

usage() {
  cat >&2 <<'EOF'
用法：update-otel-version.sh [选项] <旧版本> <新版本>

选项：
  -n, --dry-run   只列出将要发生的替换，不写入文件
  -h, --help      显示本帮助

版本号格式：X.Y.Z，可带后缀，例如 0.158.0、0.147.0-r0、0.156.0-rc.2。

示例：
  # 更新 Operator 版本
  update-otel-version.sh 0.147.0-r0 0.156.0-rc.2
  # 更新 Collector 版本
  update-otel-version.sh 0.147.0 0.158.0
EOF
}

DRY_RUN=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    --)           shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*)           echo "错误：未知选项 '$1'" >&2; usage; exit 1 ;;
    *)            POSITIONAL+=("$1"); shift ;;
  esac
done

if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
  usage
  exit 1
fi

OLD_VERSION="${POSITIONAL[0]}"
NEW_VERSION="${POSITIONAL[1]}"

# 允许裸 X.Y.Z（Collector 版本）以及带后缀的形式（如 -r0、-rc.2）。
VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+([.+-][0-9A-Za-z.+-]+)?$'
if ! [[ "$OLD_VERSION" =~ $VERSION_RE ]]; then
  echo "错误：旧版本 '$OLD_VERSION' 不符合 X.Y.Z[-后缀] 格式" >&2
  exit 1
fi
if ! [[ "$NEW_VERSION" =~ $VERSION_RE ]]; then
  echo "错误：新版本 '$NEW_VERSION' 不符合 X.Y.Z[-后缀] 格式" >&2
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

# 版本号只含数字、字母、点、加号和连字符，作为 ERE 时只需转义点号和加号。
OLD_RE="$(printf '%s' "$OLD_VERSION" | sed -e 's/[.+]/\\&/g')"
# 替换侧需要转义 & 与反斜杠。
NEW_ESCAPED="$(printf '%s' "$NEW_VERSION" | sed -e 's/[&\\]/\\&/g')"

# 边界约束，避免把短版本号误当成长版本号的前缀：
#   - 左侧不能紧跟数字或点，否则 10.147.0 会被误匹配；字母不排除，
#     因为 CSV 名称形如 opentelemetry-operator2.v0.156.0-rc.2。
#   - 右侧不能紧跟版本号可能包含的字符，否则用 0.147.0 会命中 0.147.0-r0。
LEFT='(^|[^0-9.])'
RIGHT='([^0-9A-Za-z_.+-])'
MATCH_RE="${LEFT}${OLD_RE}(${RIGHT}|$)"

# 收集包含目标版本号的文件（兼容 bash 3.2，不使用 mapfile）。
FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FILES+=("$line")
done < <(grep -rlE --include='*.mdx' "$MATCH_RE" "$DOCS_DIR" || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "docs/en/ 下没有 .mdx 文件包含版本号 '$OLD_VERSION'，无需更新。"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] 以下 ${#FILES[@]} 个文件包含 $OLD_VERSION，将被替换为 $NEW_VERSION："
  for file in "${FILES[@]}"; do
    echo "  ${file#${REPO_ROOT}/}"
    grep -nE "$MATCH_RE" "$file" | sed -e 's/^/    /'
  done
  echo "[dry-run] 未写入任何文件。"
  exit 0
fi

echo "正在更新 ${#FILES[@]} 个文件：$OLD_VERSION -> $NEW_VERSION"
for file in "${FILES[@]}"; do
  # 单次 sed 会消费掉匹配右侧的分隔字符，导致同一行内相邻的版本号被跳过，
  # 因此反复替换直到文件内容不再变化。
  round=0
  while [[ $round -lt 10 ]]; do
    cp "$file" "${file}.prev"
    # sed -i.bak 是 BSD sed 和 GNU sed 都支持的原地编辑形式；-E 启用 ERE。
    sed -E -i.bak \
      -e "s/${LEFT}${OLD_RE}${RIGHT}/\\1${NEW_ESCAPED}\\2/g" \
      -e "s/${LEFT}${OLD_RE}\$/\\1${NEW_ESCAPED}/g" \
      "$file"
    rm -f "${file}.bak"
    if cmp -s "$file" "${file}.prev"; then
      rm -f "${file}.prev"
      break
    fi
    rm -f "${file}.prev"
    round=$((round + 1))
  done
  echo "  已更新：${file#${REPO_ROOT}/}"
done

echo "更新完成。请执行 git diff docs/en/ 检查改动。"
