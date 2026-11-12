# 115nas — 115 生活客户端 Docker 版

115nas客户端，115 Docker 版，全AI开发，把 **115 生活官方 Linux 桌面客户端**跑进 Docker 容器，用浏览器直接使用：  
扫码登录、文件浏览、上传下载、云下载、在线播放、分享——官方客户端全功能保留，  
宿主机不用装任何软件。

- 一条 `docker compose up -d` 完成部署
- 浏览器打开 `http://<主机IP>:6080/` 即用
- 扫码登录态持久化，重建容器不丢登录
- Linux / 群晖 DSM / QNAP / Windows 都能跑

## 快速开始

```bash
# 1. 把下面的 docker-compose.yml 存到任意目录（或直接克隆本仓库）
# 2. 在同一个目录里启动
docker compose up -d

# 3. 浏览器打开，用 115 App 扫码登录
#    http://<主机IP>:6080/
```

下载的文件落在与 `docker-compose.yml` 同级的 `downloads/` 目录。

```yaml
services:
  115nas:
    image: xheia/115nas-docker:latest
    container_name: 115nas
    hostname: 115nas
    restart: unless-stopped
    stop_grace_period: 20s
    shm_size: 1g
    ports:
      - "6080:6080"     # Web 页面 + WebSocket（同一端口）
    volumes:
      - ./data/config:/config       # 客户端配置与登录态
      - ./data/appdata:/appdata     # WebKit Cookie = 扫码登录态
      - ./data/cache:/cache         # 视频缓存
      - ./logs:/logs
      - ./downloads:/root/Downloads   # 客户端默认下载目录
      - ./downloads:/media/nas        # 同一目录的另一个入口
    environment:
      - TZ=Asia/Shanghai
```

> 完整注释版见仓库根目录的 `docker-compose.yml`。国内拉取 ghcr.io 慢的话，  
> 把 `image` 换成 Docker Hub 的 `xheia/115nas-docker:latest`（内容一致）。
>
> 想把下载直接落到 NAS 共享盘，把 volumes 里那两行的左边改成绝对路径（如 `/share/Download`）；右边不动。下载不在 `data/` 里，备份时只拷 `data/` 就够了。

## 版本

**版本号就是本项目的发版号（1.1.x），每个 1.1.x 冻结当时内置的 115 客户端。**  
镜像同时带 label `115nas.client-version`，可以直接查：

```bash
docker inspect --format '{{index .Config.Labels "115nas.client-version"}}' ghcr.io/xheia/115nas-docker:1.1.6
```

| 本项目   | 内置 115 客户端 | 主要变化                                        |
| ----- | ---------- | ------------------------------------------- |
| 1.1.8 | 37.3.2     | 下载与上传统一到 `./downloads`；启动日志去重；客户端反复崩溃会告警     |
| 1.1.7 | 37.3.2     | 登录用户名与口令配对（`VNC_USER`）；诊断页不再误报 WebSocket 失败 |
| 1.1.6 | 37.3.2     | 显示栈换成 KasmVNC（三进程合一）、单端口、诊断页与 `115nas-diag` |
| 1.1.5 | 37.3.2     | 每版一个客户端镜像；修正帧率探测                            |
| 1.1.4 | 37.3.1     | 停止容器时让客户端自己退出，传输队列能落盘                       |

115 官方发新客户端时，定时任务会**自动发一版**：递增版本号 → 构建 + 冒烟测试 → 推镜像 →  
打附注 tag（并建一条 GitHub Release）。**tag 说明里写明内置的官方 deb 版本**，所以  
「哪个镜像对应哪版 115」以 tag 为准（上表只记主要节点）：

```bash
git tag -l -n6 'v*'     # 版本号 + 说明（含内置 deb 版本、上游地址）
```

`latest` 跟着最新发版走；想冻结就用具体版本号：

```bash
docker compose pull && docker compose up -d      # image: ...:1.1.6
docker exec 115nas dpkg-query -W -f='${Version}\n' 115life   # 确认实际装的客户端版本
```

> 换版本**不影响登录态**：`/config`、`/appdata` 是宿主机目录，与镜像版本无关。  
> 但降级前先备份 `./data`——客户端会升级自己的本地库，新版写过的库旧版未必读得回来。

## 目录与配置

| 容器内路径               | 宿主机              | 说明                                 |
| ------------------- | ---------------- | ---------------------------------- |
| `/root/Downloads`   | `./downloads`    | 客户端默认下载目录，直接落宿主机磁盘                 |
| `/media/nas`        | `./downloads`    | 同一目录的另一入口，文件选择器可见                  |
| `/config`           | `./data/config`  | 客户端配置、登录态、machine-id               |
| `/appdata`          | `./data/appdata` | WebKit Cookie = **扫码登录态**          |
| `/cache`            | `./data/cache`   | 视频缓存、字体缓存（可清）                      |
| `/logs`             | `./logs`         | 各组件日志；单个文件超过 2 MiB 会自动截断保留最后 500 行 |
| `/certs/server.pem` | 自备               | 让容器自己讲 HTTPS 时挂这里，见 `VNC_TLS_CERT` |

