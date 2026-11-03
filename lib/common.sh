#!/bin/bash
# 115nas 公共定义：日志、路径、环境变量默认值、进程存活判断。
# 被 entrypoint.sh 用 source 引入，不单独执行。

set -u

LOG_DIR=${LOG_DIR:-/logs}

log() {
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line" >> "$LOG_DIR/entrypoint.log"
    echo "[115nas] $*"
}

warn() { log "WARNING: $*"; }
fatal() { log "FATAL: $*"; exit 1; }

# 先建日志目录，下面 UMASK 校验失败要往里写 warn
mkdir -p "$LOG_DIR" 2>/dev/null

# ---------------------------------------------------------------- 文件权限
# 容器以 root 运行（Dockerfile 里没有 USER），所以下载/上传落盘的属主就是
# root，模式由 umask 决定：Docker 默认 0022 → 文件 0644、目录 0755。
# 这在 NAS 上的后果是「别的 uid 只读」：Emby/Jellyfin/Plex 写不了刮削结果，
# 换 uid 运行的下载器搬不动文件，非管理员账号删不掉。
#
# 设 UMASK=000 → 新文件 0666、目录 0777，任何 uid 都能读写。
# 注意它**只改模式，不改属主**：文件仍然属于 root。要「属于某个账号」只能让
# 整个会话降权运行（PUID/PGID），那是另一套机制，这里刻意不做。
# 也只影响**新落盘**的文件，存量文件要 chmod（见 README 排障表）。
#
# 必须在 mkdir / 任何进程启动之前生效：umask 是进程属性，被 fork 出来的
# Xkasmvnc、openbox、fcitx5、Life115 都会继承这一份。
UMASK=${UMASK:-022}
case "$UMASK" in
    # 1~4 位八进制：0 同样合法，等于全放开
    [0-7]|[0-7][0-7]|[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
    *) warn "UMASK=$UMASK 不是合法的八进制掩码，回退为 022"; UMASK=022 ;;
esac
umask "$UMASK"
# 取回生效值（bash 会补成四位，如 0022），日志里报它而不是配置值
UMASK_EFFECTIVE=$(umask)

mkdir -p /config /appdata /cache 2>/dev/null

# ---------------------------------------------------------------- 显示与端口
DISPLAY_NUM=${DISPLAY_NUM:-99}
export DISPLAY=":${DISPLAY_NUM}"

W=${SCREEN_WIDTH:-1280}
H=${SCREEN_HEIGHT:-800}
D=${SCREEN_DEPTH:-24}

VNC_PORT=${VNC_PORT:-5900}
HTTP_PORT=${HTTP_PORT:-6080}

# 以下两项**只对降级路径（Xvfb + x11vnc）生效**。
# KasmVNC 走 websocket 模式，RFB 与 HTTP 共用 HTTP_PORT，没有独立的 5900。
#
# 降级路径上只允许回环：RFB 协议本身没有账号体系（VNC 口令是弱共享口令），
# 暴露到容器外等于任何能连 5900 的人都能操作 115 账号。
VNC_BIND=${VNC_BIND:-127.0.0.1}

# 显示栈选择：
#   auto     = 先 KasmVNC，起不来再降级到 Xvfb+x11vnc（默认）
#   kasmvnc  = 只用 KasmVNC，起不来就失败（排障时用，避免掩盖问题）
#   fallback = 只用 Xvfb+x11vnc（怀疑 KasmVNC 与客户端有冲突时用）
DISPLAY_MODE=${DISPLAY_MODE:-auto}

# ---------------------------------------------------------------- 性能参数
# 帧率上限：服务端每发一帧都要在本机 CPU 上做一次图像编码。
# 文件管理界面用不到 60fps，限帧是这套栈上收益最大的一项。
VNC_FRAME_RATE=${VNC_FRAME_RATE:-25}

# 动态画质区间：KasmVNC 按「这一帧的带宽/延迟反馈」在 [min,max] 之间选
# WebP/JPEG 质量。上限决定静态截图清晰度，下限决定快速滚动时的流畅度。
VNC_QUALITY_MIN=${VNC_QUALITY_MIN:-3}
VNC_QUALITY_MAX=${VNC_QUALITY_MAX:-7}

# WebP 编码耗时预算（毫秒级权重）。值越大越清晰、CPU 越贵。
# 5 是在 NAS 这类弱 CPU 上「肉眼无差别但明显省 CPU」的位置。
VNC_WEBP_TIME=${VNC_WEBP_TIME:-5}

# ---------------------------------------------------------------- 兼容旧变量
# NOVNC_QUALITY / NOVNC_COMPRESSION 属于 1.1.5 及以前的 noVNC 直通参数。
# 1.1.6 换了编码栈，compression 已经没有对应物；quality 映射到动态画质上限，
# 免得老 compose 里的设置静默失效。
if [ -n "${NOVNC_QUALITY:-}" ]; then
    warn "NOVNC_QUALITY 已废弃，改用 VNC_QUALITY_MAX（本次按 NOVNC_QUALITY 生效）"
    VNC_QUALITY_MAX=$NOVNC_QUALITY
fi
if [ -n "${NOVNC_COMPRESSION:-}" ]; then
    warn "NOVNC_COMPRESSION 已废弃：KasmVNC 不用 zlib 等级，该项被忽略"
fi

