# fbu-docker

[fast-browser-use](https://github.com/APUS-AI-Lab/fast-browser-use) 的容器化封装：基于 **Debian 13**、ARM64、PyTorch CPU 推理。模型权重不打入镜像，首次运行自动从 ModelScope 下载到数据卷。同时兼容 **Docker** 与 **Podman**，下文命令两者通用（把 `docker` 换成 `podman` 即可）。

## 构建镜像

```bash
docker build -t fbu:latest .
# 或
podman build -t fbu:latest .
```

> 下文所有命令中的 `docker` 均可用 `podman` 等价替换，参数完全一致。

镜像内容：Debian 13 + Python venv（torch CPU / transformers / playwright / modelscope / fastapi）+ Chromium headless shell，约 1.5 GB，不含模型权重。

国内网络已内置换源加速，无需额外配置：
- 基础镜像经 DaoCloud 加速拉取（`--build-arg BASE_IMAGE=debian:13` 可切回官方源）
- apt 源 → 阿里云 `mirrors.aliyun.com`
- pip 源 → 阿里云 `mirrors.aliyun.com/pypi/simple/`
- HuggingFace → `hf-mirror.com` 镜像
- 模型权重 → ModelScope（国内直连，无需镜像）

## 运行

### 单次任务（首次运行自动下载约 67GB 模型到数据卷）

```bash
docker run --rm -v fbu-data:/data fbu:latest \
  run 'https://cn.bing.com/search?q=higkoo' \
  --goal '报告第一条搜索结果的标题。' \
  --expect-text 'higkoo' \
  --trace /data/artifacts/bing.json
```

结果写入卷内 `/data/artifacts/*.json`，包含最终页面状态、动作历史与断言校验明细。

### 常驻 HTTP 服务（模型只加载一次，适合 Agent 反复调用）

```bash
docker run -d --name fbu-serve -p 8768:8768 -v fbu-data:/data fbu:latest serve

# 健康检查
curl http://127.0.0.1:8768/health
# -> {"model_ready": true, "busy": false, "pending": 0}

# 提交任务
curl -s http://127.0.0.1:8768/run -H 'Content-Type: application/json' \
  -d '{"url":"https://cn.bing.com/search?q=higkoo","goal":"报告第一条搜索结果的标题。","expect_text":["higkoo"]}'
```

服务监听 `0.0.0.0:8768`（容器内所有网卡，便于端口映射与远程调用），端口用 `-p` 映射或环境变量 `FBU_PORT` 修改。接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 模型就绪状态、任务队列 |
| POST | `/run` | 执行一个浏览任务（`url`、`goal` 必填；`expect_url`、`expect_title`、`expect_text` 可选断言） |

任务串行执行，断言失败时返回 `ok: false`。服务无鉴权，请勿直接暴露公网。

### 复用已下载的模型

Qwen3.5-35B-A3B（BF16）约 67GB，运行时约占 80GB 内存。将宿主机目录挂载到 `/data` 可在容器重建后复用：

```bash
docker run --rm -v /path/to/fbu-data:/data fbu:latest run ...
```

或用 `FBU_MODEL_DIR` 指向其他含完整权重的目录。

## 运行要求

- ARM64（aarch64）主机；x86_64 同样适用（torch wheel 自动匹配）
- 内存：建议 ≥ 128GB（35B-A3B BF16 运行时约 80GB；小内存主机可改用 9B 模型，见下方环境变量）
- 无需 GPU、无需桌面环境（全程无头 Chromium）

## 主要环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `FBU_MODEL_DIR` | `/data/models/Qwen3.5-35B-A3B` | 权重目录（缺失时自动下载 35B-A3B） |
| `FBU_TRACE_DIR` | `/data/artifacts` | trace 输出目录 |
| `FBU_PORT` | `8768` | 常驻服务端口 |
| `FBU_HEADLESS` | `1` | 设为 `0` 显示浏览器窗口（需桌面环境） |
| `FBU_LOCALE` | `en-US` | 浏览器语言 |
| `TZ` | `Asia/Shanghai` | 容器时区（默认北京时间，日志时间戳同步） |

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 镜像构建（Debian 13） |
| `entrypoint.sh` | 入口：按需下载模型，转发 `run`/`serve` 命令 |
| `server.py` | 常驻 HTTP 服务（FastAPI） |

## 已知适配说明

- Playwright 官方不支持 Debian ARM64 的 chromium 分发，镜像内通过 `PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-arm64` 下载 headless shell，系统库由 apt 直接安装，已在 Debian 13 上实测可用。
- 模型从 ModelScope 镜像下载（国内网络友好）；HuggingFace 直连不可用时无需额外配置。
