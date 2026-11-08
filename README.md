# 3x-ui + Nginx + REALITY 一键部署脚本

> Nginx 提供 TLS，Xray 负责 REALITY，3x-ui 面板只在本地监听，443 统一对外。

一个交互式的 Bash 部署脚本，面向 Debian / Ubuntu VPS。自动鉴别系统/内核/架构，检查域名与 IP 是否匹配，然后完成 Nginx、Let's Encrypt 证书、LibreSpeed 测速、3x-ui 面板和 REALITY 入站的部署。

脚本**不含任何真实域名、IP、密码或 Token**，运行时全部由你输入或现场自动生成。

---

## 功能概览

- 自动识别系统版本、内核、CPU 架构
- 域名 A 记录与本机公网 IP 匹配检查
- Nginx 在 `127.0.0.1:8443` 提供 TLS，`/80` 做跳转和证书申请
- Let's Encrypt 证书申请 + 自动续期（续期后自动 reload Nginx）
- LibreSpeed 测速页部署在 `/`
- 3x-ui 面板只监听 `127.0.0.1:2053`，通过随机后缀路径对外
- Xray REALITY 监听 `443`，伪装域名为你自己的域名，回落到 Nginx
- 可选：给面板配证书，之后新增 TLS 入站可一键点“从面板配置”
- 面板设置直接写 SQLite（`settings` 表），不依赖经常不落库的 `x-ui setting` 命令
- **不启用任何防火墙拦截**（不装/不开 ufw、iptables），保证面板新加的代理端口直接可用
- 部署前自动备份 Nginx / x-ui 数据库 / 证书到 `/root/backup-<时间>/`

## 架构

```
Internet:80    → Nginx（跳转 HTTPS + 申请证书）
Internet:443   → Xray REALITY（SNI = 你的域名, target = 127.0.0.1:8443）
                   ├─ REALITY 客户端 → 走节点
                   └─ 普通浏览器     → 回落 Nginx 127.0.0.1:8443 (TLS)
                                          ├─ /            → 127.0.0.1:3000  测速
                                          └─ /<面板后缀>/ → 127.0.0.1:2053  3x-ui 面板
```

| 端口 | 监听 | 服务 |
| :--- | :--- | :--- |
| 80/tcp | `0.0.0.0` | Nginx（跳转/ACME） |
| 443/tcp | `*:443` | Xray REALITY |
| 8443/tcp | `127.0.0.1` | Nginx TLS（仅本地） |
| 2053/tcp | `127.0.0.1` | 3x-ui 面板（仅本地） |
| 3000/tcp | `127.0.0.1` | LibreSpeed 测速（仅本地） |
| 2096/tcp | `*:2096` | 3x-ui 订阅服务（默认） |

## 环境要求

- Debian / Ubuntu（脚本在 Debian 13 上实测，其他版本会提示确认）
- root 权限
- 一个域名已添加 A 记录指向本机公网 IP（脚本会检查）
- 80、443 端口可从公网访问

## 快速使用

### 方式一：直接从 GitHub 拉取运行

```bash
curl -fsSL https://raw.githubusercontent.com/jamesszg/self-modified-3xui-panel-install-sh/main/deploy_3xui_nginx_reality.sh -o /root/deploy.sh
chmod +x /root/deploy.sh
bash /root/deploy.sh
```

### 方式二：本地上传

```bash
scp -P <你的SSH端口> deploy_3xui_nginx_reality.sh root@<服务器IP>:/root/
ssh -p <你的SSH端口> root@<服务器IP>
chmod +x /root/deploy_3xui_nginx_reality.sh
bash /root/deploy_3xui_nginx_reality.sh
```

### 交互式提问说明

脚本开头会依次问你（回车即用默认值）：

