#!/bin/bash
###############################################################################
# 115nas 容器入口脚本
#
# 拉起顺序：dbus → Xtigervnc(:99) → openbox → fcitx5(中文输入)
#            → websockify(6080/6081) → Life115
#
# 环境变量（均有默认值，可用 docker -e 覆盖）：
#   SCREEN_WIDTH/HEIGHT/DEPTH  虚拟屏幕（默认 1280x800x24）
#   VNC_PORT                   VNC 监听端口（默认 5900）
#   VNC_BIND                   VNC 监听地址（默认 127.0.0.1，只允许容器内 noVNC 连接）。
#                              设为 0.0.0.0 才会对外暴露 5900——仅用于「Cloudflare
#                              浏览器渲染 VNC」或原生 VNC 客户端直连，必须同时设密码
#   HTTP_PORT / HTTPS_PORT     noVNC 对外端口（默认 6080 / 6081）
#   VNC_PASSWORD               可选；设置后 noVNC 连接需输入密码
#   HTTPS_CERT                 HTTPS 证书（PEM，证书+私钥合一），默认 /certs/server.pem
#   WS_PATH                    可选；反代改写路径时指定 noVNC 的 WebSocket 端点
#                              （如 115nas/websockify），默认 websockify
#   WS_VERBOSE                 可选；非空则 websockify 打印每个请求（排查反代用）
#   HIDE_SYSTEM_PATHS          默认 1：文件选择器里隐藏容器内部路径（见第 6.5 节）
#   GTK_BOOKMARKS              默认 "/root/Downloads=115 下载目录|/media/nas=NAS 共享目录"
#                              钉在文件选择器侧栏顶部的书签，| 分隔，路径=显示名
#   EXTRA_VISIBLE_MOUNTS       默认空；额外允许出现在文件选择器卷列表里的挂载点，
#                              空格分隔（如 "/share/Download /share/Multimedia"）
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
# 只允许回环：VNC 协议本身没有账号体系（RFB 密码只是弱共享口令），
# 暴露到容器外就意味着任何能连到 5900 的人都能操作 115 账号。
VNC_BIND=${VNC_BIND:-127.0.0.1}
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

# VNC 绑定地址：默认只监听回环（noVNC 从 127.0.0.1 连进来就够了）。
# 只有显式 VNC_BIND=0.0.0.0 才放开，并且强制要求密码——RFB 口令是弱共享口令、
# 可被暴力破解，裸暴露 5900 等于把 115 账号交给扫端口的机器人。
LOCAL_FLAG="-localhost"
if [ "$VNC_BIND" != "127.0.0.1" ]; then
    if [ -z "$VNC_PASSWORD" ]; then
        log "FATAL: VNC_BIND=$VNC_BIND 会把 VNC($VNC_PORT) 暴露到容器外，但 VNC_PASSWORD 为空。"
        log "       无密码的 VNC = 谁连上谁就能操作你的 115 账号。请先设置 VNC_PASSWORD 再重启。"
        exit 1
    fi
    LOCAL_FLAG=""
    log "WARNING: VNC bound to $VNC_BIND (reachable outside the container); keep it behind a tunnel/VPN"
