# Qwen3.5-9B ToolHub — 本地全能 AI 助手

基于 Qwen3.5-9B 多模态大模型的本地一体化部署方案。开箱即用，无需云端 API、无需联网授权，所有推理均在本机 GPU 完成。

## 能做什么

* 联网搜索与摘要 — 实时搜索互联网，抓取网页正文，提炼关键信息并附来源
* 图像理解 — 上传图片后直接提问，支持局部放大分析细节，支持以图搜图
* 文件浏览 — 浏览和读取本机文件（只读，不会修改你的文件）
* 深度思考 — 内置思维链（Chain-of-Thought），复杂问题可展开推理过程
* 流式输出 — 边生成边显示，思考过程和最终回答实时呈现
* OpenAI 兼容 API — 支持 `/v1/chat/completions` 接口，可对接第三方客户端

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11 |
| GPU | NVIDIA 显卡，驱动版本 >= 525，建议 6GB 以上显存 |
| WSL | 已安装并可正常使用 |
| WSL 内 | Python 3.10+、curl、sha256sum |
| 磁盘 | 至少 20GB 可用空间（模型 + 运行时） |

> Q4_K_M 量化下 9B 模型约占 5.5GB 显存，加上 mmproj 视觉投影约 6.1GB 总计。8GB 显存的显卡可正常运行。

## 快速开始

### 1. 安装

Windows 用户（推荐）：双击 `bootstrap.bat`，自动通过 WSL 完成所有安装。

WSL 终端：

```bash
./install.sh

```

安装脚本会自动完成：

* 创建 Python 虚拟环境并安装依赖
* 下载 llama.cpp CUDA 运行时（llama-server.exe）
* 下载 Qwen3.5-9B Q4_K_M 量化模型和视觉投影模型

> 如果你已有模型文件，可将 GGUF 文件放到对应目录，安装脚本会自动跳过下载。

### 2. 启动服务

```bash
./start_8080_toolhub_stack.sh start

```

首次启动需要 30-60 秒加载模型到 GPU。看到 `栈已启动` 表示就绪。

### 3. 开始使用

