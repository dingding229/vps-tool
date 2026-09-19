# VPS Tool

VPS 到手后的一键初始化脚本。当前版本 `v0.6.0`，使用 Shell 编写，提供美化交互界面。

## 交互界面

- 页面采用统一的编号区块顺序：环境、APT、SSH、Fail2ban、vnStat、网络加速、工具更新、文件与备份；
- 主菜单按“快速开始 → SSH 与登录 → 访问防护 → 网络与流量 → 系统维护”排列，相近功能保持在同一区域；
- 中文标签按终端显示宽度对齐，不再使用按字节计算的 `printf %-Ns`；
- 主菜单和日志菜单按照“配置 → 监控 → 检查 → 恢复”分组；
- 窄终端使用紧凑的双行安全事件布局，宽终端自动切换为表格；
- Fail2ban 状态会解析成结构化指标，不再混入原始 Status 树；
- 所有页面、工具日志、备份名和状态时间统一显示为北京时间（`Asia/Shanghai`）。
- 正常启动时先刷新 APT 索引并检查可升级软件包，再进入 VPS Tool 功能；
- 每次运行会检查 GitHub `main` 分支版本；发现新版本时自动替换程序文件并重新进入原操作。

## 功能概览

- SSH 仅允许密钥登录
- 未检测到公钥时可自动生成 Ed25519 密钥，并在确认下载和登录成功后删除服务器端临时私钥
- 修改 SSH 登录端口
- 自动检测并放行 UFW / firewalld 端口
- SSH 配置语法检查和临时自动回滚，降低锁死风险
- 新端口与当前端口相同时自动跳过防火墙变更；重复的同值 `Port` 声明会去重检查，不再误判失败
- 当前端口不变且目标用户已经仅允许密钥登录时，自动跳过重复的新终端连接确认和定时回滚
- 为默认禁用 root 的 VPS 单独启用 root SSH 登录，推荐仅密钥，也可选择仅对 root 开放密码认证
- root 登录启用前自动备份 SSH 配置、root 密码状态、登录 Shell 和 `authorized_keys`，登录未确认时可完整恢复
- 安装和配置 Fail2ban
- 从脚本查看格式化的 Fail2ban 最近日志、实时日志、Ban/Unban、IP 查询
- Fail2ban 日志按事件、Jail 和 IP 分栏显示，封禁/恢复封禁/异常使用红色重点标记
- Fail2ban 文件日志和 systemd journal 时间统一转换为北京时间后显示
- 查看当前 Jail 和封禁 IP
- 从脚本解封 IP
- 配置 Fail2ban 和工具自身的 logrotate 清理策略
- 安装并启用 vnStat，自动识别和选择主要网络接口
- 从脚本查看累计、最近 24 小时、最近 30 天、最近 12 个月和流量最高日期
- vnStat 数据统一转换为 KiB / MiB / GiB / TiB，并以中文表格展示，不直接返回原始 JSON
- vnStat 时间戳统一转换为北京时间，支持切换默认查询接口
- 调用 [Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)
- 启动前自动执行 `apt-get update` 并检查系统软件包是否为最新；发现更新时以 Y/N 交互确认是否升级
- 启动时自动检查并安装 VPS Tool 新版本，更新失败不会阻止现有功能继续运行
- 系统状态和最终配置检查

## 支持范围

支持系统：Debian 12+、Ubuntu 24.04+，架构：x86_64 / aarch64。

## 一键安装

> 建议先确认 VPS 控制台或救援模式可用，并且不要关闭当前 SSH 会话。

使用 root 用户执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dingding229/vps-tool/main/install.sh)
```

使用普通 sudo 用户执行：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/dingding229/vps-tool/main/install.sh)"
```

安装器会将项目安装到：

```text
/opt/vps-tool
```

同时创建快捷命令：

```bash
sudo vps-tool
```

