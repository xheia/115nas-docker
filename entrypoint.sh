#!/bin/bash
###############################################################################
# 115nas 容器入口（1.1.6 重构版）
#
# 进程栈：
#   tini(PID 1) → 本脚本 → Xkasmvnc(X 服务端 + RFB + HTTP + WebSocket 同一进程)
#                          → openbox → fcitx5 → Life115
#   KasmVNC 起不来时降级：Xvfb + x11vnc + websockify(noVNC)
#
# 与 1.1.5 的区别（为什么重构）：
#   1. 三个进程合一 —— 少一次 websockify 转发、少两处需要守活的 pid。
#   2. 编码换成 WebP/JPEG 自适应 + 多线程，比 noVNC 的固定 Tight 画质省 CPU。
#   3. 入口不再做「先探测一次 WS 再进客户端」的双握手，首页就是客户端本体；
#      需要排障时开 /diag.html（静态页，不走启动路径）。
#   4. 启动并行化 + 去掉 fcitx5 的 sleep 1，首屏更快。
#   5. tini 做 PID 1，孤儿进程有人 reap，停止时信号也能正确分发。
#
# 环境变量（均有默认值）：
#   SCREEN_WIDTH/HEIGHT/DEPTH  虚拟屏（默认 1280x800x24）
#   HTTP_PORT                  Web + WebSocket 端口（默认 6080）
#   VNC_PORT                   RFB 端口（默认 5900，只绑回环）
#   VNC_BIND                   RFB 绑定地址（默认 127.0.0.1；改 0.0.0.0 必须配口令）
#   VNC_PASSWORD               可选；设置后浏览器里会出现登录框
#   VNC_FRAME_RATE             帧率上限（默认 25；0 = 不限）
#   VNC_QUALITY_MIN/MAX        动态画质区间（默认 3 / 7）
#   VNC_WEBP_TIME              WebP 编码耗时预算（默认 5，越大越清晰越费 CPU）
#   VNC_TLS_CERT               可选；挂载 PEM（证书+私钥合一）后端口改走 HTTPS/WSS
#   DISPLAY_MODE               auto | kasmvnc | fallback（默认 auto）
#   HIDE_SYSTEM_PATHS          默认 1：文件选择器侧栏钉常用目录书签
#   GTK_BOOKMARKS              书签列表，| 分隔，路径=显示名
#   LIFE_STOP_TIMEOUT          停止容器时等客户端自己退出的秒数（默认 8）
#   UMASK                      新落盘文件的权限掩码（默认 022；000 = 任何 uid 可读写）
#
# 日志：/logs/entrypoint.log（总）、xkasmvnc.log、openbox.log、fcitx5.log、
#       life115.log、websockify.log（仅降级模式）、xvfb.log / x11vnc.log
###############################################################################
set -u

APP_DIR=${APP_DIR:-/usr/local/share/115nas}
# shellcheck source=/dev/null
. "$APP_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$APP_DIR/lib/display.sh"
# shellcheck source=/dev/null
. "$APP_DIR/lib/desktop.sh"
# shellcheck source=/dev/null
. "$APP_DIR/lib/diag.sh"

T0=$(date +%s%3N 2>/dev/null || echo 0)
since() {
    local now; now=$(date +%s%3N 2>/dev/null || echo 0)
    [ "$T0" = "0" ] && { echo "?"; return; }
    echo "$((now - T0))"
}

cleanup() {
    log "收到停止信号，开始退出..."

    # ① 先掐掉重启循环，否则下面停掉客户端它立刻又拉起来。
    if proc_alive "$LIFE_PID"; then
        kill -TERM "$LIFE_PID" 2>/dev/null
        sleep 1   # bash 等前台子进程时会把信号压后处理，补一刀 KILL 兜底
        kill -KILL "$LIFE_PID" 2>/dev/null
    fi

    # ② 让 Life115 自己退出。它退出时会把传输队列和任务状态写回 /appdata 的
    #    本地库；直接 SIGKILL 会让列表停在旧快照，重启后已完成的任务又冒出来。
    local lp="" i=0
    [ -f "$LIFE_PID_FILE" ] && lp=$(cat "$LIFE_PID_FILE" 2>/dev/null || true)
    if proc_alive "$lp"; then
        log "请 Life115(pid $lp) 退出，最多等 ${LIFE_STOP_TIMEOUT}s"
        kill -TERM "$lp" 2>/dev/null
        while [ "$i" -lt "$LIFE_STOP_TIMEOUT" ] && proc_alive "$lp"; do
            sleep 1
            i=$((i + 1))
        done
        if proc_alive "$lp"; then
            warn "Life115 在 ${LIFE_STOP_TIMEOUT}s 内没退出，强行杀掉（传输状态可能没落盘）"
            kill -KILL "$lp" 2>/dev/null
        else
            log "Life115 已自行退出（用时 ${i}s，传输状态已落盘）"
        fi
    fi

    # ③ 其余进程没有状态要落盘，直接 TERM
    local p
    for p in "$WS_PID" "$X11VNC_PID" "$XVNC_PID" "$XVFB_PID" "$OB_PID"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    pkill -x fcitx5 2>/dev/null
    rm -f /tmp/115nas-rfb.pass /tmp/115nas-tls-cert.pem /tmp/115nas-tls-key.pem 2>/dev/null
    exit 0
}
trap cleanup TERM INT

