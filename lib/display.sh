#!/bin/bash
# 显示栈：KasmVNC 优先，Xvfb+x11vnc 兜底。
#
# 为什么换成 KasmVNC（1.1.6 的主要改动）：
#   1.1.5 及以前是三个进程串起来的 —— Xtigervnc(X 服务端 + RFB) →
#   websockify(HTTP/WS 桥) → noVNC(静态页)。浏览器到画面之间多一次进程内转发，
#   而且 noVNC 只能拿到 Tight/JPEG 的固定画质。
#   KasmVNC 把 X 服务端、RFB、HTTP、WebSocket 做到同一个进程里（Xkasmvnc），
#   编码上有 WebP/JPEG 自适应 + 多线程（1.4.0 起明显降 CPU），少一跳、少两个进程。
#   它的 Web 客户端本身就是 noVNC 的定制分支，WS 路径仍然是 `websockify`，
#   **现有反向代理规则不用改**。
#
# 兜底路径保留：Xvfb + x11vnc 仍在镜像里。KasmVNC 起不来（老内核、库冲突、
# 参数被拒）时自动降级，代价是画质与剪贴板退步，日志会明确写清楚。

start_kasmvnc() {
    local bin=""
    for c in Xkasmvnc Xvnc; do
        if command -v "$c" >/dev/null 2>&1; then bin=$(command -v "$c"); break; fi
    done
    [ -n "$bin" ] || { warn "kasmvnc: 找不到 Xkasmvnc/Xvnc"; return 1; }

    local www="$KASM_WWW"
    [ -d "$www" ] || www=/usr/share/kasmvnc/www
    [ -d "$www" ] || { warn "kasmvnc: 找不到 web 资源目录（预期 $KASM_WWW）"; return 1; }

    # ---- 监听地址与认证 ----
    # KasmVNC 默认走 websocket 模式（不传 -noWebsocket）：HTTP、WebSocket、
    # RFB 全部落在 -websocketPort 这一个端口上。源码 vncExtInit.cc 里
    # `if (!noWebsocket) createWebsocketListeners(...)` 这条分支**不使用**
    # rfbport / port 变量，所以这里没有独立的 RFB 端口可绑，VNC_PORT 与
    # VNC_BIND 只对降级路径（x11vnc）有意义。
    #
    # 也**不能**传 -localhost：它把监听地址换成字符串 "local"，
    # getaddrinfo("local") 会返回 IPv4 与 IPv6 两条记录，而每个
    # WebsocketListener 都去 bind 同一个抽象 unix socket（.KasmVNCSock<pid>），
    # 第二条就报 "failed to bind socket: Address already in use" 让 X 直接 Fatal；
    # 就算绑上了，它也只绑 127.0.0.1，宿主 -p 映射进来的流量根本到不了。
    # 换成具体地址（0.0.0.0）时 getaddrinfo 只给出一条记录，两个问题一起消失。
    #
    # RFB 层仍然不放认证：KasmVNC 的鉴权在 Web 层（下面的 kasmpasswd）。
    # 不显式写 None 的话，TigerVNC 系的默认值是 VncAuth 并要求口令文件，
    # 没设口令时容器会直接起不来。
    local sec_args=(-SecurityTypes None)
    local auth_args=()
    if [ -n "$VNC_PASSWORD" ]; then
        # 口令文件必须落在 KasmVNC 的默认路径 $HOME/.kasmpasswd ——
        # 写到别处它不会读，表现为「设了口令但照样能进」。
        if printf '%s\n%s\n' "$VNC_PASSWORD" "$VNC_PASSWORD" \
             | kasmvncpasswd -u vncuser -w "$HOME/.kasmpasswd" >/dev/null 2>&1; then
            log "Web 登录口令已启用（用户名 vncuser，口令文件 $HOME/.kasmpasswd）"
            log "  验证方式：打开页面应出现登录框；若直接进了桌面，说明口令没生效"
        else
            fatal "VNC_PASSWORD 已设置，但 kasmvncpasswd 生成口令文件失败；拒绝在无认证状态下启动"
        fi
    else
        # 关键：没有口令文件时 KasmVNC 对**所有** HTTP 请求回 401（连续几次还会
        # 把来源 IP 拉进黑名单，日志里是 "IP ... is blacklisted, dropping"），
        # 首页和 /websockify 一并进不去 —— 「没设口令」不等于「谁都能进」，
        # 而是「谁都进不来」。必须显式 -DisableBasicAuth 才是匿名可访问。
        auth_args=(-DisableBasicAuth)
        warn "未设置 VNC_PASSWORD：Web 端口无登录口令（靠反代/内网隔离）"
    fi

    # ---- TLS（可选）----
    # 证书合用一份 PEM 时按块拆开：KasmVNC 要 -cert / -key 两个文件。
    local tls_args=()
    if [ -f "$VNC_TLS_CERT" ] && grep -q "BEGIN CERTIFICATE" "$VNC_TLS_CERT" 2>/dev/null \
       && grep -q "PRIVATE KEY" "$VNC_TLS_CERT" 2>/dev/null; then
        awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' "$VNC_TLS_CERT" > /tmp/115nas-tls-cert.pem
        awk '/BEGIN [A-Z ]*PRIVATE KEY/,/END [A-Z ]*PRIVATE KEY/' "$VNC_TLS_CERT" > /tmp/115nas-tls-key.pem
        if [ -s /tmp/115nas-tls-cert.pem ] && [ -s /tmp/115nas-tls-key.pem ]; then
            tls_args=(-sslOnly -cert /tmp/115nas-tls-cert.pem -key /tmp/115nas-tls-key.pem)
            log "TLS 已启用：端口 $HTTP_PORT 只提供 HTTPS/WSS（证书 $VNC_TLS_CERT）"
        fi
    fi

    # ---- 编码参数 ----
    # 不传 -FrameRate 时默认 60fps，是这套栈上最大的浪费。
    # 这几个名字与 1.5.2 的配置表一致（vncExtInit.cc 里的 rfb::*Parameter
    # 定义与 common/rfb/Configuration.cc，大小写敏感、不带前导横线）。
    local enc_args=()
    [ "$VNC_FRAME_RATE" != "0" ] && enc_args+=(-FrameRate "$VNC_FRAME_RATE")
    enc_args+=(-CompareFB 2)
    enc_args+=(-DynamicQualityMin "$VNC_QUALITY_MIN" -DynamicQualityMax "$VNC_QUALITY_MAX")
    enc_args+=(-webpEncodingTime "$VNC_WEBP_TIME")

    # shellcheck disable=SC2086
    "$bin" ":$DISPLAY_NUM" \
        -geometry "${W}x${H}" -depth "$D" \
        -httpd "$www" \
        -websocketPort "$HTTP_PORT" -interface 0.0.0.0 \
        "${sec_args[@]}" "${auth_args[@]}" "${tls_args[@]}" "${enc_args[@]}" \
        -AlwaysShared -ac -desktop 115nas \
        >"$LOG_DIR/xkasmvnc.log" 2>&1 &
    XVNC_PID=$!

    # 只等 HTTP 应答（401 也算应答，说明 Web 层活着）。探 5900 在这个模式下没有
    # 意义（它不绑那个端口），而只看进程存活会被「参数被拒、X 直接 Fatal」骗过去。
    if ! wait_http "$HTTP_PORT" 20; then
        warn "kasmvnc: HTTP 端口 $HTTP_PORT 未就绪（见 $LOG_DIR/xkasmvnc.log）"
        tail -n 15 "$LOG_DIR/xkasmvnc.log" 2>/dev/null | while read -r l; do warn "  | $l"; done
        kill "$XVNC_PID" 2>/dev/null
        return 1
    fi

    DISPLAY_BACKEND="kasmvnc"
    log "Xkasmvnc 已就绪：Web/WS :$HTTP_PORT（HTTP、WebSocket、RFB 同一端口，pid $XVNC_PID）"
    log "  编码：frame rate ${VNC_FRAME_RATE}fps，动态画质 ${VNC_QUALITY_MIN}-${VNC_QUALITY_MAX}，webp 预算 ${VNC_WEBP_TIME}ms"
    return 0
}

