# fast-browser-use Docker 镜像（Debian 13 / ARM64 CPU 推理）
# 默认通过 DaoCloud 镜像加速拉取基础镜像（docker.io 直连受限的环境友好）；
# 网络无限制时可用 --build-arg BASE_IMAGE=debian:13 切换回官方源
ARG BASE_IMAGE=docker.m.daocloud.io/library/debian:13
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    VENV=/opt/fbu-venv \
    PLAYWRIGHT_BROWSERS_PATH=/opt/fbu/ms-playwright \
    PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-arm64 \
    FBU_TRACE_DIR=/data/artifacts \
    PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/ \
    MODELSCOPE_CACHE=/data/.modelscope-cache \
    HF_HUB_OFFLINE=1

# apt 源切换为阿里云镜像（兼容新版/旧版 sources 文件格式）
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
 || sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
 || true

# Chromium headless shell 运行所需系统库
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-venv python3-pip \
      git curl ca-certificates \
      libnss3 libnspr4 libasound2t64 libgbm1 libwayland-server0 \
      fonts-liberation libfontconfig1 \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv "$VENV"
ENV PATH="$VENV/bin:$PATH"

# 依赖约束文件需先于 pip 步骤复制（ torch 版本钉死见文件内注释）
COPY constraints.txt /root/constraints.txt

# PyTorch CPU 后端依赖（aarch64 的 PyPI wheel 即 CPU 版）+ ModelScope 下载工具 + 常驻服务
# 模型权重统一从 ModelScope（国内直连）下载，不依赖 HuggingFace
# torch 通过 constraints.txt 钉在 2.12：aarch64 wheel 为纯 CPU 构建
# （2.13+ 会连带拉取约 3GB 的 CUDA 依赖），防止上游依赖范围放行升级
RUN pip install --no-cache-dir -c /root/constraints.txt \
      "transformers>=5.17,<6" "accelerate>=1.10,<2" \
      "playwright>=1.58,<2" fastapi uvicorn \
 && pip install --no-cache-dir -c /root/constraints.txt \
      "fast-browser-use[torch,modelscope] @ git+https://github.com/APUS-AI-Lab/fast-browser-use.git"

# Playwright 对 Debian ARM64 无官方支持，伪装 ubuntu24.04-arm64 下载 headless shell
RUN python -m playwright install chromium-headless-shell

# 系统时区落到 /etc/localtime 与 /etc/timezone，date/日志时间戳一并使用北京时间
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime && echo "${TZ}" > /etc/timezone

WORKDIR /app
COPY server.py entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

ENV FBU_BACKEND=torch \
    FBU_DEVICE=cpu
VOLUME /data
EXPOSE 8768

ENTRYPOINT ["/app/entrypoint.sh"]
# 默认演示任务；实际使用通过 docker run 传参覆盖
CMD ["run", "https://cn.bing.com/search?q=higkoo", "--goal", "报告第一条搜索结果的标题。", "--trace", "/data/artifacts/demo.json"]
