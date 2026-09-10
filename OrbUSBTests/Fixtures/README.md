# Fixtures 来源

采集环境：2026-09-09，OrbStack 2.2.3 (2020300)。

- `list-captured-redacted.json`：真实 list JSON，Realtek RTL9210C + EarPods，未 attached。
- `list-captured.txt`：同一时刻真实 list 文本。
- `info-captured-redacted.txt`：真实 RTL9210C info。
- `list-attached-captured-redacted.json` / `.txt`：真实 EarPods attached 后的 list。
- `info-attached-captured-redacted.txt` / `info-detached-captured-redacted.txt`：真实 EarPods 往返状态。

- `list-empty-captured.json` / `.txt`：当日 18:02 的真实空设备列表。

脱敏只替换序列号；JSON 被重新格式化，字段、值类型及设备/ports 结构保留。原始输出在被 gitignore 排除的 `Tests/Fixtures/`。

测试函数名称含 Synthetic 的内容是明确人工构造的边界输入。特别是 Forwarded，尚没有本机串口/安全密钥真实采集，不能据合成测试声称已完成该类硬件验证。
