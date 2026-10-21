# syntax=docker/dockerfile:1
###############################################################################
# 115nas — 115 生活官方 Linux 客户端（Docker 版）
#
# 把官方 115 生活桌面客户端跑进容器，通过浏览器（noVNC）直接使用：
# 扫码登录、文件浏览/管理、上传、下载、云下载、在线播放、分享，全功能保留。
#
# 进程栈（entrypoint.sh 依次拉起）：
#   dbus → Xtigervnc(:99) → openbox → fcitx5(中文输入) → websockify(6080/6081)
#   → Life115
#
# 显示栈选型：TigerVNC 的 Xtigervnc = 虚拟屏 + VNC 服务端二合一，
# 替代原来的 Xvfb + x11vnc。关键原因：x11vnc 0.9.16 未实现 RFB 的
# Extended Clipboard 伪编码（0xC0A1E5CE，2016 年并入协议主分支），
# 客户端只能退回标准 ClientCutText（RFC 6143 §7.5.6，仅 ISO-8859-1），
# 中文等 Latin-1 外字符会被逐字截断到低 8 位而乱码。
# Xtigervnc 支持该扩展，noVNC 1.2.0+ 亦支持，双方自动协商 UTF-8 传输。
# x11vnc 仍保留在镜像里作为回退（若 TigerVNC 无法启动）。

# 基础镜像选型：debian:12-slim。官方 115Life_37.3.1.deb 的 Depends 同时要求：
#   * libwebkit2gtk-4.1-0（WebKitGTK 4.1 API，登录二维码 WebView 用）
#   * libgtk-3-0 / libssl3（未改名的旧包名）
# Ubuntu 22.04 没有 4.1 版 WebKitGTK；Ubuntu 24.04 把后两者改成 t64 后缀
# （libgtk-3-0t64 / libssl3t64），无法满足 Depends；只有 Debian 12 三者全满足。
###############################################################################
FROM debian:12-slim

LABEL org.opencontainers.image.title="115nas" \
      org.opencontainers.image.description="115 生活 Linux 客户端（Docker + noVNC 版）" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/xheia/115nas-docker"

# 内置 115 客户端版本（CI 通过 --build-arg 传入，docker inspect 可见）
ARG CLIENT_VERSION=unknown
LABEL 115nas.client-version="${CLIENT_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/root \
    DISPLAY=:99 \
    SCREEN_WIDTH=1280 \
    SCREEN_HEIGHT=800 \
    SCREEN_DEPTH=24 \
    VNC_PORT=5900 \
    HTTP_PORT=6080 \
    HTTPS_PORT=6081 \
    # 登录态持久化（据官方 deb prerm 注释确认的真实路径）：
    #   $XDG_CONFIG_HOME/115Life/     设置与会话
    #   $XDG_DATA_HOME/life115/       种子/播放记录等运行时数据
    #   $XDG_DATA_HOME                WebKit Cookie（扫码登录态就在这，重启不能丢）
    #   $XDG_CACHE_HOME               视频缓存（挂卷后可清理）
    XDG_CONFIG_HOME=/config \
    XDG_DATA_HOME=/appdata \
    XDG_CACHE_HOME=/cache \
    # WebKitGTK 在 Xvfb 软件渲染下需要关闭合成模式，否则二维码登录页可能白屏
    WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    GDK_BACKEND=x11 \
    # 中文输入：容器内跑 fcitx5 拼音。noVNC 窗口内按 Ctrl+Space 呼出输入法，
    # 拼音候选直接显示在虚拟屏上（VNC 可见），数字键选字；
    # 任何场景都可以用「电脑复制 → Ctrl+V 粘贴」兜底。
    GTK_IM_MODULE=fcitx \
    QT_IM_MODULE=fcitx \
    XMODIFIERS=@im=fcitx

