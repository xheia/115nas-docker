# syntax=docker/dockerfile:1
###############################################################################
# 115nas — 115 生活官方 Linux 客户端（Docker 版）
#
# 把官方 115 生活桌面客户端跑进容器，浏览器打开即用：扫码登录、文件管理、
# 上传下载、云下载、在线播放、分享，全功能保留。
#
# 1.1.6 起显示栈换成 KasmVNC：X 服务端 + RFB + HTTP + WebSocket 在同一个进程
# （Xkasmvnc）里完成，替代原来的 Xtigervnc + websockify + noVNC 三件套。
# 少一次进程内转发、编码换成 WebP/JPEG 自适应 + 多线程，CPU 与首屏都更好；
# 它的 Web 客户端本来就是 noVNC 的分支，WebSocket 路径仍是 `websockify`，
# 现有反向代理规则不用改。
#
# 镜像里仍保留 Xvfb + x11vnc + websockify 作为降级路径：KasmVNC 在某些老内核/
# 库组合上起不来时自动切换，代价是画质与中文剪贴板退步。
#
# 基础镜像必须 Debian 12：官方 115Life deb 的 Depends 同时要求
#   libwebkit2gtk-4.1-0 / libgtk-3-0 / libssl3（旧包名）与 libc6>=2.31；
# Ubuntu 22.04 没有 WebKitGTK 4.1，24.04 把后两者改成 t64 后缀，只有 bookworm 全满足。
# KasmVNC 的 bookworm 包要求 libc6>=2.35，bookworm 是 2.36，同样满足。
###############################################################################

# ---- 阶段 1：字体子集 -------------------------------------------------------
# fonts-noto-cjk 装完约 200MB（十个 ttc，每个含四个地区变体）。客户端界面只
# 用到常规和粗体两个字重，其余五个（Thin/Light/DemiLight/Medium/Black）纯占体积
# 且拖慢镜像拉取。这里在临时阶段装完整包，只留需要的两个 ttc 再 COPY 过去，
# 中间层不会留在最终镜像里。
#
# 兜底：万一包内文件名变了（上游改过排布），就整目录搬走——宁可大一点，
# 也不能出现「中文全变方框」这种比慢严重得多的问题。
FROM debian:12-slim AS fonts
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends fonts-noto-cjk; \
    rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    src=/usr/share/fonts/opentype/noto; \
    dst=/fonts-out; \
    mkdir -p "$dst"; \
    for f in NotoSansCJK-Regular.ttc NotoSansCJK-Bold.ttc; do \
        if [ -f "$src/$f" ]; then cp "$src/$f" "$dst/"; fi; \
    done; \
    if [ -z "$(ls -A "$dst")" ]; then \
        echo "WARN: 预期的两个字重没找到，回退为整目录拷贝"; \
        cp -a "$src/." "$dst/"; \
    fi; \
    du -sh "$dst"; ls -l "$dst"

# ---- 阶段 2：运行镜像 -------------------------------------------------------
FROM debian:12-slim

ARG APP_VERSION=1.1.6
ARG CLIENT_VERSION=unknown

LABEL org.opencontainers.image.title="115nas" \
      org.opencontainers.image.description="115 生活 Linux 客户端（Docker + KasmVNC 版）" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.source="https://github.com/xheia/115nas-docker" \
      115nas.version="${APP_VERSION}" \
      115nas.client-version="${CLIENT_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    DISPLAY=:99 \
    APP_DIR=/usr/local/share/115nas \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24 \
    VNC_PORT=5900 \
    HTTP_PORT=6080 \
    # 登录态持久化（据官方 deb 的 prerm 确认的真实路径）：
    #   $XDG_CONFIG_HOME/115Life/   设置与会话
    #   $XDG_DATA_HOME/life115/     种子/播放记录等运行时数据
    #   $XDG_DATA_HOME              WebKit Cookie（扫码登录态就在这，重启不能丢）
    #   $XDG_CACHE_HOME             视频缓存（挂卷后可清理）
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/appdata \
    XDG_CACHE_HOME=/cache \
    # WebKitGTK 在软件渲染下需要关掉合成模式，否则二维码登录页可能白屏
    WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    GDK_BACKEND=x11 \
    GTK_IM_MODULE=fcitx \
    QT_IM_MODULE=fcitx \
    XMODIFIERS=@im=fcitx