> **从 1.1.7 及更早版本升级**：旧 compose 把下载写进 `./nas/Downloads`、上传写进 `./data/nas`，  
> 1.1.8 起统一为 `./downloads`。先停容器、把两个旧目录的内容合并过去，再启动：
>
> ```bash
> docker compose down
> mkdir -p downloads
> rsync -a ./nas/Downloads/ ./downloads/ 2>/dev/null   # 没有 rsync 就用 cp -a
> rsync -a ./data/nas/      ./downloads/ 2>/dev/null
> docker compose up -d
> ```
>
> 确认文件都在 `downloads/` 之后，再删掉空的 `./nas` 与 `./data/nas`。

> 容器以 **root** 运行，下载/上传的文件属主是 `root`、默认模式 `644`。NAS 上别的账号或  
> 套件（Emby/Jellyfin/Plex、另一个 uid 的下载器）需要写这些文件时设 `UMASK=000`，  
> 只对新文件生效，存量文件见「排障」。

| 环境变量                                              | 默认                                              | 说明                                                                               |
| ------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| `TZ`                                              | `Asia/Shanghai`                                 | 时区                                                                               |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | 1280 / 800 / 24                                 | 虚拟屏分辨率（浏览器端自适应缩放）                                                                |
| `VNC_FRAME_RATE`                                  | `25`                                            | 帧率上限，`0` 关闭。见「性能」                                                                |
| `VNC_QUALITY_MIN` / `VNC_QUALITY_MAX`             | 3 / 7                                           | 动态画质区间：下限决定滚动流畅度，上限决定静态清晰度                                                       |
| `VNC_WEBP_TIME`                                   | `5`                                             | WebP 编码耗时预算，越大越清晰越费 CPU                                                          |
| `HTTP_PORT`                                       | 6080                                            | 容器内 Web 端口。一般不用动；端口冲突改 compose 里 `ports` 的**左边**就够                               |
| `VNC_PASSWORD`                                    | 空                                               | 设置后浏览器出现登录框，**登录用户名见下一行**。至少 6 位（工具硬限制），公网暴露务必设置                         |
| `VNC_USER`                                        | `vncuser`                                        | 登录用户名，与 `VNC_PASSWORD` 配对：登录框里填这个名字 + 你设的口令。改名字后旧用户名失效                          |
| `VNC_BIND`                                        | `127.0.0.1`                                     | **只对降级模式（`DISPLAY_MODE=fallback`）生效**：设 `0.0.0.0` 才对外开放 5900，且必须同时设 `VNC_PASSWORD`，否则拒绝启动 |
| `VNC_TLS_CERT`                                    | `/certs/server.pem`                             | 挂载 PEM（证书+私钥合一）后，6080 改走 HTTPS/WSS                                               |
| `DISPLAY_MODE`                                    | `auto`                                          | `kasmvnc` / `fallback` 可强制指定，排障用                                                 |
| `HIDE_SYSTEM_PATHS`                               | `1`                                             | 文件选择器侧栏钉上常用目录书签，设 `0` 关闭                                                         |
| `GTK_BOOKMARKS`                                   | `/root/Downloads=115 下载目录\|/media/nas=NAS 共享目录` | 书签，`\|` 分隔，写法 `路径=显示名`                                                           |
| `UMASK`                                           | `022`                                           | 新落盘文件的权限掩码。默认 `022` → 文件 644、目录 755；设 `000` → 666/777，任何 uid 都能读写（**属主仍是 root**） |

## 性能

画面链路是「客户端绘制 → X11 帧缓冲 → 服务端编码 → 浏览器解码」，编码全在 NAS 的 CPU 上  
（容器无 GPU），所以**每帧编码量**是主要开销。1.1.6 的默认值已经按「文件管理界面」调过：

- 编码由 KasmVNC 负责，WebP/JPEG 按带宽与延迟反馈自适应，且多线程编码
- 帧率上限 25fps（服务端原生默认 60，对文件列表是纯浪费）
- 画质区间 3–7：滚动时自动降、停下自动升
- 静态资源与 WebSocket 由同一个进程提供，没有中间转发

仍觉得慢时按序试（都可用环境变量覆盖，不用重建镜像）：