fi

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
        # tigervncpasswd 来自 tigervnc-tools，缺了它整个认证就没了——此时必须
        # 拒绝启动，而不是“降级为无密码”：那样等于把 115 账号裸挂到公网上，
        # 而用户从界面上看不出任何区别（这正是踩过的坑）。
        if command -v tigervncpasswd >/dev/null 2>&1 \
           && printf '%s\n' "$VNC_PASSWORD" | tigervncpasswd -f > "$VNC_PASS_FILE" 2>/dev/null \
           && [ -s "$VNC_PASS_FILE" ]; then
            sec="VncAuth"; pw="-PasswordFile $VNC_PASS_FILE"
            log "VNC password authentication enabled (RFB VncAuth)"
        else
            log "FATAL: VNC_PASSWORD is set but the password could not be stored"
            log "       (tigervncpasswd missing or failed). Refusing to start without"
            log "       authentication, because the UI would look identical while the"
            log "       session is actually open to anyone. Check: tigervncpasswd in PATH?"
            exit 1
        fi
    else
        log "WARNING: no VNC_PASSWORD - the VNC session is unauthenticated"
    fi
    # shellcheck disable=SC2086
    Xtigervnc ":$DISPLAY_NUM" \
        -geometry "${W}x${H}" -depth "$D" \
        -rfbport "$VNC_PORT" \
        $LOCAL_FLAG \
        -SecurityTypes "$sec" $pw \
        -AlwaysShared -ac -desktop 115nas \
        >"$LOG_DIR/xvnc.log" 2>&1 &
    XVNC_PID=$!
    if wait_vnc_port; then
        VNC_MODE="tigervnc"
        log "Xtigervnc listening on $VNC_BIND:$VNC_PORT (pid $XVNC_PID)"
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
    VNC_ARGS="-display $DISPLAY -rfbport $VNC_PORT $LOCAL_FLAG -forever -shared -xkb -quiet -o $LOG_DIR/x11vnc.log"
    if [ -n "$VNC_PASSWORD" ]; then
        if x11vnc -storepasswd "$VNC_PASSWORD" "$VNC_PASS_FILE" >/dev/null 2>&1; then
            VNC_ARGS="$VNC_ARGS -rfbauth $VNC_PASS_FILE"
            log "x11vnc: password authentication enabled"
        else
            log "FATAL: VNC_PASSWORD is set but x11vnc -storepasswd failed; refusing to"
            log "       start unauthenticated (see the tigervnc branch for the rationale)"
            exit 1
        fi
    else
        VNC_ARGS="$VNC_ARGS -nopw"
        log "WARNING: no VNC_PASSWORD - the VNC session is unauthenticated"
    fi
    # shellcheck disable=SC2086
    x11vnc $VNC_ARGS &
    VNC_PID=$!
    if wait_vnc_port; then
        VNC_MODE="x11vnc"
        log "x11vnc listening on $VNC_BIND:$VNC_PORT (pid $VNC_PID)"
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
#
# --heartbeat：定期向客户端发 ping。放在反向代理后面时，很多反代会按空闲时间
# 掐断 WebSocket（nginx 默认 60s read timeout），表现为画面用着用着突然
#「无法连接到服务器」。部分老版本 websockify 没有该参数，先探测再启用。
WS_EXTRA=""
if websockify --help 2>&1 | grep -q -- "--heartbeat"; then
    WS_EXTRA="--heartbeat 30"
fi
# WS_VERBOSE=1：把每个 HTTP 请求/WebSocket 连接打进容器日志。排查反代是否把
# 握手转发进来时很有用：看到 "GET /websockify ... 404" 说明 Upgrade 头被中间层
# 丢了；看到 "WebSocket connection" 说明握手已到容器，问题在别处。
if [ -n "${WS_VERBOSE:-}" ]; then
    WS_EXTRA="$WS_EXTRA --verbose"
fi
# shellcheck disable=SC2086
websockify --web "$NOVNC_WEB" $WS_EXTRA "$HTTP_PORT" "127.0.0.1:$VNC_PORT" \
    >"$LOG_DIR/websockify.log" 2>&1 &
WS_PID=$!
log "noVNC (HTTP) on :$HTTP_PORT (pid $WS_PID)${WS_EXTRA:+, args:$WS_EXTRA}"

# HTTPS：仅当挂载了证书（把宿主机的 PEM 证书+私钥合一文件放到 /certs/server.pem）。
if [ -f "$HTTPS_CERT" ] \
   && grep -q "BEGIN CERTIFICATE" "$HTTPS_CERT" 2>/dev/null \
   && grep -q "PRIVATE KEY" "$HTTPS_CERT" 2>/dev/null; then
    # shellcheck disable=SC2086
    websockify --web "$NOVNC_WEB" $WS_EXTRA --cert "$HTTPS_CERT" --ssl-only \
        "$HTTPS_PORT" "127.0.0.1:$VNC_PORT" \
        >"$LOG_DIR/websockify-ssl.log" 2>&1 &
    WSS_PID=$!
    log "noVNC (HTTPS) on :$HTTPS_PORT (pid $WSS_PID)"
