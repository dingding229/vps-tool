# Fail2ban 日志中心

交互模式选择“查看 Fail2ban 日志”，或执行：

```bash
sudo bash scripts/fail2ban-log.sh
```

支持：

- 最近 N 条日志
- 实时跟踪日志，Ctrl+C 返回
- 仅查看 Ban / Unban 记录
- 查询指定 IP
- 最近 1 小时 / 24 小时
- 查看当前封禁 IP
- 解封 IP

脚本优先读取 `/var/log/fail2ban.log`，不存在时回退到 `journalctl -u fail2ban`。