start_fallback_vnc() {
    warn "降级到 Xvfb + x11vnc：画质与剪贴板都比 KasmVNC 差（中文剪贴板会乱码）"
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null

    Xvfb "$DISPLAY" -screen 0 "${W}x${H}x${D}" -ac \
         +extension GLX +extension RANDR +render -noreset \
         >"$LOG_DIR/xvfb.log" 2>&1 &
    XVFB_PID=$!

    local i=0
    while [ "$i" -lt 100 ]; do
        xdpyinfo -display "$DISPLAY" >/dev/null 2>&1 && break
        sleep 0.2
        i=$((i + 1))
    done

    local -a args=(-display "$DISPLAY" -rfbport "$VNC_PORT" -forever -shared -xkb -quiet
                   -o "$LOG_DIR/x11vnc.log")
    if [ "$VNC_BIND" = "127.0.0.1" ]; then args+=(-localhost); fi
    if [ -n "$VNC_PASSWORD" ]; then
        command -v x11vnc >/dev/null 2>&1 || fatal "降级路径需要 x11vnc，但镜像里没有"
        x11vnc -storepasswd "$VNC_PASSWORD" /tmp/115nas-rfb.pass >/dev/null 2>&1 \
            || fatal "x11vnc -storepasswd 失败；拒绝在无认证状态下启动"
        args+=(-rfbauth /tmp/115nas-rfb.pass)
        log "x11vnc 口令认证已启用"
    else
        args+=(-nopw)
        warn "未设置 VNC_PASSWORD：x11vnc 无口令"
    fi

    x11vnc "${args[@]}" >"$LOG_DIR/x11vnc.out" 2>&1 &
    X11VNC_PID=$!
    wait_tcp 127.0.0.1 "$VNC_PORT" 15 || { warn "x11vnc 没起来"; return 1; }

    # websockify 仍然需要：x11vnc 不会讲 HTTP/WS。
    local extra=""
    websockify --help 2>&1 | grep -q -- "--heartbeat" && extra="--heartbeat 30"
    [ -n "${WS_VERBOSE:-}" ] && extra="$extra --verbose"
    # shellcheck disable=SC2086
    websockify --web "$NOVNC_WEB" $extra "$HTTP_PORT" "127.0.0.1:$VNC_PORT" \
        >"$LOG_DIR/websockify.log" 2>&1 &
    WS_PID=$!
    wait_http "$HTTP_PORT" 15 || { warn "websockify 没起来"; return 1; }

    DISPLAY_BACKEND="x11vnc"
    log "Xvfb + x11vnc + websockify 已就绪：Web/WS :$HTTP_PORT（降级模式）"
    return 0
}

start_display() {
    rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null

    case "$DISPLAY_MODE" in
        kasmvnc)
            start_kasmvnc || fatal "DISPLAY_MODE=kasmvnc 且启动失败；看 $LOG_DIR/xkasmvnc.log"
            ;;
        fallback)
            start_fallback_vnc || fatal "DISPLAY_MODE=fallback 且启动失败"
            ;;
        *)
            if start_kasmvnc; then
                :
            else
                # KasmVNC 失败时它可能留下了锁文件，先清干净再起兜底
                rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}" 2>/dev/null
                start_fallback_vnc || fatal "KasmVNC 与 X11vnc 都没起来；看 $LOG_DIR/"
            fi
            ;;
    esac
}