| 旋钮                    | 默认       | 调法                       |
| --------------------- | -------- | ------------------------ |
| `VNC_FRAME_RATE`      | `25`     | 降到 `15`，编码量再减；拖窗口会有轻微残影  |
| `VNC_QUALITY_MAX`     | `7`      | 降到 `5`，静态画面糊一点，但每帧编码更快   |
| `VNC_WEBP_TIME`       | `5`      | 降到 `2`，明显省 CPU，代价是文字边缘略糊 |
| `SCREEN_WIDTH/HEIGHT` | 1280x800 | 降到 1024x768，像素少 23%      |

先确认瓶颈在哪：`docker stats 115nas --no-stream`。CPU 打满才是上面这些参数的问题；  
`Xkasmvnc` 占用不高却仍卡，那就是网络或浏览器端。

## 公网访问的安全底线

页面本身**没有账号体系**（`VNC_PASSWORD` 才有），谁打开谁就能操作你的 115 账号。务必：  
① 设 `VNC_PASSWORD=<强密码>`；② 前置 HTTPS（反代终止 TLS，或挂证书用 `VNC_TLS_CERT`）；  
③ 能限 IP 就限 IP，或只走 VPN / Tailscale，不要裸暴露到公网。

登录框出现时，用户名是 **`vncuser`**（可用 `VNC_USER` 改），口令就是你设的 `VNC_PASSWORD`。

## 排障

```bash
docker exec 115nas 115nas-diag
```

它会打印显示后端、监听端口、HTTP/WebSocket 自检结果和最近日志。

| 现象                       | 排查                                                                                                                                             |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| 打开 6080 显示「拒绝连接」         | `docker ps -a` 看容器状态；`docker logs 115nas` 看原因                                                                                                  |
| 页面能开、连不上画面               | 打开 `http://<主机IP>:6080/diag.html`，它会分别报告 HTTP 转发与 WebSocket 握手结果，并给出对应中间层的改法                                                                   |
| 反代后面连不上                  | 中间层没转发 WebSocket。QNAP/威联通把**目标协议**改成 `HTTP 和 WebSocket`；nginx 需 `proxy_http_version 1.1` + `Upgrade`/`Connection` 头                            |
| 界面一直转圈                   | 看 `/logs/entrypoint.log`、`/logs/xkasmvnc.log`；若日志里有「降级到 Xvfb + x11vnc」，说明 KasmVNC 没起来，见该日志末尾                                                   |
| 进程在，但画面一片空白              | `docker exec 115nas 115nas-diag` 看「图形栈」段：没有「客户端窗口」或 X 扩展缺 `RANDR`/`XInputExtension`/`XTEST`，就是渲染/输入栈的问题；再结合 `/logs/life115.log`                |
| 扫码后重启要重新扫码               | `/config`、`/appdata` 没挂卷或被删                                                                                                                    |
| 下载的文件不在 NAS 上            | 客户端设置里下载目录指回 `/root/Downloads`；确认 compose 里 `./downloads` 那两行没被删掉，且该目录有写入权限                                                                    |
| 下载的文件别的应用读不了/删不掉         | 属主是 `root`（容器以 root 运行）。设 `UMASK=000` 重启，**只对新文件生效**；存量：`docker exec 115nas chmod -R a+rwX /root/Downloads`（只要读就不加 `w`，用 `a+rX`）               |
| 设了 `VNC_PASSWORD` 却不弹登录框 | `docker logs 115nas \| grep "登录口令已启用"`；没有就是没生效                                                                                                 |
| 115 提示登录异常 / 异地登录        | 容器重建后主机标识变了会被当成新设备。compose 已固定 `hostname`、镜像把 machine-id 存进 `/config`；再查出口 IP：`docker exec 115nas curl -s --noproxy '*' https://myip.ipip.net` |
| 重启后上传列表里又冒出已完成的任务        | 客户端把传输记录存在 `/appdata` 的本地库里（桌面版也一样）。若是**重复条目或状态错乱**，说明停止时客户端被强杀：新版会等它自己退出，`docker logs 115nas` 里能看到 `Life115 已自行退出`                            |
| 端口 6080 被占用              | 把 compose 里的 `"6080:6080"` 改成 `"8080:6080"`（左边是 NAS 上的端口，右边别动），`docker compose up -d` 后访问 `http://<主机IP>:8080/`                                |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 容器没有 GPU，界面走软件光栅，滚动流畅度取决于 NAS 的 CPU；  
  这是预期行为，调 VNC 编码参数只能省传输，改不了渲染。`115nas-diag` 的「图形栈」段可确认
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名、hostname 与端口）
- 文件选择器里仍能看到容器自己的目录（`/config`、`/appdata` 等），只是常用目录被钉在  
  侧栏顶部。标准 GTK3 没有「只显示指定目录」的开关，收干净要动挂载命名空间，不值得

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / lib / web / compose）：MIT
- 仓库内的 `115Life_*.deb`（官方 Linux 客户端安装包）版权归 **广东一一五科技股份有限公司** 所有，  
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