快捷命令可以从 `/usr/local/sbin/vps-tool` 符号链接启动，入口脚本会自动解析真实安装目录 `/opt/vps-tool`，不会错误地在 `/usr/local/sbin/config` 或 `/usr/local/sbin/lib` 中查找文件。

仅安装但不立即进入交互菜单：

```bash
sudo VPS_TOOL_INSTALL_ONLY=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/dingding229/vps-tool/main/install.sh)"
```

## 手动安装

```bash
git clone https://github.com/dingding229/vps-tool.git
cd vps-tool
sudo bash vps-init.sh
```

## 交互确认规则

所有确认问题统一显示为：

```text
是否继续 [Y/n]
```

- 输入 `Y` 或直接回车：继续；
- 输入 `N`：取消或返回；
- 输入其他内容：脚本会提示重新输入 Y/N。

## 常用命令

```bash
# 打开交互菜单
sudo vps-tool

# 查看系统状态
sudo vps-tool --status

# 检查系统配置
sudo vps-tool --verify

# 查看 Fail2ban 日志
sudo vps-tool --fail2ban-logs

# 打开 vnStat 流量中心
sudo vps-tool --vnstat

# 启用 root SSH 登录
sudo vps-tool --enable-root

# 执行待处理的 SSH 回滚
sudo vps-tool --rollback

# 检查并升级 APT 软件包
sudo vps-tool --apt

# 手动检查并安装 VPS Tool 更新
sudo vps-tool --update
```


## APT 启动检查

正常运行脚本时会在进入目标功能前检查系统软件包状态：

1. 执行 `apt-get update` 刷新软件包索引；
2. 使用模拟升级读取可升级数量，不直接展示冗长的 APT 原始输出；
3. 在交互终端发现更新时，格式化展示前 8 个软件包，并询问是否升级；
4. 确认问题仅接受 `Y/N`，直接回车默认 `Y`；
5. 使用 `apt-get upgrade --with-new-pkgs -y` 执行常规升级；如果仍有需要单独处理的软件包，会在结果中提示；
6. 检测到 `/var/run/reboot-required` 时提示重启服务器。

APT 网络或索引检查失败不会阻止 SSH 回滚及其他 VPS Tool 功能。非交互环境只检查并记录状态，不会自动执行系统升级。SSH 紧急回滚、APT 手动更新和工具自更新流程会跳过重复的启动检查。

手动打开完整的 APT 更新页面：

```bash
sudo vps-tool --apt
```

临时跳过一次启动检查：

```bash
sudo VPS_TOOL_SKIP_APT_CHECK=1 vps-tool
```

最近一次检查结果会记录在 `/var/lib/vps-tool/apt.conf`，并显示在“系统状态总览”的“系统软件 / APT”区块中。所有检查时间均显示为北京时间。

## 自动更新

脚本在受管理的安装目录（默认 `/opt/vps-tool`）启动时，会从 GitHub `main` 分支读取最新版本号：

- 远程版本高于当前版本时，自动下载并检查更新包；
- 更新时直接替换 `/opt/vps-tool`，成功后不保留旧版本备份；
- 更新完成后自动重新进入用户原本执行的功能；
- 网络不可用、下载失败或更新包检查失败时，继续使用当前版本，不影响 SSH、Fail2ban 等功能；
- Git 克隆的源码目录不会被自动覆盖。

也可以手动执行：

```bash
sudo vps-tool --update
```

临时跳过一次自动检查：

```bash
sudo VPS_TOOL_DISABLE_AUTO_UPDATE=1 vps-tool
```

自动更新状态会记录在 `/var/lib/vps-tool/update.conf`，并显示在“系统状态总览”页面。

## vnStat 流量监控

主菜单可分别选择“安装 vnStat 流量监控”和“查看 vnStat 流量”，也可以直接执行：

```bash
sudo vps-tool --vnstat
```

流量中心提供：

