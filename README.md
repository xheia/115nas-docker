# 115nas — 115 生活客户端 Docker 版

把 **115 生活官方 Linux 桌面客户端**跑进 Docker 容器，通过浏览器（noVNC）直接使用：
扫码登录、文件浏览/管理、上传、下载、云下载、在线播放、分享——官方客户端全功能保留，
宿主机不用装任何软件。

- 一条 `docker compose up -d` 完成部署（首次构建约 5-15 分钟）
- 浏览器打开 `http://<主机IP>:6080/` 即用，自动进入客户端
- 扫码登录态持久化：重建容器不丢登录
- 内置 fcitx5 拼音输入法：noVNC 窗口内 `Ctrl+Space` 直接打中文
- NAS 共享目录挂进容器，下载直接落盘
- 任意 Docker 主机可用：Linux / 群晖 DSM / QNAP / Windows

## 快速开始

```bash
# 1. 构建并启动（NAS_SHARE 指向宿主机目录，客户端下载落地处）
NAS_SHARE=/share/Download docker compose up -d

# 2. 浏览器打开，用 115 App 扫码登录
http://<主机IP>:6080/
```

不用 compose，等价 `docker run`：

```bash
docker build -t 115nas-docker:latest .

docker run -d --name 115nas --restart unless-stopped --shm-size=1g \
  -p 6080:6080 -p 6081:6081 \
  -e TZ=Asia/Shanghai \
  -v ./data/config:/config -v ./data/appdata:/appdata \
  -v ./data/cache:/cache -v ./logs:/logs \
  -v /share/Download:/media/nas -v /share/Download:/root/Downloads \
  115nas-docker:latest
```

## 中文输入与剪贴板

**容器内输入法**：在 noVNC 窗口里点输入框 → `Ctrl+Space` 呼出 fcitx5 → 打拼音、
**数字键选字**（候选项直接显示在虚拟屏上）。

**剪贴板**：容器用 TigerVNC 的 `Xtigervnc` 作显示栈，支持 RFB 的 Extended Clipboard
扩展，剪贴板按 **UTF-8** 传输，**中文双向复制粘贴不再乱码**。

> 老版本用 `x11vnc`，它不支持该扩展，只能退回标准 `ClientCutText`
> （RFC 6143 §7.5.6，仅 ISO-8859-1），中文会被逐字截断到低 8 位而乱码。

> 部分浏览器的异步剪贴板 API 仅在 HTTPS / localhost 下可用；若通过
> `http://<IP>:6080` 访问时剪贴板不可用，改用 HTTPS（挂证书到 `/certs/server.pem`）。

## 目录与配置

| 容器内路径 | 宿主机（compose 默认） | 说明 |
| --- | --- | --- |
| `/root/Downloads` | `$NAS_SHARE` | 客户端默认下载目录，直接落宿主机磁盘 |
| `/media/nas` | `$NAS_SHARE` | 同一目录的另一个入口，客户端文件选择器可见 |
| `/config` | `./data/config` | 客户端配置（勿删） |
| `/appdata` | `./data/appdata` | WebKit Cookie = **扫码登录态**（勿删） |
| `/cache` | `./data/cache` | 视频缓存（可清理） |
| `/logs` | `./logs` | 各组件日志 |
| `/certs/server.pem` | 挂载点 | HTTPS 证书（PEM，证书+私钥合一）；存在才监听 6081 |

| 环境变量 | 默认 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区 |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | 1280 / 800 / 24 | 虚拟屏分辨率（浏览器端自动缩放） |
| `HTTP_PORT` / `HTTPS_PORT` | 6080 / 6081 | noVNC 端口（改需同步改 compose 的 ports） |
| `VNC_PASSWORD` | 空 | noVNC 连接密码。**暴露到公网时务必设置** |
| `VNC_PORT` | 5900 | x11vnc 端口（仅监听 127.0.0.1，一般不用改） |
| `HTTPS_CERT` | `/certs/server.pem` | HTTPS 证书路径 |

## 镜像仓库与自动更新

镜像发布在双仓库（均 public）：`ghcr.io/xheia/115nas-docker` 与 `xheia/115nas-docker`（Docker Hub），
标签 `main` / `edge` / `latest` / `1.1.0`（1.1.0 内置 115Life 37.3.1）。

**115 官方客户端更新后，`latest` 自动跟进，无需人工干预：**

- CI 每天 18:00（北京时间）查询 115 官方版本接口 `appversion.115.com/1/web/1.0/api/getMultiVer`
- 发现新版本 → 自动下载 deb（校验 `dpkg Version` 与文件大小）→ 提交到 main →
  同一流水线内重建镜像 → 推送两个仓库的 `latest`（同时更新 `main`/`edge`）
- NAS 上跟更新：`docker compose pull && docker compose up -d`
  （compose 默认引用 `:latest`；想锁定版本就改成具体 tag）
- 查看镜像内置客户端版本：
  `docker inspect --format '{{index .Config.Labels "115nas.client-version"}}' <镜像名>`

手动操作：立即重建去 Actions → Publish Docker image → Run workflow；
发固定版本 `git tag v1.2.0 && git push origin v1.2.0`（产出 `1.2.0` + `latest`）。
流水线完整定义（上游检测源、校验逻辑、Secrets 说明）见仓库 `.github/workflows/docker-publish.yml`。

> 国内网络拉取 ghcr.io / docker.io 常需镜像加速或代理；拉不动就本地构建。

## 排障

| 现象 | 排查 |
| --- | --- |
| 打开 6080 显示「拒绝连接」 | `docker ps -a` 看容器状态；`docker logs 115nas` 看原因；首次启动后镜像还在构建 |
| 界面一直转圈连不上 | 看容器内 `/logs/entrypoint.log`、`x11vnc.log`、`websockify.log` |
| 扫码后重启要重新扫码 | `/config`、`/appdata` 没挂卷或被删 |
| 下载的文件不在 NAS 上 | 客户端设置里下载目录指回 `/root/Downloads`；检查 `NAS_SHARE` 挂载 |
| 中文输不进去 | `Ctrl+Space` 呼出 fcitx5；不行就 `Ctrl+V` 粘贴 |
| 粘贴/复制中文乱码 | 看日志 `display:` 一行：应为 `tigervnc`；若显示 `x11vnc` 说明 TigerVNC 未装上，重构建镜像 |
| 端口 6080 被占用 | 改 `HTTP_PORT` 并同步 compose 的 ports 映射 |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名与端口）
- noVNC 不传输本机输入法——中文靠容器内 fcitx5 或粘贴

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
