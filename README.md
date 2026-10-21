# 115nas — 115 生活客户端 Docker 版

全AI开发，把 **115 生活官方 Linux 桌面客户端**跑进 Docker 容器，用浏览器（noVNC）直接使用：  
扫码登录、文件浏览、上传下载、云下载、在线播放、分享——官方客户端全功能保留，  
宿主机不用装任何软件。

- 一条 `docker compose up -d` 完成部署
- 浏览器打开 `http://<主机IP>:6080/` 即用
- 扫码登录态持久化，重建容器不丢登录
- Linux / 群晖 DSM / QNAP / Windows 都能跑

## 快速开始

```bash
# 1. 把下面的 docker-compose.yml 存到任意目录（或直接克隆本仓库）
# 2. NAS_SHARE 指向宿主机目录（客户端下载落地处），启动
NAS_SHARE=/share/Download docker compose up -d

# 3. 浏览器打开，用 115 App 扫码登录
#    http://<主机IP>:6080/
```

```yaml
services:
  115nas:
    image: ghcr.io/xheia/115nas-docker:latest
    container_name: 115nas
    hostname: 115nas
    restart: unless-stopped
    stop_grace_period: 20s
    shm_size: 1g
    ports:
      - "6080:6080"     # noVNC 页面 + WebSocket（HTTP）
      - "6081:6081"     # HTTPS（仅挂载证书时监听）
    volumes:
      - ./data/config:/config       # 客户端配置与登录态
      - ./data/appdata:/appdata     # WebKit Cookie = 扫码登录态
      - ./data/cache:/cache         # 视频缓存
      - ./logs:/logs
      - ${NAS_SHARE:-./data/nas}:/media/nas        # 上传目录
      - ${NAS_SHARE:-./data/nas}:/root/Downloads   # 客户端默认下载目录
    environment:
      - TZ=Asia/Shanghai
```

> 完整注释版见仓库根目录的 `docker-compose.yml`。国内拉取 ghcr.io 慢的话，  
> 把 `image` 换成 Docker Hub 的 `xheia/115nas-docker:latest`（内容一致）。

## 目录与配置

| 容器内路径               | 宿主机              | 说明                               |
| ------------------- | ---------------- | -------------------------------- |
| `/root/Downloads`   | `$NAS_SHARE`     | 客户端默认下载目录，直接落宿主机磁盘               |
| `/media/nas`        | `$NAS_SHARE`     | 同一目录的另一入口，文件选择器可见                |
| `/config`           | `./data/config`  | 客户端配置、登录态、machine-id             |
| `/appdata`          | `./data/appdata` | WebKit Cookie = **扫码登录态**        |
| `/cache`            | `./data/cache`   | 视频缓存、字体缓存（可清）                    |
| `/logs`             | `./logs`         | 各组件日志                            |
| `/certs/server.pem` | 自备               | HTTPS 证书（PEM，证书+私钥合一），存在才监听 6081 |

| 环境变量                                              | 默认                                              | 说明                                                                                                                  |
| ------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `NAS_SHARE`                                       | `./data/nas`                                    | compose 用：宿主机目录，同时挂到上面两个路径                                                                                          |
| `TZ`                                              | `Asia/Shanghai`                                 | 时区                                                                                                                  |
| `SCREEN_WIDTH` / `SCREEN_HEIGHT` / `SCREEN_DEPTH` | 1280 / 800 / 24                                 | 虚拟屏分辨率（浏览器端自动缩放）                                                                                                    |
| `VNC_FRAME_RATE`                                  | `25`                                            | 帧率上限，`0` 关闭。见「性能」                                                                                                   |
| `NOVNC_QUALITY`                                   | `5`                                             | noVNC JPEG 画质 0-9                                                                                                   |
| `NOVNC_COMPRESSION`                               | `1`                                             | noVNC 压缩级别 0-9，越低越省 CPU                                                                                             |
| `HTTP_PORT` / `HTTPS_PORT`                        | 6080 / 6081                                     | noVNC 端口（改需同步 compose 的 ports）                                                                                      |
| `VNC_PASSWORD`                                    | 空                                               | noVNC 连接密码（RFB VncAuth）。**公网暴露务必设置**，设置后连接时弹密码框。生效校验：`docker logs 115nas \| grep "password authentication enabled"` |
| `VNC_BIND`                                        | `127.0.0.1`                                     | 设 `0.0.0.0` 才对外开放 5900（原生 VNC 客户端直连用）——**必须同时设密码，否则容器拒绝启动**                                                         |
| `WS_PATH`                                         | `websockify`                                    | 被套了路径前缀（如 `/115nas/`）时改成 `115nas/websockify`                                                                        |
| `HTTPS_CERT`                                      | `/certs/server.pem`                             | HTTPS 证书路径                                                                                                          |
| `HIDE_SYSTEM_PATHS`                               | `1`                                             | 文件选择器侧栏钉上常用目录书签，设 `0` 关闭                                                                                        |
| `GTK_BOOKMARKS`                                   | `/root/Downloads=115 下载目录\|/media/nas=NAS 共享目录` | 文件选择器侧栏书签，`\|` 分隔，写法 `路径=显示名`                                                                                       |

