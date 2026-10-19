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
    # - 想锁定版本：把 :latest 改成具体 tag（如 :1.1.0，对应 115Life 37.3.1）
    # - 想本地构建：取消 build: . 的注释，并把 image 改回 115nas-docker:1.1.0
    #build: .   # 本地构建镜像
    image: ghcr.io/xheia/115nas-docker:latest
    container_name: 115nas
    restart: unless-stopped
    shm_size: 1g
    ports:
      - "6080:6080"     # noVNC 页面 + WebSocket（HTTP）
      - "6081:6081"     # HTTPS（仅挂载证书时监听）
      # - "5900:5900"   # 只有「原生 VNC 客户端直连」或「Cloudflare 浏览器渲染 VNC」
      #                 # 才需要；同时要开 VNC_BIND=0.0.0.0 + VNC_PASSWORD，否则容器拒启
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
| `VNC_PASSWORD_AUTOLOGIN` | 空 | 设为 `1` 才把密码写进 URL 自动登录（免输入，但口令会留在地址栏/浏览器历史/反代日志里），默认关闭 |
| `VNC_PORT` | 5900 | VNC 服务端口，仅监听 127.0.0.1，一般不用改 |
| `VNC_BIND` | `127.0.0.1` | VNC 监听地址。设 `0.0.0.0` 才会对外开放 5900（给原生 VNC 客户端或 Cloudflare 浏览器渲染 VNC 用）——**必须先设 `VNC_PASSWORD`，否则容器拒绝启动** |
| `WS_PATH` | `websockify` | noVNC 的 WebSocket 端点。反代改写路径（加前缀）时改这里，如 `115nas/websockify` |
| `WS_VERBOSE` | 空 | 设为任意值后 websockify 打印每个请求，用来确认反代有没有把 WS 握手转进来 |
| `HTTPS_CERT` | `/certs/server.pem` | HTTPS 证书路径 |
| `HIDE_SYSTEM_PATHS` | `1` | 文件选择器里收敛容器内部路径（见下节）。设 `0` 关闭 |
| `GTK_BOOKMARKS` | `/root/Downloads=115 下载目录\|/media/nas=NAS 共享目录` | 钉在文件选择器侧栏顶部的书签，`\|` 分隔，写法 `路径=显示名` |
| `EXTRA_VISIBLE_MOUNTS` | 空 | 额外允许出现在文件选择器卷列表里的挂载点，空格分隔，如 `/share/Download /share/Multimedia` |

## 文件选择器里的路径（隐藏容器内部目录）

选「上传哪个文件 / 下到哪个目录」时，115 客户端弹的是 **GTK3 原生文件选择器**，
默认会把容器自己的文件系统整个摊在你面前：`/config`（登录态）、`/appdata`
（WebKit Cookie）、`/cache`、`/logs` 这些卷，加上 `/bin` `/usr` 等镜像目录，
全都和一两个 NAS 目录混在一起。

容器启动时会自动做两步收敛，不用手动配置：

1. **书签置顶** —— 把 `/root/Downloads`（客户端默认下载目录）和 `/media/nas`
   （上传目录）钉在侧栏顶部，一次点击直达。
   书签写在 `/config/gtk-3.0/bookmarks`，所有 GTK 文件选择器共用，随配置卷持久化。
2. **精简卷列表** —— 「其他位置」里的 `/config` `/appdata` `/cache` `/logs`
   `/etc/resolv.conf` 等条目来自 GIO 读的挂载表。容器会生成一份只保留
   **根 + NAS 目录**的挂载表（`/tmp/115nas-mtab`），用 `LIBMOUNT_MTAB` 指给客户端进程。
   实测典型容器从 16 条挂载收敛到 4 条：

   ```
   overlay / overlay rw,relatime,lowerdir=... 0 0
   /dev/md9 /media/nas     ext4 rw,relatime 0 0
   /dev/md9 /root/Downloads ext4 rw,relatime 0 0
   /dev/md9 /share/Multimedia ext4 rw,relatime 0 0   ← EXTRA_VISIBLE_MOUNTS 加的
   ```

想让别的 NAS 共享目录也出现（比如 `/share/Multimedia` 挂进了容器）：

```yaml
environment:
  - EXTRA_VISIBLE_MOUNTS=/share/Multimedia /share/Download
  - GTK_BOOKMARKS=/root/Downloads=115 下载|/media/nas=NAS 共享|/share/Multimedia=影音
```