1. 流量总览：数据库更新时间、开始采集时间、累计接收/发送/合计、最新日月统计；
2. 今日流量：按北京时间筛选当天流量；
3. 最近 24 小时：按北京时间列出每小时流量；
4. 最近 30 天：按日期列出每日流量；
5. 最近 12 个月：按月份列出月流量；
6. 流量最高日期：格式化显示 Top 10；
7. 安装配置服务、切换默认监控接口、查看服务状态。

所有数据都通过 vnStat JSON 接口读取后再格式化，不会把原始 JSON 或原始命令输出直接显示到页面。流量单位使用 1024 进制自动换算（B、KiB、MiB、GiB、TiB、PiB）。新安装的 vnStat 只能从安装后开始采集，不会补生成历史流量；刚安装时页面显示“等待采集”属于正常情况。

## 启用 root SSH 登录

主菜单选择“启用 root SSH 登录”，或执行：

```bash
sudo vps-tool --enable-root
```

流程支持两种模式：

1. **仅密钥登录（默认且推荐）**：优先复用当前 sudo 用户的公钥；没有公钥时自动生成 Ed25519 密钥。若 root 账户被锁定，脚本会使用随机强密码解锁账户并立即丢弃该密码，同时保持 SSH 密码认证关闭。
2. **密码或密钥登录**：交互设置 root 强密码，只对 root 用户启用密码认证，不改变普通用户的仅密钥策略。建议先安装 Fail2ban。

脚本会把 root 专用规则作为 SSH 主配置的第一条 `Include` 加载，并使用 `sshd -t` 与 `sshd -T -C user=root,...` 检查实际生效参数。应用后必须在另一终端确认 root 登录；选择 `N` 时会恢复：

- `/etc/ssh/sshd_config`；
- root 专用 SSH 配置；
- root 原密码哈希和密码状态；
- root 原登录 Shell；
- root 原 `authorized_keys`。

如果系统配置了 `AllowUsers`、`DenyUsers`、`AllowGroups` 或 `DenyGroups`，脚本会提示这些访问控制仍可能阻止 root，最终以实际登录结果为准。

## 时间显示

- 脚本进程统一使用 `Asia/Shanghai`，所有工具生成的时间、页面标题、运行日志、配置时间和备份目录名均为北京时间；
- 读取 Fail2ban systemd journal 时先使用 UTC 带偏移时间，再转换为北京时间；
- 读取无时区偏移的 `/var/log/fail2ban.log` 时，先按服务器原时区解释，再转换为北京时间；
- 脚本不会修改服务器系统时区。

## 自动生成 SSH 密钥

当目标用户没有可用公钥时，脚本默认提供“自动生成 Ed25519 密钥”选项：

1. 临时在服务器生成 Ed25519 密钥对，并将公钥加入 `authorized_keys`；
2. 提供 `scp` 下载命令，并通过 Y/N 选择是否在终端显示私钥；
3. 在本地保存私钥并通过当前 SSH 端口确认登录；
4. 登录成功后在确认问题中输入 `Y`，直接回车也默认为 `Y`；
5. 脚本删除服务器端临时私钥，只保留登录所需的公钥；
6. 如果取消或脚本异常退出，尚未确认的临时私钥和公钥会自动清理。

## 注意事项

- 脚本不会长期保存自动生成的私钥，也不会保存明文密码。
- 启用 root 密码登录的风险高于仅密钥登录；默认选项始终是仅密钥模式。
- APT 升级采用常规 `upgrade --with-new-pkgs`，不会自动执行发行版升级，也不会自动删除软件包。
- BBRv3 安装器来自上游 GitHub，执行前会先下载到临时文件并记录日志。
- Fail2ban 日志可能来自 `/var/log/fail2ban.log` 或 systemd journal，脚本会自动检测。
- vnStat 统计依赖后台持续采集；重装前如需保留历史数据，请自行备份 `/var/lib/vnstat/`。
- 日志查看和解封功能需要 root 权限。
- 首次生产使用前，建议先在备用 VPS 上检查，并确保有云厂商控制台或救援模式。