浏览器打开 [http://127.0.0.1:8080](http://127.0.0.1:8080)

直接在输入框输入问题即可。支持的问法示例：

* `帮我搜索今天的科技新闻并总结三条`
* `这张图片里有什么？`（需先通过 API 发送图片）
* `列出 D:\Projects 下的所有文件`

### 4. 停止服务

```bash
./start_8080_toolhub_stack.sh stop

```

## 服务管理

```bash
./start_8080_toolhub_stack.sh start    # 启动模型后端 + 网关
./start_8080_toolhub_stack.sh stop     # 停止所有服务
./start_8080_toolhub_stack.sh restart  # 重启
./start_8080_toolhub_stack.sh status   # 查看运行状态
./start_8080_toolhub_stack.sh logs     # 查看日志

```

## 架构概览

```
浏览器 / 第三方客户端
        │
        ▼
┌─────────────────────────────────────────┐
│     网关层 (端口 8080)                   │
│     run_8080_toolhub_gateway.py         │
│     • OpenAI 兼容 API                    │
│     • 工具调用代理                       │
│     • 流式 SSE 输出                      │
│     • WebUI 透传                         │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│     模型后端 (端口 8081)                 │
│     llama-server (llama.cpp)            │
│     • Qwen3.5-9B Q4_K_M 量化推理        │
│     • 视觉理解 (mmproj)                  │
│     • GPU 全层卸载 + Flash Attention     │
└─────────────────────────────────────────┘

```

工作流程：用户发送消息 → 网关判断是否需要调用工具 → 调用工具获取信息 → 将结果交给模型生成最终回答
→ 流式返回给用户。

## 内置工具

| 工具 | 说明 |
| --- | --- |
| `web_search` | 互联网搜索（基于 DuckDuckGo） |
| `web_fetch` | 抓取网页正文内容 |
| `web_extractor` | 提取网页结构化信息 |
| `image_search` | 以关键词搜索图片 |
| `image_zoom_in_tool` | 对图片指定区域放大查看 |
| `filesystem` | 浏览和读取本机文件（只读） |
| `read_memory` | 读取已保存的记忆 |

> 网关模式下文件系统为只读，不提供代码执行和命令执行能力，确保安全。

## 配置说明

复制 `.env.example` 为 `.env` 即可自定义配置，所有选项均有默认值：

```bash
# 端口
GATEWAY_PORT=8080        # 网关端口（用户访问）
BACKEND_PORT=8081        # 模型后端端口（内部）

# 推理参数
THINK_MODE=think-on      # think-on: 深度思考 | think-off: 快速回答
CTX_SIZE=16384           # 上下文窗口长度
IMAGE_MIN_TOKENS=256     # 单张图片最小视觉 token
IMAGE_MAX_TOKENS=1024    # 单张图片最大视觉 token
MMPROJ_OFFLOAD=off       # 视觉投影是否上 GPU（off 更稳定，on 更快）

```

### 思考模式切换

```bash
# 深度思考模式（默认）— 适合复杂推理，会输出思维链
THINK_MODE=think-on ./start_8080_toolhub_stack.sh restart

# 快速回答模式 — 跳过思维链，回答更快
THINK_MODE=think-off ./start_8080_toolhub_stack.sh restart

```

## 目录结构

```
.
├── bootstrap.bat                  # Windows 一键安装入口
├── install.ps1                    # PowerShell 安装脚本
├── install.sh                     # WSL 安装脚本（核心）
├── start_8080_toolhub_stack.sh    # 服务启停管理
├── switch_qwen35_webui.sh         # 模型后端控制
├── run_8080_toolhub_gateway.py    # 网关服务
├── toolhub_gateway_agent.py       # 工具代理逻辑
├── agent_runtime/                 # 工具实现
│   ├── search_tools.py            #   搜索工具
│   ├── web_fetch_tool.py          #   网页抓取
│   ├── image_zoom_tool.py         #   图片放大
│   ├── readonly_tools.py          #   只读文件系统
│   └── ...
├── requirements.txt               # Python 依赖
├── .env.example                   # 配置模板
├── docs/                          # 补充文档
│   ├── QUICKSTART.md
│   ├── RELEASE_NOTES.md
│   └── TROUBLESHOOTING.md
└── .tmp/                          # 运行时目录（安装后生成）
    ├── llama_win_cuda/            #   llama.cpp 运行时
    └── models/                    #   模型文件

```

## API 使用

网关提供 OpenAI 兼容的 Chat Completions 接口：

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-9B-Q4_K_M",
    "stream": true,
    "messages": [
      {"role": "user", "content": "今天有什么科技新闻？"}
    ]
  }'

```

也可搭配支持 OpenAI API 的客户端使用，将 API Base URL 设为 `http://127.0.0.1:8080/v1` 即可。

## 常见问题

### 页面报内容编码错误

```bash
./start_8080_toolhub_stack.sh restart

```

如仍有问题，清除浏览器缓存后刷新。

### 启动后模型未就绪

```bash
# 检查状态
./start_8080_toolhub_stack.sh status

# 查看日志定位问题
./start_8080_toolhub_stack.sh logs

```

### 提示 llama-server.exe 不存在

重新运行安装脚本，确认 `.tmp/llama_win_cuda/llama-server.exe` 已下载。

### 提示模型文件不完整

确认以下两个文件存在：

```
.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/Qwen3.5-9B-Q4_K_M.gguf
.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/mmproj-Qwen3.5-9B-BF16.gguf

```

### 回答下方看不到性能统计

重启服务后发送新消息即可显示，历史消息不会回填统计数据。

### 显存不足 (CUDA OOM)

* 降低上下文长度：`CTX_SIZE=8192 ./start_8080_toolhub_stack.sh restart`
* 降低图片 token：`IMAGE_MAX_TOKENS=512 ./start_8080_toolhub_stack.sh restart`
* 关闭视觉投影 GPU 卸载：确保 `MMPROJ_OFFLOAD=off`

## 已知限制

* 仅支持 Windows + WSL + NVIDIA GPU 环境
* 网关模式下文件系统为只读
* 不提供代码执行和系统命令执行能力
* 模型上下文窗口最大 16K tokens

## 致谢

* [Qwen3.5](https://github.com/QwenLM/Qwen3) — 阿里巴巴通义千问团队
* [llama.cpp](https://github.com/ggml-org/llama.cpp) — GGUF 量化推理引擎
* [Qwen-Agent](https://github.com/QwenLM/Qwen-Agent) — 工具调用框架
* [lmstudio-community](https://huggingface.co/lmstudio-community) — GGUF 量化模型