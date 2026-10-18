# 115nas — 115 生活客户端 Docker 版

全AI生成，把 **115 生活官方 Linux 桌面客户端**（`115Life_37.3.1.deb`）跑进 Docker 容器，  
通过浏览器（noVNC）直接使用：**扫码登录、文件浏览/管理、上传、下载、云下载、  
在线播放、分享**，官方客户端全功能保留，减少风控危险，无需在电脑上装任何软件。

- 一条 `docker compose up -d` 完成部署（首次构建约 5-15 分钟）
- 浏览器打开 `http://<主机IP>:6080/` 即用，自动进入客户端
- 扫码登录态持久化：重建容器不丢登录
- **内置 fcitx5 拼音输入法**：noVNC 窗口内 `Ctrl+Space` 直接打中文
- NAS 共享目录挂进容器，下载直接落盘；也可 `docker save` 导出镜像免重复构建
- 任意 Docker 主机可用：Linux / 群晖 DSM / QNAP Container Station / Windows

## 快速开始

```bash
# 1. 构建并启动（NAS_SHARE 指向宿主机上的目录，客户端下载落地处）
NAS_SHARE=/share/Download docker compose up -d

# 2. 打开浏览器
http://<主机IP>:6080/
```

首次会构建镜像（拉 debian:12 + apt + 官方 deb，约 5-15 分钟）。  
之后用 115 App 扫码登录。

不用 compose 的话，等价 `docker run`：

```bash
docker build -t 115nas:1.1.0 .

docker run -d --name 115nas --restart unless-stopped --shm-size=1g \
  -p 6080:6080 -p 6081:6081 \
  -e TZ=Asia/Shanghai \
  -v ./data/config:/config -v ./data/appdata:/appdata \
  -v ./data/cache:/cache -v ./logs:/logs \
  -v /share/Download:/media/nas -v /share/Download:/root/Downloads \
  115nas:1.1.0
```

## 中文输入

容器内已装 **fcitx5 拼音**：

1. 在 noVNC 窗口里点一下输入框
2. 按 `Ctrl+Space` 呼出输入法
3. 打拼音，候选项显示在虚拟屏上，**数字键选字**

任何场景都可以用「电脑上复制 → noVNC 窗口内 `Ctrl+V` 粘贴」兜底  
（noVNC 不传输本机输入法，但剪贴板是通的）。

## 目录与持久化

| 容器内路径               | 宿主机（compose 默认）  | 说明                                |
| ------------------- | ---------------- | --------------------------------- |
| `/root/Downloads`   | `$NAS_SHARE`     | **客户端默认下载目录**，直接落宿主机磁盘            |
| `/media/nas`        | `$NAS_SHARE`     | 同一目录的另一个入口，客户端文件选择器可见             |
| `/config`           | `./data/config`  | 客户端配置（勿删）                         |
| `/appdata`          | `./data/appdata` | WebKit Cookie = **扫码登录态**（勿删）     |
| `/cache`            | `./data/cache`   | 视频缓存（可清理）                         |
| `/logs`             | `./logs`         | 各组件日志                             |
| `/certs/server.pem` | 挂载点              | HTTPS 证书（ PEM，证书+私钥合一）；存在才监听 6081 |

## 配置（环境变量）

| 变量                                                | 默认                  | 说明                              |
| ------------------------------------------------- | ------------------- | ------------------------------- |
| `TZ`                                              | `Asia/Shanghai`     | 时区                              |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | 1280 / 800 / 24     | 虚拟屏分辨率（浏览器端自动缩放适配）              |
| `HTTP_PORT` / `HTTPS_PORT`                        | 6080 / 6081         | noVNC 端口（改需同步改 compose 的 ports） |
| `VNC_PASSWORD`                                    | 空                   | noVNC 连接密码。**暴露到公网时务必设置**       |
| `VNC_PORT`                                        | 5900                | x11vnc 端口（仅监听 127.0.0.1，一般不用改）  |
| `HTTPS_CERT`                                      | `/certs/server.pem` | HTTPS 证书路径                      |

## 镜像仓库（ghcr.io / Docker Hub）

打版本标签即触发 GitHub Actions 自动构建推送：

```bash
git tag v1.1.0 && git push origin v1.1.0
```

产物：`ghcr.io/xheia/115nas-docker:1.1.0`（ghcr 已发布 `main` / `edge`，public）；
配好 Docker Hub Secrets 后同时推 `xheia/115nas-docker:1.1.0`。

> Docker Hub 启用（一次性）：仓库 Settings → Secrets and variables → Actions 添加
> `DOCKERHUB_USERNAME`（Docker Hub 用户名）和 `DOCKERHUB_TOKEN`
> （hub.docker.com → Account Settings → Personal access tokens，权限 Read/Write/Delete，
> **不是登录密码**）。仓库不存在时首次推送自动创建，默认 private，推完可在 Hub 后台改
> public。ghcr.io 无需任何配置。

使用发布版镜像（跳过本地构建）：把 compose 里的 `build: .` 删掉，`image:` 改为

```yaml
image: ghcr.io/xheia/115nas-docker:1.1.0
```

> 国内网络拉取 ghcr.io / docker.io 常需镜像加速或代理；拉不动时用上面  
> 「镜像导出与迁移」的 tar 文件，或本地构建。

## 排障

| 现象               | 排查                                                            |
| ---------------- | ------------------------------------------------------------- |
| 打开 6080 显示「拒绝连接」 | 容器没起来：`docker ps -a` 看状态；`docker logs 115nas` 看原因；首次启动后镜像还在构建 |
| 界面一直转圈连不上        | 看容器内 `/logs/entrypoint.log`、`x11vnc.log`、`websockify.log`     |
| 扫码后重启要重新扫码       | `/config`、`/appdata` 没挂卷或被删                                   |
| 下载的文件不在 NAS 上    | 下载目录被改过——客户端设置里指回 `/root/Downloads`；或检查 `NAS_SHARE` 挂载        |
| 中文输不进去           | `Ctrl+Space` 呼出 fcitx5；不行就用 `Ctrl+V` 粘贴                       |
| 端口 6080 被占用      | 改 `HTTP_PORT` 并同步 compose 的 ports 映射                          |
| 想重新构建镜像          | `docker compose build --no-cache`                             |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名与端口）
- noVNC 不传输本机输入法——中文靠容器内 fcitx5 或粘贴

## 目录结构

```
Dockerfile          镜像定义（debian:12 + X 栈 + fcitx5 + 官方 deb）
entrypoint.sh       容器入口：dbus→Xvfb→openbox→fcitx5→x11vnc→websockify→Life115
docker-compose.yml  Compose 编排
115Life_37.3.1.deb  115 生活官方 Linux 客户端（随仓库分发，构建时 COPY 进镜像）
.github/workflows/  CI：打版本标签自动构建并推送到 ghcr.io + Docker Hub
```

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，  
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
