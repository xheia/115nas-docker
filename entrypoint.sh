#!/bin/bash
###############################################################################
# 115nas 容器入口脚本
#
# 拉起顺序：dbus → Xtigervnc(:99) → openbox → fcitx5(中文输入)
#            → websockify(6080/6081) → Life115
#
# 环境变量（均有默认值，可用 docker -e 覆盖）：
#   SCREEN_WIDTH/HEIGHT/DEPTH  虚拟屏幕（默认 1280x800x24）
#   VNC_PORT                   VNC 监听端口（默认 5900，仅 127.0.0.1）
#   HTTP_PORT / HTTPS_PORT     noVNC 对外端口（默认 6080 / 6081）
#   VNC_PASSWORD               可选；设置后 noVNC 连接需输入密码
#   HTTPS_CERT                 HTTPS 证书（PEM，证书+私钥合一），默认 /certs/server.pem
#
# 日志统一写 /logs/（建议挂卷持久化）：
#   entrypoint.log / xvnc.log / openbox.log / fcitx5.log / x11vnc.log /
#   websockify.log / websockify-ssl.log / life115.log
###############################################################################
set -u

LOG_DIR=/logs
mkdir -p "$LOG_DIR" /config /appdata /cache 2>/dev/null

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_DIR/entrypoint.log"; echo "[115nas] $*"; }

DISPLAY_NUM=99
export DISPLAY=":${DISPLAY_NUM}"
W=${SCREEN_WIDTH:-1280}
H=${SCREEN_HEIGHT:-800}
D=${SCREEN_DEPTH:-24}
VNC_PORT=${VNC_PORT:-5900}
HTTP_PORT=${HTTP_PORT:-6080}
HTTPS_PORT=${HTTPS_PORT:-6081}
VNC_PASSWORD=${VNC_PASSWORD:-}
HTTPS_CERT=${HTTPS_CERT:-/certs/server.pem}
NOVNC_WEB=/usr/share/novnc
VNC_PASS_FILE=/tmp/115nas-vnc.pass
XVNC_PID=""

XVFB_PID=""; OB_PID=""; VNC_PID=""; WS_PID=""; WSS_PID=""; LIFE_PID=""

cleanup() {
    log "entrypoint: received stop signal, shutting down..."
    for P in "$LIFE_PID" "$WSS_PID" "$WS_PID" "$VNC_PID" "$XVNC_PID" "$OB_PID" "$XVFB_PID"; do
        [ -n "$P" ] && kill "$P" 2>/dev/null
    done
    # VNC 密码临时文件
    rm -f "$VNC_PASS_FILE" 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# ---------------------------------------------------------------- 1. dbus
# libsecret（保存登录态）、GTK、WebKit、libnotify 都会用到 dbus。
mkdir -p /run/dbus
dbus-uuidgen --ensure >/dev/null 2>&1
if [ ! -S /run/dbus/system_bus_socket ]; then
    if dbus-daemon --system --fork >"$LOG_DIR/dbus.log" 2>&1; then
        log "dbus system bus started"
    else
        log "WARNING: dbus-daemon --fork failed, retrying with --nofork"
        dbus-daemon --system --nofork >>"$LOG_DIR/dbus.log" 2>&1 &
    fi
else
    log "dbus system bus already running"
fi

# 会话总线（dbus-launch 来自 dbus-x11）：WebKitGTK 的密码保存、GTK 设置、
# fcitx5 都需要。缺失不影响二维码登录（登录态主要靠 WebKit Cookie）。
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)" >/dev/null 2>&1
    export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
    log "dbus session bus: ${DBUS_SESSION_BUS_ADDRESS:-none}"
fi

# ------------------------------------------------- 2. 虚拟屏 + VNC 服务端
# 首选 Xtigervnc（TigerVNC）：虚拟屏与 VNC 服务端二合一，且支持 RFB 的
# Extended Clipboard 伪编码（0xC0A1E5CE），剪贴板按 UTF-8 传输，中文不乱码。
#
# 为什么不再首选 x11vnc：x11vnc 0.9.16 未实现该扩展，noVNC 只能退回标准
# ClientCutText（RFC 6143 §7.5.6，仅 ISO-8859-1），且其实现为
# data[i] = text.charCodeAt(i)，非 Latin-1 字符被截断到低 8 位 → 中文必然乱码。
# （上游 issue LibVNC/x11vnc#77，2020 年至今未解决）
#
# x11vnc + Xvfb 仍保留在镜像中作为回退：若 TigerVNC 起不来，自动降级，
# 保证容器仍然可用（代价是剪贴板退回 Latin-1，日志会明确告警）。
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null

