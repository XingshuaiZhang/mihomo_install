# Mihomo 代理 - Ubuntu 服务器部署

## 快速开始

### 首次安装
```bash
cd ~/tools/mihomo_install
bash install.sh
```

按提示输入：
- 安装目录（默认 `~/tools/mihomo`）
- Clash 订阅链接
- 端口配置（直接回车使用默认）

### 注册快捷命令（推荐）
```bash
cd ~/tools/mihomo_install
bash register.sh
source ~/.bashrc
```

之后在任何终端中可直接使用：
- `mihomo` - 启动代理并设置当前终端代理环境变量
- `mihomo-nodes` - 命令行测速所有节点并手动切换

### 配置全局代理（推荐）

`mihomo` 守护进程本身是常驻后台的，但 `http_proxy / https_proxy` 等
环境变量默认只在当前终端有效。如果希望**所有新终端、以及 VSCode
Remote-SSH 的扩展进程**（例如 Claude Code 插件）都自动走代理，
执行：

```bash
bash ~/tools/mihomo_install/setup_global_proxy.sh
```

它会做三件事：

1. 在 `~/.bashrc` 顶部（非交互式早返回之前）注入 `source proxy_toggle.sh`，
   保证非登录 / 非交互 shell 也继承代理变量。
2. 在 `~/.profile` 中同样注入，覆盖登录 shell 与 VSCode 远端启动路径。
3. 在 `~/.vscode-server/data/Machine/settings.json` 中写入
   `http.proxy / http.proxyStrictSSL / http.proxySupport`，
   让 VSCode 内核与扩展也走代理（原文件会自动备份为 `.bak.*`）。

安装后请：

- 已打开的终端执行 `source ~/.bashrc`，或重新打开终端。
- 在 VSCode 命令面板执行 **"Remote-SSH: Kill VS Code Server on Host..."**
  并重新连接，让远端扩展宿主进程继承新环境变量。这一步是修复
  **Claude Code 插件登录返回 403** 的关键。

验证：

```bash
echo $HTTPS_PROXY                                                # http://127.0.0.1:7890
curl -sS -o /dev/null -w "%{http_code}\n" https://api.anthropic.com
```

### 开关代理

`setup_global_proxy.sh` 安装后，任何新终端都已自动开启代理。
随时可以在当前 shell 中切换：

```bash
proxy_on        # 开代理
proxy_off       # 关代理
proxy_status    # 查看当前状态
```

> 这些函数只影响当前 shell 的环境变量，不会停止 mihomo 守护进程。

### Claude Code 插件登录仍报 403？强制重启 vscode-server

跑完 `setup_global_proxy.sh` 后，**已经在跑的** vscode-server 进程不会自
动继承新环境变量。VSCode 的 "Remote-SSH: Kill VS Code Server on Host..."
在 `VSCODE_RECONNECTION_GRACE_TIME`（默认 3 小时）保护下经常并不真杀，
导致 extensionHost 与 Claude Code 子进程仍然没有 `HTTPS_PROXY`，
登录回调换 token 时被直连拦截 → 403。

正确做法是从一个**独立的、非 VSCode 的** SSH 终端把 vscode-server 真正
杀掉，再让 VSCode 重新部署 server：

1. 在本地电脑另开一个普通 SSH 终端：
   ```bash
   ssh <你的用户>@<vps>
   ```

2. 在那个终端执行：
   ```bash
   pkill -u "$USER" -f '.vscode-server/cli/servers/.*/server-main.js'
   pkill -u "$USER" -f '.vscode-server/.*/bootstrap-fork'
   pkill -u "$USER" -f 'anthropic.claude-code'
   sleep 2
   pgrep -u "$USER" -af vscode-server     # 应无 server-main 输出
   ```

3. 回到 VSCode，**关掉**当前 Remote 窗口，再发起一个**新的** Remote-SSH
   连接（不是 reload）。

4. 在 VSCode 集成终端验证：
   ```bash
   echo $HTTPS_PROXY     # 应为 http://127.0.0.1:7890
   ```
   有值之后再点 Claude Code 登录。

> 不建议直接 `rm -rf ~/.vscode-server`：单纯删目录不会杀进程，反而会让
> server 与扩展全部重下、`settings.json` 中刚写入的 `http.proxy*` 丢失。
> 优先走上面 4 步；只有杀进程后 `HTTPS_PROXY` 依然为空才考虑 nuke。

### 卸载全局代理

```bash
bash ~/tools/mihomo_install/setup_global_proxy.sh --uninstall
```

会移除 `~/.bashrc` / `~/.profile` 中的标记块，以及 VSCode settings.json
中的 `http.proxy*` 键。之后请重新打开终端，并在 VSCode 中再次执行
"Remote-SSH: Kill VS Code Server on Host..." 让设置生效。

### 启动代理

**方式1：使用快捷命令（推荐）**
```bash
mihomo
```

**方式2：直接执行脚本**
```bash
source ~/tools/mihomo_install/quick_start.sh
```

### 测试网络
```bash
bash ~/tools/mihomo_install/test.sh
```

### 命令行测速和切换节点
```bash
bash ~/tools/mihomo_install/nodes.sh
```

如果已执行 `register.sh`，也可以直接运行：
```bash
mihomo-nodes
```

## 文件说明

- `install.sh` - 交互式安装脚本
- `quick_start.sh` - 一键启动脚本
- `register.sh` - 注册快捷命令
- `test.sh` - 网络测试工具
- `nodes.sh` - 命令行节点测速与手动切换工具
- `setup_global_proxy.sh` - 安装 / 卸载全局代理（写入 bashrc、profile、VSCode 设置）
- `proxy_toggle.sh` - 提供 `proxy_on / proxy_off / proxy_status` 开关函数

## 使用说明

### yacd 可视化界面

1. **设置 VSCode 端口转发**
   - 按 `F1` 或 `Ctrl+Shift+P`
   - 输入 "Forward a Port" 或 "转发端口"
   - 输入端口：`9090`

2. **访问 yacd**
   - https://yacd.metacubex.one
   - 或 https://yacd.haishan.me

3. **配置连接**
   - 主机：`127.0.0.1`
   - 端口：`9090`
   - 密钥：安装完成后显示

### 管理命令

```bash
# 启动/停止
~/tools/mihomo/run.sh
~/tools/mihomo/stop.sh

# 查看状态
~/tools/mihomo/status.sh

# 测速并切换节点
bash ~/tools/mihomo_install/nodes.sh

# 查看日志
tail -f ~/tools/mihomo/run/mihomo.log
```

### 节点测速与切换

默认会读取 `PROXY` 组中的全部节点，逐个测速，然后让你输入编号切换：

```bash
bash ~/tools/mihomo_install/nodes.sh
```

常用参数：

```bash
# 仅测速，不进入切换提示
bash ~/tools/mihomo_install/nodes.sh --list-only

# 指定测速超时（毫秒）
bash ~/tools/mihomo_install/nodes.sh --timeout 3000

# 指定其他 Selector 组
bash ~/tools/mihomo_install/nodes.sh --group GLOBAL
```

## 默认配置

- 代理端口：`7890` (HTTP/SOCKS5)
- 控制端口：`9090`
- 安装目录：`~/tools/mihomo`

## 故障排除

```bash
# 查看状态
~/tools/mihomo/status.sh

# 重启服务
~/tools/mihomo/stop.sh && ~/tools/mihomo/run.sh

# 测试网络
bash ~/tools/mihomo_install/test.sh
```