## 性能

画面链路是「客户端绘制 → X11 帧缓冲 → Xtigervnc 编码 → websockify 转发 → 浏览器解码」，
前三段都在 NAS 的 CPU 上（容器无 GPU），所以**每帧的编码是主要开销**。默认值已按
「文件管理界面」这个用途调过，一般不用动。仍觉得慢时按序试：

| 旋钮 | 默认 | 调法 |
| --- | --- | --- |
| `NOVNC_COMPRESSION` | `1` | 再降到 `0`（不压缩）。**别调高**——高等级只适合极慢网络，局域网里是纯烧 CPU |
| `VNC_FRAME_RATE` | `25` | 降到 `15`，编码量再减；拖窗口会有轻微残影 |
| `NOVNC_QUALITY` | `5` | 降到 `3`，画质换流畅，文字边缘会糊 |

浏览器地址里也能临时试，不用重启：`http://<主机IP>:6080/vnc.html?autoconnect=1&compression=0`。
先确认瓶颈在哪：`docker stats 115nas --no-stream`，CPU 打满才是上面这些参数的问题；
若 `Xtigervnc` 占用不高却仍卡，那就是网络或浏览器端。

## 公网访问的安全底线

noVNC / websockify 本身**没有账号体系**，谁打开页面谁就能操作你的 115 账号。务必：  
① 设 `VNC_PASSWORD=<强密码>`；② 前置 HTTPS（挂证书走 6081，或在前面套一层）；  
③ 能限 IP 就限 IP，或只走 VPN / Tailscale，不要裸暴露到公网。

## 排障

| 现象                       | 排查                                                                                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 打开 6080 显示「拒绝连接」         | `docker ps -a` 看容器状态；`docker logs 115nas` 看原因                                                                                                          |
| 页面能开、顶部红条「无法连接到服务器」      | 中间那层没转发 WebSocket——容器首页会先探测一次，并把尝试的地址和原因直接写在页面上                                                                                                        |
| 界面一直转圈连不上                | 看 `/logs/entrypoint.log`、`/logs/xvnc.log`、`/logs/websockify.log`                                                                                       |
| 扫码后重启要重新扫码               | `/config`、`/appdata` 没挂卷或被删                                                                                                                            |
| 下载的文件不在 NAS 上            | 客户端设置里下载目录指回 `/root/Downloads`；检查 `NAS_SHARE` 挂载                                                                                                       |
| 设了 `VNC_PASSWORD` 却不弹密码框 | 密码没生效。`docker logs 115nas` 里应有 `password authentication enabled`；**没有就是容器在裸奔**（这种情况新版镜像会直接拒绝启动），重建镜像并确认日志                                              |
| 115 提示登录异常 / 异地登录        | 容器重建后主机标识变了，会被当成新设备。compose 已固定 `hostname`、镜像把 machine-id 存进 `/config`；再查出口 IP 是否走了代理：`docker exec 115nas curl -s --noproxy '*' https://myip.ipip.net` |
| 重启后上传列表里又冒出已完成的任务   | 客户端把传输记录存在 `/appdata` 的本地库里，重启不清空（桌面版也一样）。若是**重复条目或状态错乱**，说明停止容器时客户端被强杀、队列没落盘：新版镜像会等它自己退出，`docker logs 115nas` 里能看到 `Life115 exited cleanly after Ns`。要清空就在客户端里删传输记录 |
| 端口 6080 被占用              | 改 `HTTP_PORT` 并同步 compose 的 ports                                                                                                                      |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名、hostname 与端口）
- 文件选择器里仍能看到容器自己的目录（`/config`、`/appdata` 等），只是常用目录被钉在
  侧栏顶部。标准 GTK3 没有「只显示指定目录」的开关，收干净要动挂载命名空间，不值得

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，  
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
