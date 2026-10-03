# AI-Ops P1-a 交付说明：lanhc-agent（设备侧伴随进程）

对应方案：`/home/dev/src/AI-OPS-CODEX-LANHC-PLAN.md` P1 阶段。

## 交付内容

| 文件 | 说明 |
| --- | --- |
| `lanhc/cmd/lanhc-agent/main.go` | tsnet 入网 + 只读 HTTP 服务 |
| `lanhc/cmd/lanhc-agent/collect.go` | inventory / health / SMART / logs 采集器 |
| `lanhc/cmd/lanhc-agent/exec.go` | 模板化命令白名单（无自由 shell） |
| `lanhc/cmd/lanhc-agent/http.go` | 只读 API 路由 |
| `lanhc/cmd/lanhc-agent/*_test.go` | 模板校验 + HTTP 端点测试 |
| `lanhc/cmd/lanhc-agent/README.md` | 运行 / API / 发行包安装文档 |
| `lanhc/cmd/lanhc-agent/install-agent.sh` | 随包分发的一键安装脚本 |
| `lanhc/cmd/lanhc-agent/lanhc-agent.service` | systemd 单元（随包分发） |
| `lanhc/cmd/lanhc-agent/lanhc-agent.defaults` | 环境文件（随包分发） |

## 验证结果

```text
go vet ./cmd/lanhc-agent/            # 通过
go test ./cmd/lanhc-agent/           # ok
go build -o bin/lanhc-agent ./cmd/lanhc-agent
bin/lanhc-agent -selfcheck
  hostname=DESKTOP-QUNGQK7 os=linux arch=amd64 cpus=24 mem=31939MB
  disks=6 failed_units=0 root_used=10.8% mem_used=10.0%
```

## 设计要点

- **伴随进程**：与 `lanhc` 同机，但独立二进制、独立 service；不修改 `lanhcd`。
- **只读优先**：写操作仅 `smartctl-long` / `smartctl-info` 两个模板，参数做字符白名单。
- **不装 Codex**：agent 无 AI、无 LLM key，只在 tailnet 上开放接口。
- **首次上线只填 `TS_AUTHKEY`**：hostname/control-url/dir/listen/tags 全部有默认值，
  推荐用带 `--tags tag:lanhc-agent` 的 preauthkey，agent 侧 tag 留空。
- **ACL 收口**：建议仅 `tag:ai-ops-runner` → `tag:lanhc-agent` 放行 `:8088`。

## 后续（P1-b）

iDRAC/Redfish 适配器：`Systems/1/Storage`、`LogServices/SEL`、`Power/Thermal`，
覆盖整机 down 时无法访问 agent 的场景。
