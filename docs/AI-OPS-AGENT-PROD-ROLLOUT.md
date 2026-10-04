# lanhc-agent 生产金丝雀上线 Runbook

适用：把 `lanhc-agent` 部署到生产设备（首个试点建议 R930），接入 `Lanhc AI Console` /
`Lanhc Sentinel` 的只读取证链路。

配套文档：`AI-OPS-DEPLOY-RUNBOOK.md`（全栈）、`lanhc/cmd/lanhc-agent/README.md`（组件）。

## 0. 结论先行

- **不需要重装 `lanhc` / `lanhcd`**：`lanhc-agent` 是独立二进制，自己用 `tsnet`
  加入同一 tailnet，与现有 lanhc 进程互不依赖。
- 上线只新增 3 个文件：二进制、systemd unit、环境文件。
- 回滚只影响 agent：`systemctl disable --now lanhc-agent`，lanhc 不受影响。
- 首轮只做「装 agent → 注册成功 → 节点 online → 从 runner curl healthz」，
  **先不要**接 AI 自动诊断和任何写操作。

## 1. 上线前检查

| 项 | 检查方法 | 期望 |
| --- | --- | --- |
| 控制面可达 | 在目标机 `curl -sS https://headscale.lanhc.com/health` | 有响应 |
| headscale user | `headscale users list` | 存在目标 user |
| preauth key | 见下方命令 | 拿到一次性 key |
| ACL | headscale policy | 放行 `tag:ai-ops-runner -> tag:lanhc-agent:8088` |
| systemd 单元名 | `systemctl list-units 'lanhc*'` | 确认是 `lanhcd.service` |
| 磁盘工具 | `command -v smartctl` | 有则 SMART 接口可用，无则返回结构化 error |

创建带 tag 的 preauth key（推荐主路径）：

```bash
headscale preauthkeys create --user <user> --tags tag:lanhc-agent --expiration 24h
```

> 规则：key 带 tag 时，agent 侧 `LANHC_AGENT_TAGS` 必须留空（默认即空）。
> 两边同时写 `tag:lanhc-agent` 会被 headscale 拒绝：
> `requested tags [...] are invalid or not permitted`。

## 2. 金丝雀安装（单机）

在目标机（首个试点机）执行：

```bash
tar xzf lanhc_linux_amd64.tar.gz
cd lanhc_linux_amd64

# 可选：先看采集能力，不接入 tailnet
./lanhc-agent -selfcheck

# 安装 + 注册 + 开机自启
sudo TS_AUTHKEY=tskey-auth-XXXX ./agent/install-agent.sh
```

脚本行为：

1. 二进制 → `/usr/local/bin/lanhc-agent`
2. unit → `/etc/systemd/system/lanhc-agent.service`
3. 环境文件 → `/etc/default/lanhc-agent`（写入 `TS_AUTHKEY`）
4. `systemctl daemon-reload && systemctl enable --now lanhc-agent`

`TS_AUTHKEY` 是一次性 key。注册成功后节点身份保存在 `/var/lib/lanhc-agent`，
可清空环境文件里的 `TS_AUTHKEY`，重启不会要求重新注册。

## 3. 验证

### 3.1 本机

```bash
systemctl status lanhc-agent --no-pager
journalctl -u lanhc-agent -n 50 --no-pager
```

日志应出现：

```
lanhc-agent <version> listening on tailnet :8088 (hostname=<host>-agent)
```

### 3.2 控制面

```bash
headscale nodes list | grep "$(hostname)-agent"
```

期望：该节点 `tag:lanhc-agent`、`online`、有 `100.64.x.y` 地址。

### 3.3 从 runner 经 tailnet 取证

在 `ops-runner` 所在节点或其容器内：

```bash
AGENT_IP=100.64.0.x
curl -sS http://$AGENT_IP:8088/v1/healthz
curl -sS http://$AGENT_IP:8088/v1/inventory
curl -sS http://$AGENT_IP:8088/v1/health
curl -sS "http://$AGENT_IP:8088/v1/logs?scope=journal&tail=100"
curl -sS "http://$AGENT_IP:8088/v1/disk/smart?dev=/dev/sda"
```

期望：前四个 `200`；SMART 在无 `smartctl` 时返回 `{"error":"smartctl not installed"}`，
而不是连接失败或崩溃。

受控命令接口格式（模板白名单，无自由 shell）：