# ---------------------------------------------------------------- 其它
VNC_PASSWORD=${VNC_PASSWORD:-}
# 与 VNC_PASSWORD 配对使用：这两个是同一个 Basic Auth 账号的用户名和口令。
# 只设口令不设用户名时用下面的默认值，免得启动日志里冒出用户没设过的名字。
VNC_USER=${VNC_USER:-vncuser}
VNC_TLS_CERT=${VNC_TLS_CERT:-/certs/server.pem}
LIFE_STOP_TIMEOUT=${LIFE_STOP_TIMEOUT:-8}
LIFE_PID_FILE=/tmp/115nas-life115.pid
KASM_WWW=${KASM_WWW:-/usr/share/kasmvnc/www}
NOVNC_WEB=/usr/share/novnc

# 运行期 PID 槽位（cleanup 用）
XVNC_PID=""
XVFB_PID=""
X11VNC_PID=""
WS_PID=""
OB_PID=""
LIFE_PID=""
LIFE_SHELL_PID=""
DISPLAY_BACKEND=""

# ---------------------------------------------------------------- 进程存活
# kill -0 对**僵尸进程**同样返回成功（进程已退出、只是还没被 reap）。
# 容器里 PID 1 现在是 tini（会 reap），但降级/无 tini 场景仍可能碰到，
# 所以照样排除 Z 状态，不要改回裸 kill -0。
proc_alive() {
    local p="${1:-}" st=""
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    if [ -r "/proc/$p/stat" ]; then
        st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
        [ "$st" != "Z" ] || return 1
    fi
    return 0
}

# 等一个 TCP 端口可用。$1=host $2=port $3=最大秒数
wait_tcp() {
    local host="$1" port="$2" secs="${3:-15}" i=0
    while [ "$i" -lt $((secs * 5)) ]; do
        (echo > "/dev/tcp/$host/$port") 2>/dev/null && return 0
        sleep 0.2
        i=$((i + 1))
    done
    return 1
}

# 等 HTTP 端口能应答。比只见端口更严格：能连上不等于 web 层真的起来了。
#
# 注意不能只认 2xx：设了 VNC_PASSWORD 时，`/` 可能返回 401/403（要先登录），
# 只认 2xx 会把它误判成「服务没起来」而白白降级到 x11vnc。
# 判据是「有没有 HTTP 应答」——000 表示连 TCP/HTTP 都没通。
http_ready() {
    local port="$1" code
    code=$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null)
    [ -n "$code" ] && [ "$code" != "000" ]
}

wait_http() {
    local port="$1" secs="${2:-20}" i=0
    while [ "$i" -lt $((secs * 2)) ]; do
        http_ready "$port" && return 0
        sleep 0.5
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------- 图形能力
# 为什么要探测：115Life 的界面是 Avalonia(.NET) 自己画的，不是网页。它按
# Glx → Egl → Software 的顺序挑后端（Avalonia.X11.dll 里三种都在）。
#
# 注意别把「有没有库」当成「走哪条路」：镜像里其实有 mesa 的 GL 供应商库
# （libGLX_mesa / libEGL_mesa，作为 libgl1/libegl1 的依赖被带进来，CI 的 diag
# 输出里就能看到），但容器没有 GPU，拿不到可用的硬件 visual 时 Avalonia 照样
# 回落到 Skia 软件渲染。库在只是必要条件，不是充分条件 —— 所以这里只报事实，
# 不替客户端下结论。
#
# 这一步的意义是：界面一卡就会被误判成「KasmVNC 编码太慢」，日志里先留一行，
# 省掉一轮扯皮。GLX 扩展在 X 服务端有没有，与客户端能不能协商出 visual 是两件事，
# 所以下面分开报。
GRAPHICS_EXTS=""
GRAPHICS_GL_VENDOR=""
GRAPHICS_RENDER=""

detect_graphics() {
    GRAPHICS_EXTS=""
    if command -v xdpyinfo >/dev/null 2>&1; then
        GRAPHICS_EXTS=$(xdpyinfo -queryExtensions 2>/dev/null \
                        | awk '/^    [A-Za-z]/{print $1}' | tr '\n' ' ' | sed 's/ *$//')
    fi

    GRAPHICS_GL_VENDOR=""
    for f in libGLX_mesa.so.0 libEGL_mesa.so.0 libGLX_nvidia.so.0; do
        [ -e "/usr/lib/x86_64-linux-gnu/$f" ] && GRAPHICS_GL_VENDOR="$GRAPHICS_GL_VENDOR $f"
    done
    GRAPHICS_GL_VENDOR=${GRAPHICS_GL_VENDOR# }

    if [ -n "$GRAPHICS_GL_VENDOR" ]; then
        # 不要写成「OpenGL」——这只证明库在，不证明用上了。容器没有 GPU 时
        # Avalonia 拿不到硬件 visual，通常仍回落 Skia，而这行会被当成「GL 已生效」。
        GRAPHICS_RENDER="有 GL 库（vendor:$GRAPHICS_GL_VENDOR），实际后端由客户端决定"
    else
        GRAPHICS_RENDER="无 GL 库，客户端只能软件渲染（属预期）"
    fi
}

# 列出当前屏幕上的可见窗口。用来回答「进程在，但画面出来了吗」——
# 这一条比 pgrep 有用得多：客户端渲染后端失败时进程照样活着，只是不画。
list_windows() {
    command -v xwininfo >/dev/null 2>&1 || { echo "    （镜像里没有 xwininfo）"; return 0; }
    local rows
    rows=$(xwininfo -root -children 2>/dev/null | grep -E '^ +0x[0-9a-f]+ ' | head -5)
    if [ -n "$rows" ]; then
        echo "$rows" | sed 's/^ */    /'
    else
        echo "    （没有可见窗口：客户端进程在，但没把窗口画出来）"
    fi
}
