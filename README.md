<p align="center">
  <img src="./logo.png" width="96" alt="SeerCat">
</p>

<h1 align="center">SeerCat</h1>

<p align="center">
  TCP / UDP 流量转发管理面板：端口转发、多跳隧道、用户配额、限速、流量计费，一个面板管理所有节点。
</p>

<p align="center">
  <a href="https://github.com/gokele/SeerCat-releases/releases/latest"><img src="https://img.shields.io/github/v/release/gokele/SeerCat-releases?label=最新版本" alt="release"></a>
  <img src="https://img.shields.io/badge/平台-Linux%20amd64%20%7C%20arm64-6366F1" alt="platform">
</p>

---

本仓库只用于发布 SeerCat 的程序与安装脚本，下载和更新都从这里获取。

## 功能

- **两种转发**：端口转发 (入口直连目标) 与隧道转发 (入口 → 多跳中转 → 出口，支持 TLS / WSS 等加密协议)
- **TCP / UDP** 同时转发，多个目标地址支持轮询、随机、主备，目标故障自动切换
- **多用户**：按用户、按隧道分配转发数量、流量额度、到期时间，到期或超额自动暂停
- **限速**：按用户的隧道权限绑定限速规则
- **流量计费**：单向 / 双向计费，流量倍率，每月自动重置
- **节点管理**：一键生成安装命令，在线状态与系统监控，链路诊断
- **节点自动恢复**：节点重装系统或换机器后，重新连上面板即自动恢复全部规则与限速
- **登录人机验证**：拉绳 / 曲线滑块行为验证 (可在网站配置里开启)
- 主控、节点都是单个程序，不依赖 Docker、Java、数据库服务

## 安装主控

需要 Linux (systemd)，使用 root 运行：

```bash
curl -fL https://github.com/gokele/SeerCat-releases/releases/latest/download/panel.sh -o panel.sh && bash panel.sh
```

国内服务器下载慢可以用加速地址：

```bash
curl -fL https://ghfast.top/https://github.com/gokele/SeerCat-releases/releases/latest/download/panel.sh -o panel.sh && bash panel.sh
```

选择「安装」，输入面板端口 (默认 `6366`)，完成后访问 `http://服务器IP:端口`。

- 默认管理员：`admin_user` / `admin_user`，**首次登录后请立即修改**
- 登录后先在「网站配置」填写面板地址 (如 `1.2.3.4:6366`)，节点用它连接面板
- 面板套了 CDN / HTTPS 时，面板地址填 `https://你的域名`，节点会自动使用 wss 连接

## 安装节点

在面板「节点管理」新增节点，点击复制安装命令，到节点服务器上用 root 执行即可，命令形如：

```bash
curl -fL https://github.com/gokele/SeerCat-releases/releases/latest/download/agent.sh -o ./agent.sh && chmod +x ./agent.sh && ./agent.sh -a 面板地址:端口 -s 节点密钥
```

## 从 flux-panel 迁移

**主控**：在原 flux-panel 服务器上运行上面的主控安装命令，选择「安装」。脚本检测到旧版后会自动：

1. 读取原来的 JWT 密钥和前端、后端端口
2. 正常停止旧容器，复制数据库到 `/opt/seercat/data`
3. 删除旧容器 (数据卷 `sqlite_data` 和镜像保留，确认无误后可自行删除)
4. 启动 SeerCat，**同时监听原前端端口和原后端端口**

账号、节点、隧道、转发、限速、流量全部保留，已登录的用户不用重新登录，节点不用改任何配置。

**节点**：在每台节点上运行：

```bash
curl -fL https://github.com/gokele/SeerCat-releases/releases/latest/download/agent.sh -o agent.sh && bash agent.sh update
```

脚本会把旧的 `/etc/flux_agent` 迁移到 `/etc/seercat`，沿用原面板地址、密钥和本地规则，旧目录改名为 `/etc/flux_agent.bak-时间` 备份。

## 更新

```bash
# 主控
curl -fL https://github.com/gokele/SeerCat-releases/releases/latest/download/panel.sh -o panel.sh && bash panel.sh update

# 节点
curl -fL https://github.com/gokele/SeerCat-releases/releases/latest/download/agent.sh -o agent.sh && bash agent.sh update
```

更新前会自动备份程序和数据库 (主控保留最近 5 份)，新版本启动失败会自动回滚。安装指定版本可加 `SEERCAT_VERSION=v2.1.0`。

## 卸载

```bash
bash panel.sh uninstall   # 主控，可选择是否保留数据
bash agent.sh uninstall   # 节点
```

## 文件位置

| | 主控 | 节点 |
|---|---|---|
| 程序 | `/opt/seercat/seercat` | `/etc/seercat/seercat-agent` |
| 配置 | `/opt/seercat/seercat.env` | `/etc/seercat/config.json` |
| 数据 | `/opt/seercat/data/seercat.db` | `/etc/seercat/gost.json` |
| 备份 | `/opt/seercat/backup/` | `/etc/seercat/seercat-agent.bak` |
| 服务 | `systemctl status seercat` | `systemctl status seercat-agent` |
| 日志 | `journalctl -u seercat -f` | `journalctl -u seercat-agent -f` |

主控配置 `seercat.env`：

```ini
SEERCAT_LISTEN=:6366          # 监听端口，多个用逗号分隔，如 :7878,:6365
SEERCAT_DB=/opt/seercat/data/seercat.db
JWT_SECRET=...                # 登录令牌密钥，修改后所有用户需要重新登录
TZ=Asia/Shanghai              # 流量重置与统计使用的时区
```

修改后执行 `systemctl restart seercat`。

## 常见问题

**节点一直离线？** 检查「网站配置」里的面板地址是否正确，以及主控端口是否在防火墙 / 安全组放行。节点日志：`journalctl -u seercat-agent -f`。

**转发不通？** 在转发列表点「诊断」，会逐段检测入口、中转、出口到目标的连通性。同时确认节点上的转发端口已在防火墙放行。

**节点重装系统了？** 重新运行面板里复制的安装命令即可，节点连上后规则会自动恢复。

**文件校验**：每个版本附带 `SHA256SUMS`，可用 `sha256sum -c SHA256SUMS` 校验下载的文件。

## 许可

SeerCat **可免费使用**，包括运营你自己的转发服务 (个人或商业运营均可)；**禁止转售、出租本软件，禁止二次分发** (在其他网站、网盘、仓库或镜像重新发布)。分享本仓库的官方下载地址不受限制。完整条款见 [LICENSE](./LICENSE)。

SeerCat 基于 [flux-panel](https://github.com/bqlpfy/flux-panel) (Apache License 2.0) 与 [gost](https://github.com/go-gost/gost) (MIT) 修改开发，感谢原作者。第三方组件的许可证全文见 [THIRD_PARTY_LICENSES](./THIRD_PARTY_LICENSES)，署名与修改说明见 [NOTICE](./NOTICE)。

## 免责声明

本软件为流量转发工具，仅限合法、合规用途，使用者须确保其使用行为符合所在国家或地区的法律法规。**禁止将本软件用于任何违法或未经授权的行为，包括但不限于网络攻击、数据窃取、非法访问等。** 使用本软件的风险由使用者自行承担，作者不提供任何形式的担保。
