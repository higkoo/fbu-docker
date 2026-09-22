#!/bin/bash
# 容器入口：首次启动自动通过 ModelScope 下载模型（约 67GB），然后执行 fbu 命令或常驻服务
set -e

MODEL_DIR="${FBU_MODEL_DIR:-/data/models/Qwen3.5-35B-A3B}"
export FBU_MODEL="$MODEL_DIR"
export FBU_BACKEND=torch
export FBU_DEVICE=cpu
export MODELSCOPE_CACHE=/data/.modelscope-cache

if [ ! -f "$MODEL_DIR/model.safetensors.index.json" ]; then
  echo "[entrypoint] 未发现本地权重，开始从 ModelScope 下载 Qwen3.5-35B-A3B（约 67GB）到 $MODEL_DIR ..."
  python -c "from modelscope import snapshot_download; snapshot_download('Qwen/Qwen3.5-35B-A3B', local_dir='$MODEL_DIR')"
  echo "[entrypoint] 模型下载完成。"
fi

if [ "${1:-}" = "serve" ]; then
  shift
  echo "[entrypoint] 启动常驻服务（模型加载后监听 0.0.0.0:${FBU_PORT:-8768}）..."
  exec python -m uvicorn server:app --host 0.0.0.0 --port "${FBU_PORT:-8768}" "$@"
else
  exec fbu "$@"
fi
