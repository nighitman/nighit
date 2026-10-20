# QwenPaw 在沙箱里的试用记录（2026-10-20）

结论：**能装、能跑**（pip 发行版 `qwenpaw 2.2.2`），但只适合当"试玩/开发调试"环境，
不适合作为真正的个人助理长期部署在这里。

## 实测数据

| 项目 | 结果 |
| --- | --- |
| Python | 3.11.2（项目要求 `>=3.11,<3.14`）✅ |
| 安装方式 | `pip install qwenpaw`（无需编译前端，wheel 自带 console 静态文件） |
| 依赖体积 | 虚拟环境 **1.5 GB**，约 250 个包（onnxruntime / transformers / playwright / textual / LSP 等） |
| 初始化 | `qwenpaw init --defaults` 成功，生成 `config.json` + 16 个内置 skill |
| 启动 | `qwenpaw app` 监听 8088，`GET /` 返回 200（38 KB 控制台 HTML） |
| 空闲内存 | 单进程约 **420 MB RSS** |
| 模型连通性 | 默认 provider `kilo / kilo-auto/free` 在沙箱内 **Connection error**，未配置 Key 时无法对话 |

## 本机安装/启动命令（已验证）

```bash
cd /workspace
python3 -m venv .qp-venv
# 本沙箱的 pip 23.0.1 校验 pypi 证书链失败（certifi 过旧），需放宽校验：
.qp-venv/bin/pip install --no-cache-dir \
  --trusted-host pypi.org --trusted-host files.pythonhosted.org qwenpaw

# 状态目录指向 /workspace，避免落到 ~/.qwenpaw
export QWENPAW_WORKING_DIR=/workspace/.qpdata
export QWENPAW_TELEMETRY_DISABLED=1     # 不发送匿名遥测

# init 即使加 --defaults 也会交互确认安全须知，需要伪终端：
printf '\n' | script -qec "env QWENPAW_WORKING_DIR=/workspace/.qpdata \
  QWENPAW_TELEMETRY_DISABLED=1 .qp-venv/bin/qwenpaw init --defaults" /dev/null

# 启动控制台
QWENPAW_WORKING_DIR=/workspace/.qpdata .qp-venv/bin/qwenpaw app --host 127.0.0.1 --port 8088
# -> http://127.0.0.1:8088/
```

配置模型（云端 API Key，二选一）：

```bash
.qp-venv/bin/qwenpaw models config-key     # 交互式写入 provider key
.qp-venv/bin/qwenpaw models set-llm        # 选默认模型
# 或 DASHSCOPE_API_KEY=... qwenpaw app
```

自检：`qwenpaw doctor`（本次 API/console 检查全 OK，仅模型不可达）。

## 为什么"能装"但"意义有限"

1. **沙箱是临时的**：容器随时可能被回收，`~` 与 `/workspace` 未推送的内容都会丢；
   真正的助理需要 7×24 常驻 + 稳定入口。
2. **没有 GPU、内存只有 6 GB**：本地 QwenPaw-Flash（2B/4B/9B/27B/35B-A3B）跑不动，
   必须配云端 API Key，那就跟在自己电脑上装没区别。
3. **默认没有公网入口**：8088 只有容器内可访问；要访问得复用仓库里的
   `ssh-tunnel.sh` / argo / bore 之类的隧道。
4. **安全风险高**：
   - 控制台默认 **关闭登录认证**（`qwenpaw doctor` 明确提示），一旦通过隧道暴露，
     等于把"能执行任意 skill/命令的 agent"公开给互联网；
   - skill 以当前用户权限执行任意代码，而本沙箱对 git/gh 流量**自动注入 GitHub 凭据**，
     另有 `~/.config/komari/telegram.env` 等密钥，属于典型的凭据外泄面；
   - 若要在隧道后使用，先 `qwenpaw auth reset-password` 打开认证，并只放行自己。

## 建议

- 想长期用：装在自己的电脑 / 家宽小主机 / 云服务器（Docker 镜像 `agentscope/qwenpaw:latest` 最省事），
  开启认证、限制 channel 白名单。
- 想在这里临时体验：保留 `.qp-venv` + `.qpdata`（已被 `.gitignore` 忽略），
  配一个云端 Key 后用隧道访问 8088，用完 `pkill -f 'qwenpaw app'`。
