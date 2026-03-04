#!/usr/bin/env python3
import argparse
import os
from dataclasses import dataclass
from typing import Any, Dict, List, Set

import requests
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from starlette.concurrency import run_in_threadpool

from toolhub_gateway_agent import (
    build_non_stream_response,
    run_chat_completion,
    stream_chat_completion,
)

DEFAULT_GATEWAY_HOST = '127.0.0.1'
DEFAULT_GATEWAY_PORT = 8080
DEFAULT_BACKEND_BASE = 'http://127.0.0.1:8081'
DEFAULT_MODEL_SERVER = 'http://127.0.0.1:8081/v1'
DEFAULT_TIMEOUT_SEC = 180
STREAM_CHUNK_BYTES = 8192
SUPPORTED_PROXY_METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'HEAD']
HOP_HEADERS = {
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailers',
    'transfer-encoding',
    'upgrade',
}
LOCAL_CONFIG_KEY = 'LlamaCppWebui.config'
LOCAL_OVERRIDES_KEY = 'LlamaCppWebui.userOverrides'
WEBUI_SETTINGS_PATCH = f"""
<script>
(function () {{
  try {{
    var cfgKey = '{LOCAL_CONFIG_KEY}';
    var ovKey = '{LOCAL_OVERRIDES_KEY}';
    var cfg = JSON.parse(localStorage.getItem(cfgKey) || '{{}}');
    cfg.showMessageStats = true;
    cfg.keepStatsVisible = false;
    cfg.showThoughtInProgress = true;
    cfg.disableReasoningParsing = false;
    localStorage.setItem(cfgKey, JSON.stringify(cfg));

    var overrides = JSON.parse(localStorage.getItem(ovKey) || '[]');
    var set = new Set(Array.isArray(overrides) ? overrides : []);
    ['showMessageStats', 'keepStatsVisible', 'showThoughtInProgress', 'disableReasoningParsing']
      .forEach(function (k) {{ set.add(k); }});
    localStorage.setItem(ovKey, JSON.stringify(Array.from(set)));
  }} catch (e) {{
    console.error('webui settings patch failed', e);
  }}
}})();
</script>
<style>
.chat-processing-info-container {{
  display: none !important;
}}
</style>
""".strip()


@dataclass(frozen=True)
class GatewayConfig:
    backend_base: str
    model_server: str
    gateway_host: str
    gateway_port: int
    timeout_sec: int = DEFAULT_TIMEOUT_SEC


def parse_args() -> GatewayConfig:
    parser = argparse.ArgumentParser(description='Run 8080 toolhub gateway with 8081 llama-server backend.')
    parser.add_argument('--host', default=os.getenv('GATEWAY_HOST', DEFAULT_GATEWAY_HOST))
    parser.add_argument('--port', type=int, default=int(os.getenv('GATEWAY_PORT', str(DEFAULT_GATEWAY_PORT))))
    parser.add_argument('--backend-base', default=os.getenv('BACKEND_BASE', DEFAULT_BACKEND_BASE))
    parser.add_argument('--model-server', default=os.getenv('MODEL_SERVER', DEFAULT_MODEL_SERVER))
    parser.add_argument('--timeout-sec', type=int, default=int(os.getenv('GATEWAY_TIMEOUT_SEC', str(DEFAULT_TIMEOUT_SEC))))
    args = parser.parse_args()
    return GatewayConfig(
        backend_base=args.backend_base.rstrip('/'),
        model_server=args.model_server.rstrip('/'),
        gateway_host=args.host,
        gateway_port=args.port,
        timeout_sec=args.timeout_sec,
    )


def filtered_headers(headers: Dict[str, str]) -> Dict[str, str]:
    blocked = HOP_HEADERS | {'host', 'content-length', 'proxy-connection'}
    return {key: value for key, value in headers.items() if key.lower() not in blocked}


def drop_headers_ci(headers: Dict[str, str], names: Set[str]) -> Dict[str, str]:
    lowered = {name.lower() for name in names}
    return {key: value for key, value in headers.items() if key.lower() not in lowered}


def build_backend_url(base: str, path: str, query: str) -> str:
    if not query:
        return f'{base}{path}'
    return f'{base}{path}?{query}'


def stream_upstream(upstream: requests.Response):
    try:
        for chunk in upstream.iter_content(chunk_size=STREAM_CHUNK_BYTES):
            if chunk:
                yield chunk
    finally:
        upstream.close()


