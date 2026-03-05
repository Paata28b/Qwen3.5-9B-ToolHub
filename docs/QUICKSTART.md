# QUICKSTART

## 1. 安装

### Windows 主入口

在项目根目录双击运行 `bootstrap.bat`。

### PowerShell 手动入口

```powershell
.\install.ps1
```

### WSL 兼容入口

```powershell
.\install.ps1 -Wsl
```

## 2. 启动

```powershell
.\start_8080_toolhub_stack.ps1 start
```

## 3. 打开网页

浏览器访问 `http://127.0.0.1:8080`

## 4. 查看状态

```powershell
.\start_8080_toolhub_stack.ps1 status
```

## 5. 查看日志

```powershell
.\start_8080_toolhub_stack.ps1 logs
```

## 6. 停止服务

```powershell
.\start_8080_toolhub_stack.ps1 stop
```

## 7. WSL 旧命令

```bash
./start_8080_toolhub_stack.sh start
./start_8080_toolhub_stack.sh stop
```
