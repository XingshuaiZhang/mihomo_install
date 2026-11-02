# Mihomo 代理：Ubuntu 服务器部署

无需 sudo，在用户目录安装和管理 Mihomo，支持订阅更新、节点测速、终端及 VSCode Remote-SSH 代理。
默认启用固定住宅 SOCKS5 出口，也可在首次安装时选择普通机场代理。

住宅模式的流量路径：

```text
应用 → Mihomo → 选中的机场节点 → 固定住宅 SOCKS5 → 目标网站
```

切换机场节点不会改变最终住宅出口；住宅代理不可用时连接失败，不会自动回退到机场出口或直连。
代理只覆盖进入 Mihomo 的流量，忽略代理设置的应用仍可能直连。

## 快速开始

服务器需有 Git、`curl`、`gzip` 和 Python 3.8+；节点测速工具额外需要 `jq`。
住宅模式所需的 PyYAML 由安装脚本自动准备，无需手动激活 Python 环境。

```bash
git clone https://github.com/XingshuaiZhang/mihomo_install.git
cd mihomo_install
bash install.sh
```

按提示完成配置：

1. 选择安装目录，默认 `~/tools/mihomo`。
2. 选择是否启用住宅出口（默认开启），启用时输入住宅代理信息。
3. 输入预期出口 IP（可选）、Clash/Mihomo 订阅链接和端口。
4. 按需设置 GitHub 下载代理、定时更新、用户服务、终端及 VSCode 代理。

住宅代理支持整行粘贴，输入不回显：

```text
IP:端口@用户名:密码
```

例如 `192.0.2.10:1080@example-user:example-password`（仅格式示例）。地址支持域名，
IPv6 使用 `[IPv6]:端口@用户名:密码`；密码中的特殊字符按原样粘贴，无需引号或转义。
账号密码自动保存在安装目录，私有配置文件权限为 `600`，无需手动创建 JSON。

**预期出口 IP 应填写供应商分配的实际出口 IP，未必等于 SOCKS5 入口地址。**
留空时只检查连通性，不能确认是否使用指定出口；再次配置时回车保留原值，输入 `-` 清空。