生效确认：

```bash
docker logs 115nas | grep "file chooser:"
# 正常会看到：
#   file chooser: 2 bookmark(s) pinned at /config/gtk-3.0/bookmarks
#   file chooser: mount list trimmed 16 -> 4 entries (LIBMOUNT_MTAB=/tmp/115nas-mtab)
```

### 为什么不能「彻底」隐藏

**原生 GTK3 没有「只显示指定目录」的开关。** `show-other-locations`、`show-trash`
这些是 `gtk_places_sidebar_set_*()` 这类**应用侧 API**，不是 `settings.ini`
或 gsettings 能改的配置项；只有 gtk3-classic 之类的第三方补丁集才把它做成
可配置，为此引入非官方包不值得。

所以现实效果是：

- ✅ 侧栏顶部有 NAS 目录的书签，一点即达
- ✅ 「其他位置」里不再出现 `/config` `/appdata` `/cache` `/logs` 等容器内部挂载
- ⚠️ 但**容器根目录（`/`）仍然可达** —— 在路径栏里手动敲 `/` 回车，还是能看到
  `/bin` `/usr` 这些镜像目录。要挡住这一层，得给容器加 `--cap-add SYS_ADMIN`
  后用挂载命名空间把内部目录遮住，或者改用非 root 用户运行客户端
  （`/config` 等属主是 root、权限 700，非 root 就进不去了）。这两条都会显著
  增加部署复杂度，默认不做。

libmount 版本较新（util-linux ≥ 2.39）时第 2 步会失效：`mnt_table_parse_mtab(NULL)`
已硬编码读 `/proc/self/mountinfo`，`LIBMOUNT_MTAB` 被忽略。容器启动时会用
`findmnt` 实测一次，不生效就**自动跳过**（日志里写 `LIBMOUNT_MTAB not honored`），
只保留第 1 步的书签，不会有副作用。

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

## 外网访问（反向代理）

noVNC 是「静态页 + WebSocket」两条通道：页面走 HTTP，画面走 WebSocket。
**反代必须转发 WebSocket 的 `Upgrade` / `Connection` 头**，否则页面能打开、
却顶一条红色「无法连接到服务器」。

> 容器首页现在会**先做一次 WebSocket 探测**：通了才进桌面，不通就直接在页面上
> 写明尝试的地址与原因（还会列出各平台的改法）。看到那张诊断页，就已经知道
> 是「WS 升级被吃掉」而不是别的问题了。想跳过探测直接进：地址后加 `?direct=1`。

noVNC 默认在同域名同端口的 `/websockify` 建 WS 连接（由页面路径决定）。

