#!/usr/bin/env bash
# 启动 petgen worker（前台运行，Ctrl+C 停止）。在本目录下执行：
#   bash run.sh            一直领单
#   bash run.sh --once     只做一单就退出（调试用）
# 放在哪个目录都行，路径都按本脚本所在目录算。
set -e
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="${AIPET_SERVER:-https://aipei.pixpickai.com}"
PY="${PYTHON:-python3}"

# 密钥
for f in kling.env worker.env; do
  if [ ! -f "$ROOT/secrets/$f" ]; then
    echo "缺少 $ROOT/secrets/$f"
    echo "  cp $ROOT/secrets/$f.example $ROOT/secrets/$f  然后编辑填值"
    exit 1
  fi
done

# 抠图模型：程序只会去 GitHub 下载，国内机器下不了，所以必须提前放好
MODEL="$ROOT/u2net/models/birefnet-general-lite/birefnet-general-lite.onnx"
if [ ! -s "$MODEL" ]; then
  echo "缺少抠图模型 $MODEL（约 214 MB）"
  echo "  从开发机 tools/petgen/work/u2net/models/birefnet-general-lite/ 拷过来："
  echo "  mkdir -p $(dirname "$MODEL")  然后上传 birefnet-general-lite.onnx 到该目录"
  exit 1
fi
# 依赖：缺了就装一次
if ! "$PY" -c "import numpy, PIL, rembg" 2>/dev/null; then
  echo "安装依赖（只有第一次需要；国内机器先 export PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/）……"
  "$PY" -m pip install -r "$ROOT/tools/petgen/requirements.txt"
fi
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || {
  echo "缺少 ffmpeg / ffprobe：apt install -y ffmpeg"; exit 1; }

export PETGEN_SECRETS="$ROOT/secrets"
export U2NET_HOME="$ROOT/u2net"
export PYTHONUNBUFFERED=1
mkdir -p "$ROOT/work" "$ROOT/u2net"
cd "$ROOT/tools/petgen"
echo "petgen worker -> $SERVER  （工作目录 $ROOT/work）"
exec "$PY" -m petgen worker --server "$SERVER" --work "$ROOT/work" "$@"