```bash
curl -sS -X POST http://$AGENT_IP:8088/v1/exec \
  -H 'Content-Type: application/json' \
  -d '{"template_id":"smartctl-info","param":"device","value":"/dev/sda"}'
```

非白名单模板应返回 `400 unknown command template`。

### 3.4 控制台

`https://console.lanhc.com/ai-ops/*`：设备列表出现新 agent 节点，能拉到
inventory / health；`Lanhc Sentinel` 侧可对存活节点发起只读调查。

## 3.5 WSL2 / 无 root 金丝雀的 smartctl

金丝雀机是 WSL2 时，`lanhc-agent` 以普通用户运行打不开 `/dev/sd*`
（`Msft Virtual Disk`），`agent_disks` 会报 `smartctl not installed`：

```text
[worker] telemetry: 1 collection failure(s): agent_disks@lanhc-canary-agent (smartctl not installed)
```

处理办法（保持 agent 非 root）：

1. 物理机：`sudo apt-get install -y smartmontools` 即可，无需改 agent。
2. WSL2：一条命令装好 shim，无需 sudo：

   ```sh
   lanhc/cmd/lanhc-agent/tools/install-smartctl-wsl2.sh ~/bin
   ```

   它构建 `lanhc/smartmontools:7.4` 并把 `smartctl-wsl2.sh` 装成
   `~/bin/smartctl`；shim 优先调用原生 smartctl，缺原生工具时经 privileged
   一次性容器枚举 `/dev`，保证 `--scan-open` 不空。`~/bin` 在 PATH 中后重启
   `lanhc-agent`。
3. 验证链路：`agent_disks` 应返回设备列表；`telemetry` 日志不再出现
   `smartctl not installed`。

注意：WSL2 虚拟盘不会给出真实 ATA SMART 属性。`ops-runner` 现在的语义是
“如实上报失败”而非静默跳过，所以 WSL2 节点会看到每块虚拟盘一条
`agent_smart@<node>:<dev> (exit status 2)`，以及一条
`no SMART samples collected for host`——这是正确行为（不上报假数据）。
真实二手盘判据只在物理机（如 `baizor-agent` 的 MegaRAID 物理盘）上有意义。

## 4. 验收标准

- [ ] 目标机 agent 进程 active，开机自启已 enable。
- [ ] headscale 显示 `<host>-agent` online 且带 `tag:lanhc-agent`。
- [ ] runner 能访问 `/v1/healthz`、`/v1/inventory`、`/v1/health`、`/v1/logs`。
- [ ] 控制台能看到该节点及数据。
- [ ] `systemctl restart lanhc-agent` 后仍是同一节点身份（不需要重新注册）。

## 5. 铺开与回滚

**铺开**：按机架/角色分批，每批重复第 2–3 步；一批稳定后再下一批。

**单机回滚**：

```bash
sudo systemctl disable --now lanhc-agent
```

如需彻底移除：

```bash
sudo systemctl disable --now lanhc-agent
sudo rm -f /etc/systemd/system/lanhc-agent.service /etc/default/lanhc-agent
sudo rm -rf /var/lib/lanhc-agent /usr/local/bin/lanhc-agent
sudo systemctl daemon-reload
```

同时在 headscale 删除该节点（或在控制台移除）。回滚不影响 `lanhc` / `lanhcd`。

## 6. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `requested tags [...] are invalid or not permitted` | key 与 agent 同时带 tag | agent 侧 `LANHC_AGENT_TAGS` 留空，只用带 tag 的 key |
| 日志停在 `NeedsLogin` + auth URL | key 无效/过期/未传 | 换新 key 重新填 `TS_AUTHKEY` 后重启 |
| `PartOf=lanhcd.service` 报找不到单元 | 生产 daemon 单元名不同 | 改成实际名（如 `tailscaled.service`）后 `daemon-reload` |
| runner curl 超时 | ACL 未放行或节点离线 | 检查 headscale policy 与节点状态 |
| SMART 返回 `smartctl not installed` | 目标机无 smartmontools | `apt install smartmontools`（可选） |

## 7. 安全边界

- agent 只读优先；写操作仅 `smartctl-long` / `smartctl-info` 模板，参数白名单。
- agent 不装 Codex、不持有 LLM 凭据。
- 生产严禁 Codex `--dangerously-bypass-approvals-and-sandbox`。
- 所有 hub 写操作进 `audit_log`。