else
    log "noVNC HTTPS listener skipped (no usable cert at $HTTPS_CERT)"
fi

# ---------------------------------------------------------------- 6. 生成入口页
# 生成的 / 首页做两件事：
#   ① 用一次真实的 WebSocket 握手做探测——通了才跳 noVNC，不通就直接列出原因；
#   ② 带上自动连接参数跳 vnc.html。
#
# 为什么值得先探测：noVNC 未连接时会把剪贴板、Ctrl/Alt、断开等按钮**整体隐藏**
# （app/styles/base.css 的 :root:not(.noVNC_connected) #noVNC_clipboard_button 等规则），
# 侧栏只剩「全屏 + 设置」两个按钮。这种画面极易被误判成「按钮丢了」，
# 实际含义是「这个会话根本没有连上」——先探测就能把这句话直接说出来。
#
# WS_PATH：反代改写了路径（例如额外加了 /115nas/ 前缀）时用它指定 noVNC 的 WS 端点。
gen_index() {
    local qs="autoconnect=1&resize=scale&quality=6&compression=3&reconnect=1&reconnect_delay=3000&show_dot=1"

    # 默认**不**把密码写进 URL：地址栏、浏览器历史、反代访问日志都会留下它。
    # 不带 password 参数时，noVNC 收到 RFB 的 credentialsrequired 会自己弹密码框
    # （ui.js 里 sendCredentials 那段），安全得多，只多一次输入。
    # 想免输密码自动登录：设 VNC_PASSWORD_AUTOLOGIN=1，代价是口令出现在 URL 里。
    local auto_pw=""
    if [ -n "${VNC_PASSWORD_AUTOLOGIN:-}" ] && [ -n "$VNC_PASSWORD" ]; then
        auto_pw="$VNC_PASSWORD"
    fi

    cat > "$NOVNC_WEB/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>115 生活</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         background:#f5f6f8; color:#1f2328; padding:20px;
         font-family:"Noto Sans CJK SC","Microsoft YaHei",system-ui,sans-serif; }
  .card { width:min(94vw,700px); background:#fff; border:1px solid #e3e6ea; border-radius:12px;
          padding:22px 24px; box-shadow:0 6px 24px rgba(0,0,0,.06); }
  h1 { margin:0 0 2px; font-size:18px; }
  .sub { margin:0 0 16px; font-size:12px; color:#8a9199; }
  p { margin:10px 0; font-size:14px; line-height:1.6; }
  #msg { font-weight:600; }
  .mono { font-family:ui-monospace,Consolas,monospace; font-size:12px; color:#57606a;
          background:#f6f8fa; border:1px solid #eaeef2; border-radius:6px; padding:8px 10px;
          word-break:break-all; font-weight:400; }
  .bad { color:#b42318; }
  .ok { color:#0f7b0f; }
  button { font:inherit; font-size:13px; padding:7px 14px; margin:10px 8px 0 0; cursor:pointer;
           border:1px solid #d0d7de; border-radius:8px; background:#f6f8fa; }
  button.primary { background:#0969da; border-color:#0969da; color:#fff; }
  .hide { display:none; }
  ul { margin:14px 0 0; padding-left:20px; font-size:13px; line-height:1.8; color:#3b4249; }
  li { margin-bottom:7px; }
  code { font-family:ui-monospace,Consolas,monospace; font-size:12px; background:#f6f8fa;
         border:1px solid #eaeef2; border-radius:4px; padding:1px 5px; color:#0a3069; }
</style>
</head>
<body>
<div class="card">
  <h1>115 生活</h1>
  <p class="sub">先确认到 VNC 的 WebSocket 通道，再进入桌面</p>
  <p id="msg">检测中…</p>
  <p id="url" class="mono"></p>
  <div id="actions" class="hide">
    <button class="primary" onclick="location.reload()">重新检测</button>
    <button onclick="location.replace('vnc.html?' + QS)">仍然进入 noVNC</button>
  </div>
  <ul id="hints" class="hide">
    <li>能看到这个页面 = <b>HTTP 转发是通的</b>，卡住的只是 WebSocket 升级这一段。</li>
    <li><b>nginx</b>：需要 <code>proxy_http_version 1.1;</code>
        <code>proxy_set_header Upgrade $http_upgrade;</code>
        <code>proxy_set_header Connection $connection_upgrade;</code>
        （配合 <code>map $http_upgrade $connection_upgrade</code>），并关闭 <code>proxy_buffering</code>。</li>
    <li><b>QNAP / 威联通「反向代理」</b>：把<b>目标协议</b>从 <code>HTTP</code> 改成
        <b>HTTP 和 WebSocket</b>（源协议保持 <code>HTTP</code>，目标仍 <code>localhost:6080</code>）。
        实测这个组合下握手返回 101；两端都留纯 <code>HTTP</code> 时 Upgrade 会被吃掉，
        正好产生现在这个现象。</li>
    <li><b>群晖 DSM</b>：反向代理 → 编辑 → 自定义标题 → 点「WebSocket」按钮自动补两条头。</li>
    <li><b>Cloudflare</b>：橙色云支持 WebSocket，但只监听固定端口（HTTPS 443 / 2053 / 2083 /
        2087 / 2096 / 8443）；6088 这类端口必须靠 Tunnel 映射，或路由器把 443 转到 NAS。</li>
    <li><b>路径被改写</b>：反代若加了前缀（如 <code>/115nas/</code>），给容器设
        <code>WS_PATH=115nas/websockify</code> 后重启。</li>
    <li><b>命令行自检</b>：<code>curl -i -N --noproxy '*' -H "Connection: Upgrade"
        -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13"
        -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" &lt;本页地址&gt;websockify</code>
        必须返回 <code>HTTP/1.1 101</code>；返回 404 就是升级头被中间层剥掉了。
        <code>--noproxy '*'</code> 不能省，否则本机代理会吃掉升级头，出现假阴性。</li>
    <li>实在绕不过去：改用 <b>TCP 层映射</b>（路由器端口转发 / frp <code>type=tcp</code>）
        直接指向容器 6080，HTTP 与 WS 一起透传。</li>
  </ul>
</div>
<script>
var QS = "__QS__";
var WSPATH = "__WSPATH__";

(function () {
    if (/[?&]direct=1/.test(location.search)) { location.replace('vnc.html?' + QS); return; }

    var msg   = document.getElementById('msg');
    var urlEl = document.getElementById('url');
    var acts  = document.getElementById('actions');
    var hints = document.getElementById('hints');

    var base = location.href.split('#')[0].split('?')[0].replace(/[^/]*$/, '');
    var rel  = (WSPATH || 'websockify').replace(/^\/+/, '');
    var wsUrl;
    try { wsUrl = new URL(rel, base).href.replace(/^http/, 'ws'); }
    catch (e) { wsUrl = base + rel; }
    urlEl.textContent = wsUrl;

    var settled = false;
    function finish(ok, reason) {
        if (settled) return;
        settled = true;
        if (ok) {
            msg.className = 'ok';
            msg.textContent = '连接正常，正在进入…';
            setTimeout(function () { location.replace('vnc.html?' + QS); }, 300);
            return;
        }
        msg.className = 'bad';
        msg.textContent = '无法建立 WebSocket 连接：' + reason;
        acts.className  = '';
        hints.className = '';
    }

    var ws, timer;
    try { ws = new WebSocket(wsUrl); }
    catch (e) { finish(false, '地址无法建立连接（' + e.message + '）'); return; }

    timer = setTimeout(function () {
        finish(false, '15 秒内没有完成握手（超时：代理未转发，或后端不可达）');
        try { ws.close(); } catch (e) {}
    }, 15000);

    ws.onopen = function () {
        clearTimeout(timer);
        finish(true);
        try { ws.close(); } catch (e) {}
    };
    ws.onerror = function () {
        clearTimeout(timer);
        finish(false, '握手被拒绝或被中断（Upgrade 头很可能被中间层剥掉了）');
    };
    ws.onclose = function (ev) {
        clearTimeout(timer);
        finish(false, '连接被关闭（code ' + ev.code + '）');
    };
})();
</script>
</body>
</html>
HTMLEOF

    # 注入运行期变量：用 python3 做字符串替换 + 百分号编码，避免密码里的
    # & = % 反斜杠 等字符破坏 URL 或 JS 字符串。python3 一定在（websockify 依赖它），
    # sed 那条只是兜底（密码含特殊字符时可能不准）。
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$NOVNC_WEB/index.html" "$qs" "$auto_pw" "${WS_PATH:-}" <<'PYEOF'
import io, sys
from urllib.parse import quote

path, qs, pw, ws_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
if pw:
    qs += "&password=" + quote(pw, safe="")
if ws_path:
    qs += "&path=" + quote(ws_path, safe="")

# 嵌入 JS 双引号字符串，转义反斜杠与双引号
js_qs = qs.replace('\\', '\\\\').replace('"', '\\"')

s = io.open(path, encoding='utf-8').read()
s = s.replace('__QS__', js_qs).replace('__WSPATH__', ws_path.replace('\\', '\\\\').replace('"', '\\"'))
io.open(path, 'w', encoding='utf-8').write(s)
PYEOF
    else
        sed -i "s#__QS__#$qs#g; s#__WSPATH__#${WS_PATH:-}#g" "$NOVNC_WEB/index.html"
    fi
}
gen_index
log "entry page generated at $NOVNC_WEB/index.html (probes WebSocket before entering)"

# ------------------------------------------- 6.5 收敛 GTK 文件选择器的可见路径
# 115 客户端选「上传哪个文件 / 下到哪个目录」时弹的是 GTK3 原生文件选择器，
# 它会把容器自己的文件系统整个摊开：/config（登录态）、/appdata（WebKit
# Cookie）、/cache、/logs 这些卷，和 /bin /usr 等镜像目录，跟 NAS 目录混在一起。
#
# 标准 GTK3 **没有**「只显示指定目录」的开关：PlacesSidebar 的
# show-other-locations / show-trash 全部是应用侧 API（gtk_places_sidebar_set_*），
# 不是 settings.ini / gsettings 能改的；做成配置项的是 gtk3-classic 这类第三方
# 补丁集，引入非官方包不值得。所以这里做两件确实能落地的事：
#
#   ① 书签置顶：写 $XDG_CONFIG_HOME/gtk-3.0/bookmarks。GTK 的所有 file chooser
#      （含 Avalonia/.NET 等在 Linux 上复用 GTK 原生对话框的应用）共享这一个
#      文件，写进去的目录固定排在侧栏顶部，一次点击直达，不用再去翻卷列表。
#      默认钉住 /root/Downloads（客户端默认下载目录）与 /media/nas（上传目录）。
#
#   ② 精简卷列表：「其他位置」里那些 /config /appdata /cache /logs 条目来自
#      GVolumeMonitor → GIO 的 g_unix_mounts_get() → libmount 读挂载表。libmount
#      允许用 LIBMOUNT_MTAB 指定一份自定义挂载表（mnt_get_mtab_path() 读该变量），
#      于是这里生成一份只保留「根 + NAS 目录」的精简表给客户端进程用，容器内部
#      卷就不再作为独立卷出现。
#      注意 libmount ≥ 2.39 已废弃这条路径（mnt_table_parse_mtab(NULL) 直接
#      硬编码 /proc/self/mountinfo，mnt_has_regular_mtab() 退化成返回 0 的桩），
#      所以启用前先用 findmnt 实测一次，不生效就整段跳过，不留后遗症。
#
# 兜底开关：HIDE_SYSTEM_PATHS=0 全部关掉。
setup_file_chooser() {
    if [ "${HIDE_SYSTEM_PATHS:-1}" = "0" ]; then
        log "file chooser: HIDE_SYSTEM_PATHS=0, container paths left as-is"
        return
    fi

    # ---- ① 书签置顶 -------------------------------------------------------
    # XDG_CONFIG_HOME=/config，所以书签落在 /config/gtk-3.0/bookmarks（随配置卷持久）。
    local bmdir="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/gtk-3.0"
    mkdir -p "$bmdir" 2>/dev/null || { log "file chooser: WARN cannot create $bmdir"; return; }

    local bm="$bmdir/bookmarks"
    local items item path label n=0
    # 条目用 | 分隔：路径里可能带空格/冒号，用 | 作分隔符歧义最小
    IFS='|' read -r -a items <<< "${GTK_BOOKMARKS:-/root/Downloads=115 下载目录|/media/nas=NAS 共享目录}"
    : > "$bm"
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        path="${item%%=*}"
        label="${item#*=}"
        [ -n "$path" ] || continue
        if [ ! -d "$path" ]; then
            log "file chooser: skip bookmark $path (not mounted)"
            continue
        fi
        # file:// URI 中的空格必须转义成 %20；空格之后是显示名
        printf 'file://%s %s\n' "$(printf '%s' "$path" | sed 's/ /%20/g')" "$label" >> "$bm"
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
        log "file chooser: $n bookmark(s) pinned at $bm"
    else
        log "file chooser: WARN no bookmark directory exists (check NAS_SHARE mounts)"
    fi

    # ---- ② 精简挂载表 -----------------------------------------------------
    # /proc/self/mounts 里路径中的空格已转义成 \040，直接按空格切词是安全的。
    MTAB_FILTER_FILE=/tmp/115nas-mtab
    : > "$MTAB_FILTER_FILE"
    while read -r dev mnt fstype opts _rest; do
        [ -n "${mnt:-}" ] || continue
        case "$mnt" in
            /)                 ;;   # 根总保留，否则一堆路径判断会拿不到挂载信息
            /root/Downloads)   ;;   # 客户端默认下载目录
            /media/*)          ;;   # 上传目录 /media/nas 及其它 /media 挂载
            *)
                # 用户额外指定的挂载点（EXTRA_VISIBLE_MOUNTS="/share/A /share/B"）
                case " ${EXTRA_VISIBLE_MOUNTS:-} " in
                    *" $mnt "*) ;;
                    *) continue ;;
                esac
                ;;
        esac
        printf '%s %s %s %s 0 0\n' "$dev" "$mnt" "$fstype" "$opts" >> "$MTAB_FILTER_FILE"
    done < /proc/self/mounts

    local want all got
    want=$(grep -c . "$MTAB_FILTER_FILE" 2>/dev/null)
    if [ "${want:-0}" -eq 0 ] || ! command -v findmnt >/dev/null 2>&1; then
        rm -f "$MTAB_FILTER_FILE"
        log "file chooser: mount trimming skipped (no findmnt or nothing to keep)"
        return
    fi

    # 关键：先实测 libmount 认不认 LIBMOUNT_MTAB。不认就撤回，绝不带着一份
    # 假挂载表启动客户端——那会让 GIO 认为系统里几乎没有挂载点。
    all=$(findmnt -rno TARGET 2>/dev/null | grep -c .)
    got=$(LIBMOUNT_MTAB="$MTAB_FILTER_FILE" findmnt -rno TARGET 2>/dev/null | grep -c .)
    if [ "${got:-0}" -eq "$want" ] && [ "${got:-0}" -lt "${all:-0}" ]; then
        export LIBMOUNT_MTAB="$MTAB_FILTER_FILE"
        log "file chooser: mount list trimmed $all -> $got entries (LIBMOUNT_MTAB=$MTAB_FILTER_FILE)"
    else
        rm -f "$MTAB_FILTER_FILE"
        log "file chooser: LIBMOUNT_MTAB not honored by this libmount (needs util-linux < 2.39); keeping full mount list"
    fi
}
MTAB_FILTER_FILE=""
setup_file_chooser

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
log "  VNC target : $VNC_BIND:$VNC_PORT (raw VNC; only for direct clients / Cloudflare browser-rendered VNC)"
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
