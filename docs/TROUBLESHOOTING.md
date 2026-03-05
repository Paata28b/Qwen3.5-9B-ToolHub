# TROUBLESHOOTING

## 1. 页面报内容编码错误

执行重启：

```powershell
.\start_8080_toolhub_stack.ps1 restart
```

如果仍失败，先清浏览器缓存，再刷新页面。

## 2. 启动后模型未就绪

先看状态：

```powershell
.\start_8080_toolhub_stack.ps1 status
```

再看日志：

```powershell
.\start_8080_toolhub_stack.ps1 logs
```

## 3. 提示缺少 llama-server.exe

重新执行安装脚本，确保 `.tmp\llama_win_cuda\llama-server.exe` 存在。

## 4. 提示模型文件不完整

检查下面两个文件是否存在：

- `.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\Qwen3.5-9B-Q4_K_M.gguf`
- `.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\mmproj-Qwen3.5-9B-BF16.gguf`

## 5. 看不到回答下方性能统计

当前版本要求消息里存在 `timings.predicted_n` 和 `timings.predicted_ms`。

重启后发一条新消息再看，旧消息不会回填。

## 6. 需要走 WSL 兼容流程

```powershell
.\install.ps1 -Wsl
```

然后在 WSL 内执行：

```bash
./start_8080_toolhub_stack.sh start
```
