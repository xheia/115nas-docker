#!/bin/bash
# 桌面会话：窗口管理器、中文输入法、字体缓存、文件选择器书签。
# 这一层与显示栈无关，KasmVNC / x11vnc 两种模式共用。

start_wm() {
    # 115 客户端需要 WM 才能正常获得焦点、拖动、最大化。
    openbox >"$LOG_DIR/openbox.log" 2>&1 &
    OB_PID=$!
    log "openbox 已启动（pid $OB_PID）"
}

start_ime() {
    # 中文输入：容器内跑 fcitx5，拼音候选直接画在虚拟屏上（VNC 能看到），
    # 数字键选字。失败不影响使用——「电脑复制 → Ctrl+V 粘贴」始终可用。
    #
    # 这里**不再 sleep 1 硬等**：旧实现每次启动白扔一秒。改成轮询进程，
    # 一般 100-300ms 内就能确认起来；超时也只是记一条日志，不阻塞后续启动。
    if ! command -v fcitx5 >/dev/null 2>&1; then
        log "未安装 fcitx5，中文输入请用 Ctrl+V 粘贴"
        return 0
    fi
    export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null
    chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null

    fcitx5 -d >"$LOG_DIR/fcitx5.log" 2>&1
    local i=0
    while [ "$i" -lt 20 ]; do
        pgrep -x fcitx5 >/dev/null 2>&1 && { log "fcitx5 已启动（Ctrl+Space 切换中文）"; return 0; }
        sleep 0.1
        i=$((i + 1))
    done
    warn "fcitx5 未能在 2s 内启动，中文输入请用 Ctrl+V 粘贴（见 $LOG_DIR/fcitx5.log）"
}

seed_font_cache() {
    # $XDG_CACHE_HOME=/cache 是挂卷，首次启动为空。镜像里已算好一份字体缓存，
    # 这里只在缓存目录不存在时复制一次（之后由卷留存），省掉首次的冷扫描。
    local cache="${XDG_CACHE_HOME:-/cache}"
    [ -d /opt/fontconfig-cache ] || return 0
    [ -d "$cache/fontconfig" ] && return 0
    mkdir -p "$cache" 2>/dev/null
    if cp -a /opt/fontconfig-cache "$cache/fontconfig" 2>/dev/null; then
        log "已从镜像播种 fontconfig 缓存（跳过首次字体扫描）"
    fi
}

setup_bookmarks() {
    # 115 客户端选「上传哪个文件 / 下到哪个目录」时弹 GTK3 原生选择器，
    # 它会把容器自己的文件系统整个摊开。GTK3 没有「只显示指定目录」的开关
    # （PlacesSidebar 的 show-* 全是应用侧 API），所以只能**书签置顶**：
    # 写 gtk-3.0/bookmarks，侧栏顶部一次点击直达，不用翻卷列表。
    #
    # 别去试 LIBMOUNT_MTAB 精简挂载表：libmount 只在编译了
    # USE_LIBMOUNT_SUPPORT_MTAB 时才读那个变量，Debian/Ubuntu 都没开。
    if [ "${HIDE_SYSTEM_PATHS:-1}" = "0" ]; then
        log "HIDE_SYSTEM_PATHS=0：不钉书签"
        return 0
    fi

    local dir="${XDG_CONFIG_HOME:-/config}/gtk-3.0" bm item path label n=0
    mkdir -p "$dir" 2>/dev/null || { warn "建不出 $dir，跳过书签"; return 0; }
    bm="$dir/bookmarks"
    : > "$bm"

    local -a items
    IFS='|' read -r -a items <<< "${GTK_BOOKMARKS:-/root/Downloads=115 下载目录|/media/nas=NAS 共享目录}"
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        path="${item%%=*}"
        label="${item#*=}"
        [ -n "$path" ] || continue
        if [ ! -d "$path" ]; then
            log "跳过书签 $path（未挂载）"
            continue
        fi
        printf 'file://%s %s\n' "$(printf '%s' "$path" | sed 's/ /%20/g')" "$label" >> "$bm"
        n=$((n + 1))
    done
    if [ "$n" -gt 0 ]; then
        log "已在文件选择器侧栏钉 $n 个书签"
    else
        warn "没有任何书签目录存在（检查 /root/Downloads、/media/nas 的挂载）"
    fi
}
