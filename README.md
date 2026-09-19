# VPS Tool

VPS 到手后的一键初始化脚本（第一版）。使用 Shell 编写，提供美化交互界面。

## 第一版功能

- SSH 仅允许密钥登录
- 未检测到公钥时可自动生成 Ed25519 密钥，并在确认下载和测试成功后删除服务器端临时私钥
- 修改 SSH 登录端口
- 自动检测并放行 UFW / firewalld 端口
- SSH 配置语法验证和临时自动回滚，降低锁死风险
- 安装和配置 Fail2ban
- 从脚本查看 Fail2ban 最近日志、实时日志、Ban/Unban、IP 查询
- 查看当前 Jail 和封禁 IP
- 从脚本解封 IP
- 配置 Fail2ban 和工具自身的 logrotate 清理策略
- 调用 [Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)
- 系统状态和最终配置验证

## 支持范围

第一版目标系统：Debian 12+、Ubuntu 24.04+，架构：x86_64 / aarch64。

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

## 常用命令

```bash
# 打开交互菜单
sudo vps-tool

# 查看系统状态
sudo vps-tool --status

# 验证配置
sudo vps-tool --verify

# 查看 Fail2ban 日志
sudo vps-tool --fail2ban-logs

# 执行待处理的 SSH 回滚
sudo vps-tool --rollback
```

## 自动生成 SSH 密钥

当目标用户没有可用公钥时，脚本默认提供“自动生成 Ed25519 密钥”选项：

1. 临时在服务器生成 Ed25519 密钥对，并将公钥加入 `authorized_keys`；
2. 提供 `scp` 下载命令，也可以输入 `PRINT` 在终端显示私钥；
3. 在本地保存私钥并通过当前 SSH 端口测试登录；
4. 测试成功后输入 `KEY_READY`；
5. 脚本删除服务器端临时私钥，只保留登录所需的公钥；
6. 如果取消或脚本异常退出，尚未确认的临时私钥和公钥会自动清理。

## 注意事项

- 脚本不会长期保存自动生成的私钥，也不会保存密码。
- BBRv3 安装器来自上游 GitHub，执行前会先下载到临时文件并记录日志。
- Fail2ban 日志可能来自 `/var/log/fail2ban.log` 或 systemd journal，脚本会自动检测。
- 日志查看和解封功能需要 root 权限。
- 第一次生产使用前，建议在测试 VPS 上验证，并确保有云厂商控制台或救援模式。