VNC_MODE=""

wait_vnc_port() {
    local i
    for i in $(seq 1 60); do
        (echo > "/dev/tcp/127.0.0.1/$VNC_PORT") 2>/dev/null && return 0
        sleep 0.5
    done
    return 1
}

start_tigervnc() {
    local sec="None" pw=""
    if [ -n "$VNC_PASSWORD" ]; then
        rm -f "$VNC_PASS_FILE"
        # -f = filter mode：stdin 读明文口令，stdout 输出加密后的口令文件
        if printf '%s\n' "$VNC_PASSWORD" | tigervncpasswd -f > "$VNC_PASS_FILE" 2>/dev/null \
           && [ -s "$VNC_PASS_FILE" ]; then
            sec="VncAuth"; pw="-PasswordFile $VNC_PASS_FILE"
            log "VNC password authentication enabled"
        else
            log "WARNING: could not store VNC password, starting without password"
        fi
    fi
    # shellcheck disable=SC2086
    Xtigervnc ":$DISPLAY_NUM" \
        -geometry "${W}x${H}" -depth "$D" \
        -rfbport "$VNC_PORT" \
        -localhost \
        -SecurityTypes "$sec" $pw \
        -AlwaysShared -ac -desktop 115nas \
        >"$LOG_DIR/xvnc.log" 2>&1 &
    XVNC_PID=$!
    if wait_vnc_port; then
        VNC_MODE="tigervnc"
        log "Xtigervnc listening on 127.0.0.1:$VNC_PORT (pid $XVNC_PID)"
        return 0
    fi
    kill "$XVNC_PID" 2>/dev/null
    return 1
}

start_x11vnc() {
    log "WARNING: Xvfb+x11vnc fallback in use; clipboard is ISO-8859-1 (CJK garbles)"
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null
    Xvfb "$DISPLAY" -screen 0 "${W}x${H}x${D}" -ac \
         +extension GLX +extension RANDR +render -noreset \
         >"$LOG_DIR/xvfb.log" 2>&1 &
    XVFB_PID=$!
    local i
    for i in $(seq 1 60); do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
        sleep 0.5
    done
    VNC_ARGS="-display $DISPLAY -rfbport $VNC_PORT -localhost -forever -shared -xkb -quiet -o $LOG_DIR/x11vnc.log"
    if [ -n "$VNC_PASSWORD" ]; then
        if x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASS_FILE" >/dev/null 2>&1; then
            VNC_ARGS="$VNC_ARGS -rfbauth $VNC_PASS_FILE"
            log "x11vnc: password authentication enabled"
        else
            VNC_ARGS="$VNC_ARGS -nopw"
            log "WARNING: could not store VNC password, falling back to no password"
        fi
    else
        VNC_ARGS="$VNC_ARGS -nopw"
    fi
    # shellcheck disable=SC2086
    x11vnc $VNC_ARGS &
    VNC_PID=$!
    if wait_vnc_port; then
        VNC_MODE="x11vnc"
        log "x11vnc listening on 127.0.0.1:$VNC_PORT (pid $VNC_PID)"
        return 0
    fi
    return 1
}

if command -v Xtigervnc >/dev/null 2>&1; then
    start_tigervnc || start_x11vnc
else
    start_x11vnc
fi

if [ -z "$VNC_MODE" ]; then
    log "FATAL: no VNC server could listen on 127.0.0.1:$VNC_PORT; see $LOG_DIR/"
    tail -n 20 "$LOG_DIR/xvnc.log" "$LOG_DIR/xvfb.log" "$LOG_DIR/x11vnc.log" 2>/dev/null
    exit 1
fi
log "display ready (mode=$VNC_MODE, ${W}x${H}x${D})"

# ---------------------------------------------------------------- 3. openbox
# 窗口管理器：客户端需要 WM 才能正常获得焦点/拖动/最大化。
openbox >"$LOG_DIR/openbox.log" 2>&1 &
OB_PID=$!
log "openbox started (pid $OB_PID)"

# ---------------------------------------------------------------- 4. fcitx5 中文输入
# 容器内跑 fcitx5 拼音输入法：noVNC 窗口里按 Ctrl+Space 呼出，拼音候选项
# 显示在虚拟屏上（VNC 可见），数字键选字。失败不影响启动——随时可以用
# 「电脑复制 → Ctrl+V 粘贴」输入中文。
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null
if command -v fcitx5 >/dev/null 2>&1; then
    fcitx5 -d >"$LOG_DIR/fcitx5.log" 2>&1
    sleep 1
    if pgrep -x fcitx5 >/dev/null 2>&1; then
        log "fcitx5 started (Ctrl+Space toggles Chinese input)"
    else
        log "fcitx5 failed to start; use copy-paste (Ctrl+V) for Chinese"
    fi
