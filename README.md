# 115nas — 115 生活客户端 Docker 版

把 **115 生活官方 Linux 桌面客户端**跑进 Docker 容器，通过浏览器（noVNC）直接使用：
扫码登录、文件浏览/管理、上传、下载、云下载、在线播放、分享——官方客户端全功能保留，
宿主机不用装任何软件。

- 一条 `docker compose up -d` 完成部署（首次构建约 5-15 分钟）
- 浏览器打开 `http://<主机IP>:6080/` 即用，自动进入客户端
- 扫码登录态持久化：重建容器不丢登录
- 任意 Docker 主机可用：Linux / 群晖 DSM / QNAP / Windows

## 快速开始

```bash
# 1. 把下面这份 docker-compose.yml 存到任意目录（或直接克隆本仓库）
# 2. 启动（NAS_SHARE 指向宿主机目录，客户端下载落地处）
NAS_SHARE=/share/Download docker compose up -d

# 3. 浏览器打开，用 115 App 扫码登录
http://<主机IP>:6080/
```

`docker-compose.yml`（与仓库根目录的文件一致，可直接复制使用）：

```yaml
services:
  115nas:
    # 默认直接用发布版镜像。latest 由 CI 自动维护：每天检查 115 官方 Linux
    # 客户端版本，有新版本就重建并更新 latest，所以
    #   docker compose pull && docker compose up -d
    # 即可跟随官方更新。
    # - 想锁定版本：把 :latest 改成具体 tag（如 :1.1.1，对应 115Life 37.3.1）
    # - 想本地构建：取消 build: . 的注释，并把 image 改回 115nas-docker:1.1.1
    #build: .   # 本地构建镜像
    image: ghcr.io/xheia/115nas-docker:latest
    container_name: 115nas
    restart: unless-stopped
    shm_size: 1g
    ports:
      - "6080:6080"     # noVNC 页面 + WebSocket（HTTP）
      - "6081:6081"     # HTTPS（仅挂载证书时监听）
      # - "5900:5900"   # 只有「原生 VNC 客户端直连」才需要；同时要开
      #                 # VNC_BIND=0.0.0.0 + VNC_PASSWORD，否则容器拒启
    volumes:
      - ./data/config:/config       # 客户端配置与登录态（勿删）
      - ./data/appdata:/appdata     # WebKit Cookie = 扫码登录态（勿删）
      - ./data/cache:/cache         # 视频缓存
      - ./logs:/logs
      - ${NAS_SHARE:-./data/nas}:/media/nas        # 上传目录
      - ${NAS_SHARE:-./data/nas}:/root/Downloads   # 客户端默认下载目录
    environment:
      - TZ=Asia/Shanghai
      # - VNC_PASSWORD=yourpassword   # 暴露到公网时务必设置
      # - VNC_BIND=0.0.0.0            # 仅原生 VNC 客户端/CF 浏览器渲染 VNC 需要，必须同时设密码
      # - SCREEN_WIDTH=1600           # 虚拟屏分辨率（浏览器端自动缩放）
      # - SCREEN_HEIGHT=900
```

> 国内拉取 ghcr.io 慢的话，把 `image` 换成 Docker Hub 的
> `xheia/115nas-docker:latest`（两边内容一致）。

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
| `VNC_PASSWORD` | 空 | noVNC 连接密码（RFB VncAuth）。**暴露到公网时务必设置**；设置后 noVNC 会**弹出密码框**要求输入。生效校验：`docker logs 115nas \| grep "password authentication enabled"` |
| `VNC_PASSWORD_AUTOLOGIN` | 空 | 设为 `1` 才把密码写进 URL 自动登录（免输入，但口令会留在地址栏/浏览器历史/访问日志里），默认关闭 |
| `VNC_PORT` | 5900 | VNC 服务端口，仅监听 127.0.0.1，一般不用改 |
| `VNC_BIND` | `127.0.0.1` | VNC 监听地址。设 `0.0.0.0` 才会对外开放 5900（给原生 VNC 客户端用）——**必须先设 `VNC_PASSWORD`，否则容器拒绝启动** |
| `WS_PATH` | `websockify` | noVNC 的 WebSocket 端点。被套了路径前缀（如 `/115nas/`）时改成 `115nas/websockify` |
| `WS_VERBOSE` | 空 | 设为任意值后 websockify 打印每个请求，用来确认 WS 握手有没有到达容器 |
| `HTTPS_CERT` | `/certs/server.pem` | HTTPS 证书路径 |
| `HIDE_SYSTEM_PATHS` | `1` | 文件选择器里收敛容器内部路径，设 `0` 关闭 |
| `GTK_BOOKMARKS` | `/root/Downloads=115 下载目录\|/media/nas=NAS 共享目录` | 钉在文件选择器侧栏顶部的书签，`\|` 分隔，写法 `路径=显示名` |
| `EXTRA_VISIBLE_MOUNTS` | 空 | 额外允许出现在文件选择器卷列表里的挂载点，空格分隔，如 `/share/Download /share/Multimedia` |

## 镜像仓库与自动更新

镜像发布在双仓库（均 public）：`ghcr.io/xheia/115nas-docker` 与 `xheia/115nas-docker`（Docker Hub），
标签 `main` / `edge` / `latest` / `1.1.1`（1.1.1 内置 115Life 37.3.1）。

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

## 公网访问的安全底线

noVNC / websockify 本身**没有账号体系**，谁打开页面谁就能
操作你的 115 账号。务必：① 设 `VNC_PASSWORD=<强密码>`（连接时需输入）；
② 前置 HTTPS（挂证书到 `/certs/server.pem` 走 6081，或在前面套一层 HTTPS）；
③ 能限 IP 就限 IP，或只走 VPN / Tailscale，不要裸暴露到公网。

## 排障

| 现象 | 排查 |
| --- | --- |
| 打开 6080 显示「拒绝连接」 | `docker ps -a` 看容器状态；`docker logs 115nas` 看原因；首次启动后镜像还在构建 |
| 页面能开、顶部红条「无法连接到服务器」 | 中间那层没把 WebSocket 转发进来——容器首页会先探测一次，并把尝试的地址和原因直接写在页面上 |
| 界面一直转圈连不上 | 看容器内 `/logs/entrypoint.log`、`/logs/xvnc.log`、`/logs/websockify.log` |
| 扫码后重启要重新扫码 | `/config`、`/appdata` 没挂卷或被删 |
| 下载的文件不在 NAS 上 | 客户端设置里下载目录指回 `/root/Downloads`；检查 `NAS_SHARE` 挂载 |
| 设了 `VNC_PASSWORD` 却不弹密码框 | 密码没生效。看 `docker logs 115nas`：应有 `password authentication enabled`；**没有就是容器在裸奔**。新版镜像在这种情形会直接拒绝启动（缺 `tigervnc-tools` 时就退化为无认证）。重建镜像并确认日志 |
| 端口 6080 被占用 | 改 `HTTP_PORT` 并同步 compose 的 ports 映射 |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名与端口）

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