# ------------------------------------------------- 0. 设备标识持久化（账号风控）
# 115 客户端会采集主机标识。容器里两处每次重建都会变：/etc/machine-id（写在
# overlay 层）和 hostname（compose 不写 hostname: 时就是容器 ID）。而镜像跟着
# 官方客户端更新，一重建设备标识就变，在 115 侧看就是「又来了一台新设备在新环境
# 登录」，足以触发异地登录风控。首份 machine-id 落到 /config 卷，之后每次恢复。
persist_machine_id() {
    local store=/config/machine-id
    mkdir -p /config 2>/dev/null
    if [ -s "$store" ]; then
        if cp -f "$store" /etc/machine-id 2>/dev/null; then
            log "machine-id 已从卷恢复（$(cut -c1-8 "$store")...），重建容器不改身份"
        else
            warn "/etc/machine-id 不可写，重建容器会导致设备标识漂移"
        fi
        return
    fi
    if [ ! -s /etc/machine-id ]; then
        { dbus-uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-'; } \
            > /etc/machine-id 2>/dev/null
    fi
    # 必须拿到非空值才落盘，否则会存一个空文件，下次启动误判成「已持久化」
    if [ -s /etc/machine-id ] && cp -f /etc/machine-id "$store" 2>/dev/null; then
        log "machine-id 已播种到卷（$(cut -c1-8 "$store")...）"
    else
        warn "machine-id 落盘失败，检查 /config 卷"
    fi
}
persist_machine_id

# ---------------------------------------------------------------- 1. dbus
# libsecret、GTK、WebKit、libnotify 都要用。
#
# 判活看进程而不是 socket：/run 在 debian-slim 里是 overlay 上的普通目录
# （Docker 不给它挂 tmpfs），docker restart 会保留上次留下的
# /run/dbus/system_bus_socket 死文件，用 -S 判活会误判「已在运行」而根本不启动。
mkdir -p /run/dbus
dbus-uuidgen --ensure >/dev/null 2>&1
if pgrep -x dbus-daemon >/dev/null 2>&1; then
    log "dbus system bus 已在运行"
else
    rm -f /run/dbus/system_bus_socket 2>/dev/null
    if dbus-daemon --system --fork >"$LOG_DIR/dbus.log" 2>&1; then
        log "dbus system bus 已启动"
    else
        warn "dbus-daemon --fork 失败，改用 --nofork"
        dbus-daemon --system --nofork >>"$LOG_DIR/dbus.log" 2>&1 &
    fi
fi

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)" >/dev/null 2>&1
    export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
    log "dbus session bus 已就绪"
fi

# ------------------------------------------------- 2. 显示栈 + 3. 桌面会话
start_display
log "显示栈已就绪（backend=$DISPLAY_BACKEND，${W}x${H}x${D}），用时 $(since)ms"

# 先把「这台机器的图形能力」记进日志。115Life 是 Avalonia 自己画的界面，
# 拿不到 GL 就走软件渲染——这属于预期，但必须留痕，否则界面一卡就会被
# 当成 VNC 编码太慢，白折腾编码参数。
detect_graphics
log "图形能力 : ${GRAPHICS_RENDER}"

start_wm
seed_font_cache
start_ime
setup_bookmarks
install_diag_page
log "桌面会话准备完毕，用时 $(since)ms"

# ---------------------------------------------------------------- 4. Life115
# 崩溃重启循环。真实 PID 写到 $LIFE_PID_FILE：外层循环的 PID 不是客户端本身，
# 停止容器时要停的是客户端（它才有状态要落盘）。
log "启动 115 生活客户端（/opt/115life/Life115）"
rm -f "$LIFE_PID_FILE"
(
    while true; do
        /opt/115life/Life115 >>"$LOG_DIR/life115.log" 2>&1 &
        child=$!
        echo "$child" > "$LIFE_PID_FILE"
        wait "$child"
        rc=$?
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Life115 退出 rc=$rc，3s 后重启" >> "$LOG_DIR/life115.log"
        sleep 3
    done
) &
LIFE_PID=$!

log "115nas 已启动，总用时 $(since)ms"
log "  访问地址 : http://<host>:$HTTP_PORT/   （诊断页 /diag.html）"
log "  显示后端 : $DISPLAY_BACKEND（kasmvnc = UTF-8 剪贴板 + 自适应编码；x11vnc = 降级）"
log "  图形库   : ${GRAPHICS_RENDER}"
log "  性能参数 : ${VNC_FRAME_RATE}fps，画质 ${VNC_QUALITY_MIN}-${VNC_QUALITY_MAX}，webp ${VNC_WEBP_TIME}ms"
if [ "$UMASK_EFFECTIVE" = "0022" ]; then
    log "  文件权限 : umask $UMASK_EFFECTIVE（新文件 644、目录 755，属主 root，其他 uid 只读）"
    log "             别的账号/套件需要写这些文件时设 UMASK=000（只影响新落盘的）"
else
    log "  文件权限 : umask $UMASK_EFFECTIVE（属主仍是 root；已下载的旧文件要 chmod）"
fi

# ---------------------------------------------------------------- 5. 常驻
# 客户端起来后确认「窗口真的画出来了」。渲染后端协商失败时进程照样活着，
# 只是不出画面——只看 pgrep 会把这种情况判成正常，然后用户看到的就是白屏。
# 判据取窗口尺寸 >= 三位数：openbox 自己那个 1x1 的选窗窗口不算。
(
    i=0
    while [ "$i" -lt 20 ]; do
        sleep 1
        if xwininfo -root -children 2>/dev/null \
             | grep -E '^ +0x[0-9a-f]+ ' | grep -qE '[0-9]{3,4}x[0-9]{3,4}\+'; then
            log "客户端窗口已创建（用时 $(since)ms）"
            exit 0
        fi
        i=$((i + 1))
    done
    warn "20s 内没看到可见窗口：进程可能起来了但没画出界面，看 /logs/life115.log"
) &

# sleep+wait 让 trap 能立刻响应停止信号；顺带每分钟体检一次。
while true; do
    sleep 60 &
    wait $! 2>/dev/null
    health_check || exit 1
done