| 问题 | 说明 | 默认 |
| :--- | :--- | :--- |
| 域名 | 你的域名，如 `example.com` | 必填 |
| 面板用户名 | 3x-ui 登录账号 | `admin` |
| 面板密码 | 回车则自动生成 16 位随机密码 | 自动生成 |
| 面板后缀 | 面板访问路径，如 `3xui-xxxxxxxx` | 自动随机 |
| 是否创建 REALITY 443 入站 | VLESS+REALITY，SNI=你的域名 | 是 |
| 是否给面板配证书 | 配完后新 TLS 入站可点“从面板配置” | 否 |
| 是否部署测速到 `/` | LibreSpeed 自建测速 | 是 |

确认后脚本全程自动执行，最后打印汇总。汇总会写入服务器的 `/root/deploy_summary.txt`（权限 600，**切勿提交到仓库**）。

## 部署后如何访问

脚本最后会打印（同时保存在 `/root/deploy_summary.txt`）：

- 测速页：`https://<你的域名>/`
- 3x-ui 面板：`https://<你的域名>/<面板后缀>/`（用汇总里的账号密码登录）
- REALITY 客户端链接：`vless://...@<服务器IP>:443?...&sni=<你的域名>&...`，直接导入 v2rayN / NekoBox / Streisand 等客户端

服务均已设置开机自启，`reboot` 后会自动恢复，验证：

```bash
systemctl is-active nginx x-ui speedtest-go
curl -I https://<你的域名>/
curl -I https://<你的域名>/<面板后缀>/
```

## 日常操作

### 新增代理
在 3x-ui 面板里新建入站即可，生成的链接可直接导入客户端。注意：
- 新入站端口避开 `443, 80, 8443, 2053, 3000, 2096`
- REALITY 入站不需要证书；TLS 类入站如果已配面板证书，点“从面板配置”即可，不用手填路径
- 客户端二维码报“没有 subId”时，去编辑该客户端补一个唯一的 `subId` 再保存（脚本通过 API 创建的客户端默认 subId 为空）

### 修改面板后缀
面板和 Nginx 的路径必须**同步改**，否则打不开：
```bash
# 1. 停服务后直接改数据库（脚本里就是这么做的）
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='webBasePath'; INSERT INTO settings (key,value) VALUES ('webBasePath','/新后缀/');"
systemctl start x-ui
# 2. 改 Nginx 里对应的 location /新后缀/ { proxy_pass ... 2053; }
# 3. nginx -t && systemctl reload nginx
```

### 证书续期
Let's Encrypt 证书路径永远不变（`live/<域名>/fullchain.pem`），但续期后必须重载进程。脚本已装好续期 hook：续期后自动 `reload nginx`（若配了面板证书，还会同时 `restart x-ui`）。可手动演练：
```bash
certbot renew --dry-run
```

### 备份
部署前脚本会自动备份到 `/root/backup-<时间>/`。日常也建议定期备份：
```bash
cp -a /etc/x-ui/x-ui.db ~/x-ui.db.bak-$(date +%F)
```

## 常见问题

**`x-ui setting` 改了不生效？**
新版 `setting` 命令有时不落库。本脚本对面板端口/后缀/监听/证书都是停服务后直接用 `sqlite3` 改 `settings` 表再重启，改完会回读校验。

**改了面板后缀后面板打不开了？**
多半是 Nginx 的 `location` 没跟改，见上文“修改面板后缀”。

**Hysteria2 客户端报 `read/write on a closed pipe`？**
先查 `ss -tulnp | grep <端口>` 确认有 `udp` 监听；再核对证书/SNI/密码是否一致，并确认外网 UDP 没被服务商或本地网络拦截。UDP 监听了只代表服务端起来了，不代表外网能进来。

**443 冲突？**
443 只能给 REALITY 用，Nginx 只在本地 8443。新增入站不要再占 443。

## 安全提醒

- 立刻修改 root 密码和面板密码，妥善保存面板后缀路径
- 不要把 `/root/deploy_summary.txt`、`/root/reality_client.txt`、数据库和证书私钥提交到任何仓库
- 面板只监听本地，安全性依赖 Nginx 的随机后缀路径，改强密码并考虑开启面板两步验证

## 免责声明

本脚本仅供个人学习交流。网络代理的合法性因地区而异，请遵守当地法律法规及 VPS 服务商的服务条款。