# 基础运行环境。分组注释说明每组的必要性，删之前先确认为什么在这里。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        # tini 做 PID 1：reap 孤儿进程 + 正确转发信号（bash 当 PID 1 两样都不会）
        tini ca-certificates curl procps psmisc iproute2 \
        # X 工具：排障（xdpyinfo）与文件选择器依赖
        x11-utils xdotool xclip xauth \
        openbox dbus dbus-x11 \
        # 降级路径（KasmVNC 起不来时用）
        xvfb x11vnc novnc websockify \
        fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 \
        # 115 客户端自身的运行期依赖（deb 也会拉，这里显式列出便于审查）
        libgtk-3-0 libwebkit2gtk-4.1-0 libsecret-1-0 libnotify4 \
        libva2 libva-drm2 fontconfig libfontconfig1 libssl3 \
        desktop-file-utils xdg-utils shared-mime-info \
        libgl1 libegl1 libgles2 libglx0 libglvnd0 libasound2 \
        libxkbcommon0 libxcursor1 libxrandr2 libxi6 libxinerama1; \
    rm -rf /var/lib/apt/lists/*

# ---- KasmVNC ---------------------------------------------------------------
# 从官方 GitHub Release 取 bookworm 包并校验 sha256（版本变了要同时改 sha，
# 避免「悄悄换了一个二进制」）。perl 依赖由 apt-get -f 自动补齐。
ARG KASMVNC_VERSION=1.5.2
ARG KASMVNC_SHA256=5f4bfda43e89178782eac37ae463b1d95d16ac5e45da8b7989ec75404e764993
RUN set -eux; \
    apt-get update; \
    curl -fsSL --retry 3 -m 300 -o /tmp/kasmvnc.deb \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_debian_bookworm_${KASMVNC_VERSION}_amd64.deb"; \
    echo "${KASMVNC_SHA256}  /tmp/kasmvnc.deb" | sha256sum -c -; \
    dpkg -i /tmp/kasmvnc.deb || true; \
    apt-get install -y -f --no-install-recommends; \
    rm -rf /var/lib/apt/lists/* /tmp/kasmvnc.deb; \
    (command -v Xkasmvnc || command -v Xvnc) >/dev/null; \
    test -d /usr/share/kasmvnc/www

# ---- 字体：只留常规 + 粗体 --------------------------------------------------
COPY --from=fonts /fonts-out/ /usr/share/fonts/opentype/noto/

# 字体缓存预热：冷扫描在 NAS 上要好几秒，表现为「窗口出来了但文字迟到」。
# $XDG_CACHE_HOME=/cache 是运行时挂卷、首次为空，所以构建时先算一份放
# /opt/fontconfig-cache，由 entrypoint 首次启动时复制进卷。
#
# 必须显式指定 XDG_CACHE_HOME：上面的 ENV 已把它指向 /cache，
# 不覆盖的话缓存会写进 /cache，而那个目录运行时会被卷盖掉，等于白算。
RUN set -eux; \
    mkdir -p /tmp/fccache; \
    XDG_CACHE_HOME=/tmp/fccache fc-cache -f >/dev/null 2>&1 || true; \
    if [ -d /tmp/fccache/fontconfig ]; then cp -a /tmp/fccache/fontconfig /opt/fontconfig-cache; fi; \
    rm -rf /tmp/fccache

# ---- 官方 115 生活客户端（deb 随仓库分发）-----------------------------------
# 用 --build-arg LIFE_DEB=115Life_<版本>.deb 选择内置哪个客户端版本；
# 默认值等于「本地直接 docker build 时用哪个」。发版时 CI 会把版本号与
# APP_VERSION 一起打进去，二者对应关系见 README「版本」。
ARG LIFE_DEB=115Life_37.3.2.deb
COPY ${LIFE_DEB} /tmp/115life.deb
RUN set -eux; \
    dpkg -i /tmp/115life.deb || true; \
    apt-get update; \
    apt-get install -y -f --no-install-recommends; \
    rm -rf /var/lib/apt/lists/* /tmp/115life.deb; \
    test -x /opt/115life/Life115; \
    test -f /opt/115life/libffcore.so

# ---- 入口与诊断 -------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/115nas-entrypoint.sh
COPY lib/  /usr/local/share/115nas/lib/
COPY web/  /usr/local/share/115nas/
COPY bin/115nas-diag /usr/local/bin/115nas-diag
RUN chmod +x /usr/local/bin/115nas-entrypoint.sh /usr/local/bin/115nas-diag

EXPOSE 6080

# /config  = 客户端配置与登录态（$XDG_CONFIG_HOME，/config/115Life/）
# /appdata = 客户端数据与 WebKit Cookie（扫码登录态所在，重启不能丢）
# /cache   = 视频缓存
# /logs    = 各进程日志
VOLUME ["/config", "/appdata", "/cache", "/logs"]

STOPSIGNAL SIGTERM

# 探的是 Web 层而不只是端口：进程活着但 HTTP 没起来时，用户看到的同样是打不开。
# 判据是「有 HTTP 应答」而不是 200——设了 VNC_PASSWORD 时首页会返回 401，
# 那属于健康状态，不能用 2xx 单一标准把它判成 unhealthy。
#
# 必须写成 shell 形式（CMD 后面直接跟命令，不走 JSON 数组）：方括号 `[ ... ]`
# 一旦紧跟在 CMD 后面，Dockerfile 解析器会先当成 JSON 解析，遇到裸词就报
# "invalid character" 让构建直接失败。加 `sh -c` 后没有歧义，同时保留
# ${HTTP_PORT} 由运行时 shell 展开。
HEALTHCHECK --interval=60s --timeout=5s --start-period=40s --retries=3 \
    CMD sh -c '[ "$(curl -s -m 4 -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/" 2>/dev/null)" != "000" ]'

# tini 做 PID 1，本脚本作为它的子进程跑（这样 cleanup 的 trap 能拿到完整信号）
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/115nas-entrypoint.sh"]