nginx 最小可用配置（示例：宿主 6088 → 容器 6080）：

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 6088;
    server_name example.com;

    location / {
        proxy_pass http://192.168.1.10:6080;
        proxy_http_version 1.1;

        # 关键两行：少了就是「无法连接到服务器」
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 长连接：关缓冲、放宽空闲超时，否则会话会被反代掐断
        proxy_buffering     off;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
```

### 平台自带反代

| 平台 | 必须做的设置 |
| --- | --- |
| **QNAP / 威联通**（控制台 → 网络和文件服务 → 网络访问 → 反向代理） | 只改一处：**目标协议** `HTTP` → **`HTTP 和 WebSocket`**（源协议保持 `HTTP`，目标仍 `localhost:6080`）。实测该组合下 WS 握手返回 `101`；两端都留纯 `HTTP` 时 `Upgrade` 被吞——页面能开、WS 必失败 |
| **群晖 DSM**（反向代理 → 编辑 → 自定义标题） | 点「**WebSocket**」按钮自动补 `Upgrade` / `Connection` 两条头，并勾选 HTTP/1.1 |
| **Cloudflare**（橙色云 / Tunnel） | 支持 WebSocket，但**只监听固定端口**：HTTPS `443/2053/2083/2087/2096/8443`，HTTP `80/8080/8880/2052/2082/2086/2095`。`6088` 这类端口只能靠 Tunnel（`cloudflared` 指到 `http://<NAS>:6080`，绕过 NAS 上任何 HTTP 反代最稳），或在路由器把上述端口转到 NAS |

> 只改**目标协议**就够了，别把源协议也改成 WebSocket。若你的 QTS 版本里没有
> 「HTTP 和 WebSocket」这个选项，就别跟它较劲：路由器端口直接转发到 `NAS:6080`
> 绕过 QTS 反代，或用 Cloudflare Tunnel 直连 `6080`。

### Cloudflare Zero Trust（Access / Tunnel）

**应用类型要选「自托管（Self-hosted）」，不要选 `VNC` 类型 + 「浏览器渲染」。**

「浏览器渲染」的 VNC/SSH/RDP 是 **Cloudflare 自己当客户端**：它连的是 origin 的
**原始 VNC 端口 5900**，把画面重新编码后推给你——和 noVNC 的「HTTP 页面 + WebSocket」
是两条完全不同的路。用那种配置时，页面虽然能渲染出来，noVNC 的 WS 却永远建不起来
（侧栏只剩「全屏 + 设置」两个按钮就是这个现象）。

自托管应用 = 普通反向代理 + 登录墙，`Upgrade` 头原样透传，noVNC 正常工作。

若改用自托管后仍报 `1006` / 不停重连，查这两处（Proxmox 的 noVNC 也是同样的坑）：

1. **主控制台 → 你的域名 → 网络 → WebSockets** 开关要在 ON（默认 ON，个别账户模板会关）；
2. **cloudflared 的 ingress 加 `http2Origin: false`**——新版 cloudflared 用 HTTP/2 连
   origin 时，WebSocket 升级可能卡死，浏览器收到 1006：

```yaml
ingress:
  - hostname: vnc2.example.com
    service: http://192.168.1.10:6080      # 直接指容器，别经 NAS 上的 HTTP 反代
    originRequest:
      http2Origin: false
  - service: http_status:404
```

> cloudflared 跑在 NAS 宿主机上就填 `http://localhost:6080`；跑在容器里可用
> `network_mode: service:115nas` 共享网络后连 `127.0.0.1:6080`。

**另一种玩法：直接用 Cloudflare 的「浏览器渲染 VNC」**
把 VNC 应用的目标改成 **5900 原始 VNC**（Tunnel 用 `service: tcp://<NAS>:5900`），
容器需要 `VNC_BIND=0.0.0.0` + `VNC_PASSWORD`，compose 里映射 `- "5900:5900"`。
好处是彻底不依赖 noVNC/WS；代价是画面被重新编码（有延迟，看视频不舒服），
剪贴板走 Cloudflare 自己的开关（新建应用默认两个方向都关，要在应用设置里手动打开）。

**30 秒自检**（在局域网另一台机器上执行，A、B 都应返回 `101 Switching Protocols`）：

```bash
WS=(-H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13"
    -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==")

# A. 直连容器
curl -i -N --noproxy '*' "${WS[@]}" http://192.168.1.10:6080/websockify

# B. 走反代
curl -i -N --noproxy '*' "${WS[@]}" http://example.com:6088/websockify
```

> **必须带 `--noproxy '*'`**：如果本机设了 `http_proxy`（公司代理、Clash 的 HTTP 端口、
> Windows 系统代理），curl 会把请求交给代理，而 HTTP 代理自己就会剥掉 `Upgrade` /
> `Connection`，于是**明明服务端正常也会返回 404**——这是个极易误判的假阴性。
> 同理，浏览器若挂了系统代理访问你的反代，WebSocket 也可能被同样的机制掐掉。

| A 直连 | B 反代 | 结论 |
| --- | --- | --- |
| 101 | 101 | 反代没问题，Ctrl+F5 清 noVNC 缓存后重试 |
| 101 | 404 | 反代支持 HTTP 但不转发 WS（`Upgrade` 头被吞）→ 按上面配置补，或改 TCP 端口映射 |
| 101 | 200 / 400 | 反代改写了路径或强制降级到 HTTP/1.0 |
| 101 | 502 / 超时 | 后端不可达：反代指向的 IP:端口 不对，或容器没起 |
| 非 101 | 任意 | 容器侧问题：`docker logs 115nas`、`/logs/websockify.log` |

> 反代改写了路径（如额外加了 `/115nas/` 前缀）时，给容器设
> `WS_PATH=115nas/websockify` 再重启（等价于在 noVNC 地址后加 `&path=...`）。

**反代不支持 WS 时**：任何「HTTP 层」转发都必须显式支持 WebSocket 才能用。若你的
反代属于不支持的类型（部分内网穿透的 http 模式、部分面板的简单反代），改用
**TCP 层映射**（路由器端口转发、frp `type=tcp`、NPS tcp 隧道）直接指向容器 6080，
HTTP 与 WS 一起透传，最省事。

**公网暴露的安全底线**：noVNC / websockify 本身**没有账号体系**，谁打开页面谁就能
操作你的 115 账号。务必：① 设 `VNC_PASSWORD=<强密码>`（连接时需输入）；
② 前置 HTTPS（挂证书到 `/certs/server.pem` 走 6081，或在反代层终结 TLS）；
③ 能限 IP 就限 IP，或只走 VPN / Tailscale，不要裸暴露到公网。

## 排障

| 现象 | 排查 |
| --- | --- |
| 打开 6080 显示「拒绝连接」 | `docker ps -a` 看容器状态；`docker logs 115nas` 看原因；首次启动后镜像还在构建 |
| 页面能开、顶部红条「无法连接到服务器」 | 反代没转发 WebSocket，见「外网访问（反向代理）」自检表 |
| noVNC 侧栏只剩「全屏」「设置」两个按钮 | **不是按钮丢了，是根本没连上**：noVNC 未连接时会整体隐藏剪贴板 / Ctrl / Alt / 断开（`base.css` 的 `:root:not(.noVNC_connected) #noVNC_clipboard_button` 等规则）。按上面的反代章修 WS 即可，按钮会自己回来 |
| 反代后仍连不上，想确认握手到没到容器 | 加 `WS_VERBOSE=1` 重启容器，`docker logs 115nas`：出现 `WebSocket connection` = 握手已到达；只有 `404` 行 = 头被中间层吞了 |
| Cloudflare 里应用设成了 `VNC` + 「浏览器渲染」 | 那是 CF 自己当 VNC 客户端去连 **5900**，不走 noVNC 的 HTTP/WS → 页面能出、画面永远连不上。改回「自托管」应用，或改指 5900 + `VNC_BIND=0.0.0.0`，见「Cloudflare Zero Trust」 |
| 界面一直转圈连不上 | 看容器内 `/logs/entrypoint.log`、`/logs/xvnc.log`、`/logs/websockify.log` |
| 扫码后重启要重新扫码 | `/config`、`/appdata` 没挂卷或被删 |
| 下载的文件不在 NAS 上 | 客户端设置里下载目录指回 `/root/Downloads`；检查 `NAS_SHARE` 挂载 |
| 中文输不进去 | `Ctrl+Space` 呼出 fcitx5；不行就 `Ctrl+V` 粘贴 |
| 设了 `VNC_PASSWORD` 却不弹密码框 | 密码没生效。看 `docker logs 115nas`：应有 `password authentication enabled`；**没有就是容器在裸奔**。新版镜像在这种情形会直接拒绝启动（缺 `tigervnc-tools` 时就退化为无认证）。重建镜像并确认日志 |
| 粘贴/复制中文乱码 | 看日志 `display:` 一行：应为 `tigervnc`；若显示 `x11vnc` 说明 TigerVNC 未装上，重构建镜像 |
| 端口 6080 被占用 | 改 `HTTP_PORT` 并同步 compose 的 ports 映射 |
| 文件选择器里还是一堆 `config` `appdata` `cache` | 看 `docker logs 115nas \| grep "file chooser:"`。出现 `LIBMOUNT_MTAB not honored` = 基础镜像的 libmount ≥ 2.39，卷列表精简不生效（书签仍然生效）；出现 `skip bookmark ... (not mounted)` = 对应目录没挂进去，检查 `NAS_SHARE`。想完全关闭收敛：`HIDE_SYSTEM_PATHS=0` |

## 已知限制

- 视频播放为软件解码（无 GPU 直通），高码率片源可能卡顿
- 官方客户端仅 amd64/x86_64，ARM 主机无法运行（deb 依赖决定）
- 单容器单 115 账号（多开：复制一份 compose，改容器名与端口）
- noVNC 不传输本机输入法——中文靠容器内 fcitx5 或粘贴
- 文件选择器无法彻底隐藏容器根目录 `/`（标准 GTK3 无此开关，见
  [文件选择器里的路径](#文件选择器里的路径隐藏容器内部目录)）

## 版权与许可

- 本项目代码（Dockerfile / entrypoint.sh / compose）：MIT
- `115Life_37.3.1.deb` 版权归 **广东一一五科技股份有限公司** 所有，
  本仓库仅打包其官方 deb 以便离线构建，不修改其内容