def inject_webui_settings(html: str) -> str:
    if WEBUI_SETTINGS_PATCH in html:
        return html
    if '<head>' in html:
        return html.replace('<head>', f'<head>\n{WEBUI_SETTINGS_PATCH}\n', 1)
    if '<body>' in html:
        return html.replace('<body>', f'<body>\n{WEBUI_SETTINGS_PATCH}\n', 1)
    return f'{WEBUI_SETTINGS_PATCH}\n{html}'


async def handle_gateway_health(cfg: GatewayConfig) -> Dict[str, Any]:
    status = 'ok'
    backend_error = ''
    try:
        health = requests.get(f'{cfg.backend_base}/health', timeout=cfg.timeout_sec)
        health.raise_for_status()
    except Exception as exc:  # noqa: BLE001
        status = 'degraded'
        backend_error = str(exc)
    return {'status': status, 'backend_base': cfg.backend_base, 'backend_error': backend_error}


async def handle_chat_completions(request: Request, cfg: GatewayConfig) -> Response:
    payload = await request.json()
    stream = bool(payload.get('stream', False))
    if stream:
        try:
            iterator = stream_chat_completion(payload, cfg.model_server, cfg.timeout_sec)
        except Exception as exc:  # noqa: BLE001
            error = {'error': {'code': 500, 'type': 'gateway_error', 'message': str(exc)}}
            return JSONResponse(status_code=500, content=error)
        return StreamingResponse(iterator, media_type='text/event-stream')

    try:
        result = await run_in_threadpool(run_chat_completion, payload, cfg.model_server, cfg.timeout_sec)
    except Exception as exc:  # noqa: BLE001
        error = {'error': {'code': 500, 'type': 'gateway_error', 'message': str(exc)}}
        return JSONResponse(status_code=500, content=error)

    answer = result['answer']
    model = result['model']
    reasoning = result.get('reasoning', '')
    return JSONResponse(content=build_non_stream_response(answer, model, reasoning))


async def handle_proxy(request: Request, full_path: str, cfg: GatewayConfig) -> Response:
    path = '/' + full_path
    url = build_backend_url(cfg.backend_base, path, request.url.query)
    headers = filtered_headers(dict(request.headers))
    body = await request.body()

    try:
        upstream = requests.request(
            method=request.method,
            url=url,
            headers=headers,
            data=body,
            stream=True,
            timeout=cfg.timeout_sec,
            allow_redirects=False,
        )
    except Exception as exc:  # noqa: BLE001
        error = {'error': {'type': 'proxy_error', 'message': str(exc)}}
        return JSONResponse(status_code=502, content=error)

    response_headers = filtered_headers(dict(upstream.headers))
    content_type = upstream.headers.get('content-type', '')
    if 'text/event-stream' in content_type:
        return StreamingResponse(
            stream_upstream(upstream),
            status_code=upstream.status_code,
            headers=response_headers,
            media_type='text/event-stream',
        )

    is_webui_html = (
        request.method == 'GET'
        and path in {'/', '/index.html'}
        and upstream.status_code == 200
        and 'text/html' in content_type
    )
    if is_webui_html:
        encoding = upstream.encoding or 'utf-8'
        html = upstream.content.decode(encoding, errors='replace')
        injected = inject_webui_settings(html)
        upstream.close()
        clean_headers = drop_headers_ci(response_headers, {'content-encoding', 'content-length', 'etag'})
        return Response(
            content=injected.encode('utf-8'),
            status_code=200,
            headers=clean_headers,
            media_type='text/html; charset=utf-8',
        )

    upstream.raw.decode_content = False
    data = upstream.raw.read(decode_content=False)
    upstream.close()
    return Response(content=data, status_code=upstream.status_code, headers=response_headers)


def create_app(cfg: GatewayConfig) -> FastAPI:
    app = FastAPI(title='Qwen3.5 ToolHub Gateway 8080')

    @app.get('/gateway/health')
    async def gateway_health() -> Dict[str, Any]:
        return await handle_gateway_health(cfg)

    @app.post('/v1/chat/completions')
    async def chat_completions(request: Request) -> Response:
        return await handle_chat_completions(request, cfg)

    @app.api_route('/{full_path:path}', methods=SUPPORTED_PROXY_METHODS)
    async def proxy_all(request: Request, full_path: str) -> Response:
        return await handle_proxy(request, full_path, cfg)

    return app


def main() -> None:
    cfg = parse_args()
    app = create_app(cfg)
    uvicorn.run(app, host=cfg.gateway_host, port=cfg.gateway_port, log_level='info')


if __name__ == '__main__':
    main()