# 显示栈：优先用 tigervnc-standalone-server 提供的 Xtigervnc（虚拟屏+VNC 二合一，
# 支持 RFB Extended Clipboard → UTF-8 剪贴板，中文不乱码）。
# xvfb + x11vnc 保留作为回退路径（x11vnc 0.9.16 无该扩展，中文会乱码）。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl procps psmisc iproute2 \
      x11-utils xdotool xclip \
      openbox dbus dbus-x11 \
      novnc websockify \
      # tigervnc-tools 提供 tigervncpasswd：少了它 VNC_PASSWORD 会静默失效
      #（服务端退化成 SecurityTypes=None，等于公网裸奔），别删
      tigervnc-standalone-server tigervnc-tools xvfb x11vnc \
      fcitx5 fcitx5-chinese-addons fcitx5-frontend-gtk3 \
      libgtk-3-0 libwebkit2gtk-4.1-0 libsecret-1-0 libnotify4 \
      libva2 libva-drm2 fontconfig libfontconfig1 libssl3 \
      desktop-file-utils xdg-utils shared-mime-info \
      fonts-noto-cjk \
      libgl1 libegl1 libgles2 libglx0 libglvnd0 libasound2 \
      libxkbcommon0 libxcursor1 libxrandr2 libxi6 libxinerama1 \
 && rm -rf /var/lib/apt/lists/*

# 字体缓存预热：Noto CJK 是十个字体文件、约 200MB，fc-cache 冷扫描在 NAS 这类
# CPU 上要好几秒，表现为「窗口出来了但文字迟到」。而 $XDG_CACHE_HOME=/cache
# 是运行时挂卷、首次启动为空，缓存放不到那里去。所以构建时先算好一份存在
# /opt/fontconfig-cache，由 entrypoint 在首次启动时复制到卷里。
#
# 注意必须显式指定 XDG_CACHE_HOME：上面的 ENV 已把它设成 /cache，fontconfig
# 会照着这个变量写缓存，不覆盖的话缓存会落在 /cache 而这个目录运行时被卷盖掉。
# 全过程容错：fc-cache 失败也不该让构建挂掉，entrypoint 里同样会跳过。
RUN mkdir -p /tmp/fccache; \
    XDG_CACHE_HOME=/tmp/fccache fc-cache -f >/dev/null 2>&1; \
    [ -d /tmp/fccache/fontconfig ] && cp -a /tmp/fccache/fontconfig /opt/fontconfig-cache; \
    rm -rf /tmp/fccache

# ---- 官方 115 生活客户端（deb 随仓库分发，构建时 COPY 进来）-----------------
# 不依赖 115 官网在构建期可用；版本升级只需替换 deb 并改 VERSION。
ARG LIFE_DEB=115Life_37.3.1.deb
COPY ${LIFE_DEB} /tmp/115life.deb
RUN dpkg -i /tmp/115life.deb \
 && apt-get update \
 && apt-get install -y -f --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* /tmp/115life.deb \
 && test -x /opt/115life/Life115 \
 && test -f /opt/115life/libffcore.so

COPY entrypoint.sh /usr/local/bin/115nas-entrypoint.sh
RUN chmod +x /usr/local/bin/115nas-entrypoint.sh

# 6080 = noVNC 页面 + WebSocket（HTTP）
# 6081 = 同上（HTTPS，仅在挂载了 /certs/server.pem 时监听）
EXPOSE 6080 6081

# /config  = 客户端配置与登录态（$XDG_CONFIG_HOME，/config/115Life/）
# /appdata = 客户端数据与 WebKit Cookie（$XDG_DATA_HOME，扫码登录态所在，重启不能丢）
# /cache   = 视频缓存（$XDG_CACHE_HOME）
# /media/nas 与 /root/Downloads 由 compose/run 挂载（NAS 共享目录）
VOLUME ["/config", "/appdata", "/cache", "/logs"]

ENTRYPOINT ["/usr/local/bin/115nas-entrypoint.sh"]