else
    log "fcitx5 not installed; use copy-paste (Ctrl+V) for Chinese input"
fi

# ---------------------------------------------------------------- 5. websockify
# noVNC 静态页 + WebSocket→RFB 桥。不带 --cert 即纯 HTTP。
websockify --web "$NOVNC_WEB" "$HTTP_PORT" "127.0.0.1:$VNC_PORT" \
    >"$LOG_DIR/websockify.log" 2>&1 &
WS_PID=$!
log "noVNC (HTTP) on :$HTTP_PORT (pid $WS_PID)"

# HTTPS：仅当挂载了证书（把宿主机的 PEM 证书+私钥合一文件放到 /certs/server.pem）。
if [ -f "$HTTPS_CERT" ] \
   && grep -q "BEGIN CERTIFICATE" "$HTTPS_CERT" 2>/dev/null \
   && grep -q "PRIVATE KEY" "$HTTPS_CERT" 2>/dev/null; then
    websockify --web "$NOVNC_WEB" --cert "$HTTPS_CERT" --ssl-only \
        "$HTTPS_PORT" "127.0.0.1:$VNC_PORT" \
        >"$LOG_DIR/websockify-ssl.log" 2>&1 &
    WSS_PID=$!
    log "noVNC (HTTPS) on :$HTTPS_PORT (pid $WSS_PID)"
else
    log "noVNC HTTPS listener skipped (no usable cert at $HTTPS_CERT)"
fi

# ---------------------------------------------------------------- 6. 生成入口页
# noVNC 自带的是 vnc.html；这里生成一个 / 首页，带上自动连接参数。
# 说明：/usr/share/novnc 由 deb 包提供，容器内可写。
gen_index() {
    local extra=""
    [ -n "$VNC_PASSWORD" ] && extra="&password=$(printf '%s' "$VNC_PASSWORD" | sed 's/[&=%]/\\&/g')"
    cat > "$NOVNC_WEB/index.html" <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>115 生活</title>
<style>
  body { margin:0; background:#f5f6f8; color:#333; font-family:"Noto Sans CJK SC","Microsoft YaHei",sans-serif; }
  .tip { padding:10px 14px; font-size:13px; color:#666; }
</style>
<meta http-equiv="refresh" content="0; url=vnc.html?autoconnect=1&resize=scale&quality=6&compression=3&reconnect=1&reconnect_delay=3000&show_dot=1${extra}">
</head>
<body>
<div class="tip">正在进入 115 生活…如长时间停留请 <a href="vnc.html?autoconnect=1&resize=scale&quality=6&compression=3&reconnect=1&reconnect_delay=3000&show_dot=1${extra}">点此重试</a>。</div>
</body>
</html>
EOF
}
gen_index
log "entry page generated at $NOVNC_WEB/index.html"

# ---------------------------------------------------------------- 7. Life115
# 崩溃退出时记录并重启，保持容器可用（日志在 /logs/life115.log）。
log "starting Life115 (/opt/115life/Life115)"
(
    while true; do
        /opt/115life/Life115 >>"$LOG_DIR/life115.log" 2>&1
        RC=$?
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Life115 exited rc=$RC, restart in 3s" >> "$LOG_DIR/life115.log"
        sleep 3
    done
) &
LIFE_PID=$!

log "115nas container is up"
log "  noVNC page : http://<host>:$HTTP_PORT/   (https://<host>:$HTTPS_PORT/)"
log "  VNC target : 127.0.0.1:$VNC_PORT"
log "  display    : $VNC_MODE (tigervnc = UTF-8 clipboard; x11vnc = Latin-1, CJK garbles)"

# ---------------------------------------------------------------- 8. 常驻
# sleep+wait 组合让 trap 能立即响应停止信号。
while true; do
    sleep 3600 &
    wait $! 2>/dev/null
    # 关键进程死亡即让容器退出，由 docker restart 策略接管
    if [ "$VNC_MODE" = "tigervnc" ]; then
        kill -0 "$XVNC_PID" 2>/dev/null || { log "FATAL: Xtigervnc died, container exiting"; exit 1; }
    else
        kill -0 "$XVFB_PID" 2>/dev/null || { log "FATAL: Xvfb died, container exiting"; exit 1; }
        kill -0 "$VNC_PID" 2>/dev/null || { log "FATAL: x11vnc died, container exiting"; exit 1; }
    fi
    kill -0 "$WS_PID"  2>/dev/null || { log "FATAL: websockify died, container exiting"; exit 1; }
done
