#!/bin/bash
# 诊断：把静态诊断页放进当前 Web 根目录，并提供健康检查。

install_diag_page() {
    # 诊断页是纯静态的，用相对路径探测同一 origin 下的 websockify，
    # 所以不需要在启动时做任何变量替换（1.1.5 的入口页要注入 QS/WSPATH）。
    local root="$NOVNC_WEB"
    [ "$DISPLAY_BACKEND" = "kasmvnc" ] && root="$KASM_WWW"
    [ -d "$root" ] || return 0

    local src="${APP_DIR:-/usr/local/share/115nas}/diag.html"
    [ -f "$src" ] || { warn "诊断页缺失（$src）"; return 0; }
    if cp -f "$src" "$root/diag.html" 2>/dev/null; then
        log "诊断页已就位：http://<host>:$HTTP_PORT/diag.html"
    else
        warn "诊断页复制失败（$root 不可写？）"
    fi
}

# 关键进程还活着吗。返回非 0 时由主循环决定退出（交给 docker restart 策略）。
health_check() {
    local dead=""

    case "$DISPLAY_BACKEND" in
        kasmvnc)
            proc_alive "$XVNC_PID" || dead="Xkasmvnc"
            ;;
        x11vnc)
            proc_alive "$XVFB_PID"   || dead="Xvfb"
            [ -z "$dead" ] || return 1
            proc_alive "$X11VNC_PID" || dead="x11vnc"
            [ -z "$dead" ] || return 1
            proc_alive "$WS_PID"     || dead="websockify"
            ;;
        *)
            dead="display"
            ;;
    esac
    [ -z "$dead" ] || { log "FATAL: $dead 已退出，容器退出（由 restart 策略接管）"; return 1; }
    return 0
}
