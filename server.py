"""fast-browser-use 常驻 HTTP 服务：模型加载一次，通过 HTTP 提供浏览任务执行。

启动（由 fbu-serve.sh 封装）:
    uvicorn server:app --host 127.0.0.1 --port 8768

接口:
    GET  /health -> {"model_ready": bool, "busy": bool, "pending": int}
    POST /run    -> 执行一个任务，body:
        {
          "url": "https://example.com",
          "goal": "Report the main heading.",
          "expect_url": null,          # 可选，精确匹配最终 URL
          "expect_title": null,        # 可选，精确匹配最终标题
          "expect_text": ["IANA"]      # 可选，页面文本必须包含的子串（可多个）
        }
    返回 {"ok": bool, "status": ..., "elapsed_ms": ..., "trace": ..., "result": {...}}

任务串行执行（模型推理为 CPU 密集，并发无收益），多余请求在锁上排队。
"""

import json
import os
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from pydantic import BaseModel, Field

from fast_browser_use import Agent
from fast_browser_use.model import get_model
from fast_browser_use.verification import verify_outcome

TRACE_DIR = Path(os.environ.get("FBU_TRACE_DIR", "/models/fbu/artifacts"))

_lock = threading.Lock()
_pending = 0
_model_ready = False
_seq = 0


class Task(BaseModel):
    url: str
    goal: str
    expect_url: str | None = None
    expect_title: str | None = None
    expect_text: list[str] = Field(default_factory=list)


@asynccontextmanager
async def lifespan(app):
    global _model_ready
    print("loading model weights ...", flush=True)
    get_model()  # 阻塞到权重加载完成，之后常驻内存
    _model_ready = True
    print("model ready", flush=True)
    yield


app = FastAPI(title="fast-browser-use server", lifespan=lifespan)


@app.get("/health")
def health():
    return {"model_ready": _model_ready, "busy": _lock.locked(), "pending": max(_pending - 1, 0)}


@app.post("/run")
def run(task: Task):
    global _seq
    with _lock:
        _seq += 1
        seq = _seq
        trace = TRACE_DIR / f"serve_{time.strftime('%Y%m%d_%H%M%S')}_{seq:04d}.json"
        start = time.time()
        with Agent(task.url, task.goal) as agent:
            try:
                for state in agent.run():
                    last = state["history"][-1] if state["history"] else {}
                    print(f"[task {seq}] [{state['elapsed_ms']}ms] {state['status']} {last.get('action', '')}", flush=True)
            finally:
                result = agent.snapshot()
                if task.expect_url or task.expect_title or task.expect_text:
                    try:
                        result["verification"] = verify_outcome(
                            agent.browser,
                            url=task.expect_url,
                            title=task.expect_title,
                            text=task.expect_text,
                        )
                    except Exception as exc:
                        result["verification"] = {"passed": False, "error": f"{type(exc).__name__}: {exc}"}
                trace.parent.mkdir(parents=True, exist_ok=True)
                trace.write_text(json.dumps(result, indent=2))
        verification = result.get("verification", {})
        elapsed_ms = int((time.time() - start) * 1000)
        return {
            "ok": result.get("status") == "done" and verification.get("passed") is not False,
            "status": result.get("status"),
            "verification": verification,
            "elapsed_ms": elapsed_ms,
            "trace": str(trace),
            "result": result,
        }
