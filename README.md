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