安装脚本会生成并校验配置、启动代理并检查出口。出口验证失败会返回失败状态。
终端代理设置和快捷命令默认开启；安装后新开终端，或执行 `source ~/.bashrc`。
已有 VSCode 远程会话需重新连接，详见[终端与 VSCode 代理](#终端与-vscode-代理)。

已有安装直接重跑 `bash install.sh`，可添加或更换住宅参数，并复用内核、订阅、端口和控制密钥。
迁移到新服务器时重复以上步骤，重新输入订阅和住宅参数即可。

### 目录和默认端口

| 项目 | 默认值 |
| --- | --- |
| 安装目录（运行文件、私有配置） | `~/tools/mihomo` |
| HTTP / SOCKS5 代理端口 | `7890` |
| 控制端口（仅监听本机） | `9090` |

项目源码目录 `mihomo_install` 与安装目录 `mihomo` 是两个目录。
下文的 `bash *.sh`、`python3 check-claude.py` 均在项目源码目录执行；运行脚本路径使用默认安装目录。
自定义安装目录可在安装提示中填写，后续脚本可通过环境变量指定：

```bash
export INSTALL_DIR=/path/to/mihomo
bash install.sh
```

## 日常使用

注册快捷命令后，在新终端中使用：

```bash
mihomo                         # 启动代理，并设置当前终端的代理变量
mihomo-nodes                   # 测速并按编号切换节点
mihomo-nodes --list-only       # 仅测速
mihomo-nodes --timeout 3000    # 测速超时，单位毫秒
mihomo-nodes --group GLOBAL    # 指定代理组
mihomo-upgrade                 # 更新内核
mihomo-residential status      # 查看住宅模式状态，不显示账号密码

proxy_on                      # 开启当前终端代理
proxy_off                     # 关闭当前终端代理
proxy_status                  # 查看当前终端代理状态
```

`proxy_*` 函数由终端代理设置提供，只修改当前 shell 的环境变量，不会停止后台服务。
住宅模式下，节点名称保持不变，测速结果为整条住宅链路的延迟。

未注册快捷命令时，可运行 `bash register.sh` 后执行 `source ~/.bashrc`；
也可直接使用 `source quick_start.sh`、`bash nodes.sh`、`bash upgrade.sh` 和 `bash residential.sh status`。

### 服务管理与网络检测

```bash
~/tools/mihomo/run.sh                    # 启动
~/tools/mihomo/stop.sh                   # 停止
~/tools/mihomo/status.sh                 # 状态
tail -f ~/tools/mihomo/run/mihomo.log     # 日志

bash test.sh                            # 网络检测
bash test.sh --all                      # 住宅模式下逐节点验证出口
bash change_subscription.sh             # 更换订阅；住宅模式自动重建链路
```

### Claude 出口与 IP 属性

```bash
python3 check-claude.py
python3 check-claude.py --json
```

工具依赖 Python 3 和 `curl`，默认经 `http://127.0.0.1:7890` 查询
[Net.Coffee](https://ip.net.coffee/claude/) 及其数据接口，显示 Claude、Cloudflare、Anthropic
的实际出口和第三方住宅属性、风险评分。默认读取安装目录中保存的预期出口，可用 `--expected-ip` 覆盖。
自定义目录或端口时使用：

```bash
python3 check-claude.py --install-dir /path/to/mihomo --proxy http://127.0.0.1:17890
```

检测会显式使用代理、忽略 `NO_PROXY`，失败后不改走直连。
评分可能来自同网段代表 IP 的缓存，工具会标注；结果不验证 Claude 登录或 API 调用，
也不包含 DNS 泄露、WebRTC/UDP 或浏览器指纹检测。

### yacd 可视化管理

在 VSCode 中执行 **Forward a Port / 转发端口**，转发控制端口（默认 `9090`），
然后打开 [yacd](https://yacd.metacubex.one)，填写主机 `127.0.0.1`、转发后的本地端口及安装时显示的密钥。

## 住宅出口维护

### 配置、刷新与验证

```bash
bash residential.sh status               # 查看状态
bash residential.sh configure            # 更换住宅参数，回车保留原值
bash residential.sh refresh              # 下载订阅、重建链路、校验并加载
bash residential.sh verify               # 验证当前 PROXY 链路与预期出口
bash residential.sh verify --all         # 逐节点验证，结束后恢复原选择
```

验证要求 Mihomo 处于 `rule` 模式。`verify --all` 会临时切换 `PROXY`，影响同时使用代理的应用。
检测请求显式使用本机代理，忽略 `NO_PROXY`，失败后不会尝试直连。

住宅模式由本地工具接管订阅刷新，只提取订阅中的 `proxies`，不接受机场下发的规则和代理组。
更新先下载并校验候选配置，再替换和加载；下载、校验或加载失败时保留或恢复原配置。
配置变化后会关闭旧连接，让应用重建链路；未变化时不重载。
运行时保留仍存在的手选节点，重启后从组内首个节点开始。

订阅默认直连下载，不继承 shell 代理变量。服务器无法访问订阅地址时，可导入本地文件，保留原远程订阅 URL：

```bash
bash residential.sh refresh --subscription-file /path/to/subscription.yaml
```

### 定时更新

安装时可启用每小时更新：优先使用用户级 systemd，不可用时尝试用户 crontab，保留其他任务。
手动管理命令如下：

| 调度方式 | 启用 | 停用 |
| --- | --- | --- |
| systemd | `bash residential.sh timer-install` | `bash residential.sh timer-remove` |
| cron | `bash residential.sh cron-install` | `bash residential.sh cron-remove` |

systemd 定时器首次启用 5 分钟后更新，此后每小时一次；cron 在每小时整点更新。
`status` 可查看定时器名称。任务使用安装目录内的工具及已验证的 Python，移动项目源码无需重新配置定时任务。

用户 systemd 依赖服务器的用户会话策略，退出 SSH 后是否继续运行需以服务器配置为准；
cron 需要系统已运行该服务且允许用户任务。两者均不可用时，手动执行 `refresh`，现有链路仍可使用。

### 配置文件与自动化

安装目录中的以下文件以 `600` 权限保存：

| 文件 | 用途 |
| --- | --- |
| `residential.json` | 住宅代理参数 |
| `residential-source.yaml` | 订阅地址和原始配置 |
| `residential-subscription.yaml` | 最近一次成功下载的节点 |
| `config.yaml` | 自动生成的运行配置 |
| `config.before-residential.yaml` | 首次启用住宅模式前的备份 |

不要直接编辑生成的 `config.yaml`，下次刷新会覆盖它。
端口、订阅等原始设置可在 `residential-source.yaml` 中修改后运行 `refresh`；控制接口地址或密钥应停服后修改。

自动化部署可从私有 JSON 导入参数，格式见 [residential.example.json](residential.example.json)：

```bash
RESIDENTIAL_SETTINGS_FILE=/private/settings.json bash install.sh
# 为已有安装导入参数：
bash residential.sh configure --settings-file /private/settings.json
```

恢复普通机场出口：停用对应的 timer / cron 并停止 Mihomo，将 `config.before-residential.yaml`
恢复为 `config.yaml`，把 `residential-source.yaml` 移出安装目录，再启动服务。
恢复前请确认备份中的订阅仍有效。

### 支持范围

- 支持本项目默认的单个 `sub` HTTP provider，订阅为完整 Clash YAML 或含 `proxies` 的 provider YAML。
  不支持 Base64/URI 列表、多 provider、自定义 provider 覆盖/筛选或已有 `dialer-proxy` 的节点。
- 工具管理 `PROXY`、`AUTO`、`GLOBAL`、规则和 DNS，不保留自定义分流；不接受已开启 TUN 或有自定义 listeners/tunnels 的配置。
- 默认拒绝业务 UDP。确认住宅供应商和机场均支持后，才可将私有 JSON 中的 `udp` 改为 `true` 并重新导入。
- 应用需使用 HTTP 代理或支持 `socks5h://` 的 SOCKS 客户端。业务域名通过住宅链上的 DoH 解析，机场地址使用独立引导 DNS；系统 DNS 不受接管。
- 固定出口不保证目标网站的账号权限或服务可用性。

## 终端与 VSCode 代理

安装入口默认提供此设置。单独补配或卸载时运行：

```bash
bash setup_global_proxy.sh
bash setup_global_proxy.sh --uninstall
```

脚本修改 `~/.bashrc`、`~/.profile` 和 `~/.vscode-server/data/Machine/settings.json`，
让新终端和 VSCode 远端进程使用代理；修改前会备份已有 VSCode 设置。
卸载会移除相应 shell 标记块和 VSCode 的 `http.proxy*` 设置。

修改后，新开终端或执行 `source ~/.bashrc`；VSCode 中执行
**Remote-SSH: Kill VS Code Server on Host...**，再重新连接，以便远端进程加载新环境。
可在集成终端检查：

```bash
echo "$HTTPS_PROXY"    # 默认应为 http://127.0.0.1:7890
```

## 故障排除

先运行 `~/tools/mihomo/status.sh`、查看日志，再执行 `bash test.sh`。
需要重启时运行：

```bash
~/tools/mihomo/stop.sh && ~/tools/mihomo/run.sh
```

### VSCode 扩展没有使用代理或登录返回 403

旧的远端进程可能尚未加载代理变量；403 也可能来自出口或目标服务限制，不能仅凭状态码判断原因。
先按上一节重新连接。若旧进程仍未退出，可从**独立于 VSCode 的 SSH 终端**执行以下命令，
这会中断当前用户的 VSCode 远程会话及 Claude Code 进程：

```bash
pkill -u "$USER" -f '.vscode-server/cli/servers/.*/server-main.js'
pkill -u "$USER" -f '.vscode-server/.*/bootstrap-fork'
pkill -u "$USER" -f 'anthropic.claude-code'
pgrep -u "$USER" -af vscode-server
```

然后关闭旧 Remote 窗口并新建 Remote-SSH 连接。终端中有 `HTTPS_PROXY` 只能证明该终端已配置代理；
如仍失败，可用 `check-claude.py` 检查出口。无需通过删除 `~/.vscode-server` 来重启进程。

### Python / PyYAML 依赖

安装脚本优先复用已具备 PyYAML 的 Python / Conda 环境，否则在
`${XDG_DATA_HOME:-$HOME/.local/share}/mihomo_install/venv` 创建专用环境，不修改系统 Python。
缺少 `ensurepip` / `python3-venv` 时，会从 PyPA 下载对应版本的 `virtualenv.pyz`；首次准备依赖需能访问 PyPA 和 Python 包索引。

可单独运行 `bash setup_python.sh` 准备环境，或设置 `MIHOMO_PYTHON=/path/to/python`
指定已有 Python 3.8+ 和 PyYAML 的解释器。后续脚本自动选择环境，无需 `activate`。

## 开发验证

```bash
python3 -m unittest discover -s tests -v
# 内核不在 ../mihomo/bin/mihomo 时：
MIHOMO_TEST_BINARY=/path/to/mihomo python3 -m unittest discover -s tests -v
```

测试使用隔离目录和回环地址上的机场、住宅 SOCKS5 及 HTTP 服务，验证出口、故障不绕行、更新和回滚，
不接触现有实例或真实凭据。找不到内核时只运行配置单元测试，并跳过真实链路测试。
