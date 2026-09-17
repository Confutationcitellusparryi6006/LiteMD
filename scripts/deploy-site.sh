#!/usr/bin/env bash
#
# 把 site/ 同步到服务器。
#
#   ./scripts/deploy-site.sh <user@host> <服务器目录> [ssh 私钥]
#
# 例：
#   ./scripts/deploy-site.sh root@203.0.113.10 /var/www/litemd ~/.ssh/gentpan.pem
#
# 默认先跑一次 dry-run 列出将要改动的文件；确认后加 --go 真正同步。
set -euo pipefail

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

GO=0
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --go) GO=1 ;;
    -h|--help) usage ;;
    *) ARGS+=("$arg") ;;
  esac
done

[[ ${#ARGS[@]} -ge 2 ]] || usage

TARGET="${ARGS[0]}"
REMOTE_DIR="${ARGS[1]}"
KEY="${ARGS[2]:-}"
PORT="${SSH_PORT:-22}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT/site/"

[[ -d "$LOCAL_DIR" ]] || { echo "找不到站点目录：$LOCAL_DIR" >&2; exit 1; }

SSH_CMD=(ssh -p "$PORT" -o StrictHostKeyChecking=accept-new)
[[ -n "$KEY" ]] && SSH_CMD+=(-i "$KEY")

RSYNC_OPTS=(
  --archive          # 保留权限与时间戳
  --compress
  --human-readable
  --delete           # 删掉服务器上已经不在 site/ 里的文件
  --exclude ".DS_Store"
  --itemize-changes
)

if [[ $GO -eq 0 ]]; then
  RSYNC_OPTS+=(--dry-run)
  echo "== 演练（不会改动服务器）：确认无误后加 --go 重跑 =="
fi

set -x
rsync "${RSYNC_OPTS[@]}" -e "${SSH_CMD[*]}" "$LOCAL_DIR" "$TARGET:$REMOTE_DIR/"
set +x

if [[ $GO -eq 1 ]]; then
  echo "同步完成：$TARGET:$REMOTE_DIR"
fi
