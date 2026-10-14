#!/usr/bin/env bash
# =====================================================================
#  VPS (Linux) - Sun-Panel 管理脚本（Docker + Cloudflare 隧道）
#
#  - 使用官方镜像 hslr/sun-panel（官方 1.8.x 正式版只以镜像/二进制发布）
#  - 容器 restart=always：进程被杀、VPS 重启都会自动拉起，不需要 cron 守护
#  - 通过 Cloudflare 隧道（cloudflared 容器）对外提供 https://你的域名：
#      不占用 80/443、不用管证书，和 VPS 上其他服务（sing-box 等）互不干扰
#  - 自动放行防火墙端口（ufw / firewalld / iptables），卸载时自动关闭
#  - 数据保存在 /opt/sun-panel（conf / database / uploads），升级不丢
#
#  用法（需要 root）：bash sunpanel-vps.sh
# =====================================================================
set -u

IMAGE="${SUNPANEL_IMAGE:-hslr/sun-panel:latest}"
CNAME="sun-panel"
TUNNEL_NAME="sunpanel-cloudflared"          # 专用名字，不会碰你其他的 cloudflared
TUNNEL_IMAGE="cloudflare/cloudflared:latest"
NET="sunpanel-net"
DATA_DIR="${SUNPANEL_DIR:-/opt/sun-panel}"
STATE_FILE="$DATA_DIR/.sunpanel-vps.env"
TOKEN_FILE="$DATA_DIR/.cf-tunnel.env"       # 仅 root 可读，保存 TUNNEL_TOKEN
LEGACY_CRON="${SUNPANEL_CRON_FILE:-/etc/cron.d/sunpanel-renew}"   # 旧版（Caddy 续期版）遗留
ROLLBACK_TAG="sun-panel-rollback:prev"
MIRROR="${SUNPANEL_MIRROR:-}"   # 可选：Docker Hub 加速站前缀，如 docker.1ms.run（拉取失败时自动改走它）
CPORT=3002            # 容器内部端口（程序默认值，不要改）
DEFAULT_PORT=3002     # 对外端口默认值（只是官方示例，可随意改）

info() { echo "➜ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
die()  { echo "❌ $*" >&2; exit 1; }

# 菜单配色：终端里显示亮绿色，重定向/非终端时自动不带颜色
if [ -t 1 ]; then G=$'\033[1;92m'; RD=$'\033[1;91m'; R=$'\033[0m'; else G=""; RD=""; R=""; fi
menu() { echo "${G}$*${R}"; }
menu_red() { echo "${RD}$*${R}"; }

ask_yn() {  # ask_yn "提示(Y/n)" 默认值(y|n)
    local a
    read -r -p "$1 " a
    a="${a:-${2:-n}}"
    case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------
# 状态文件
# ---------------------------------------------------------------------
load_state() {
    PORT="$DEFAULT_PORT"; BIND="0.0.0.0"; DOMAIN=""; FW_RULES=""
    # shellcheck disable=SC1090
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    return 0
}

save_state() {
    mkdir -p "$DATA_DIR"
    cat > "$STATE_FILE" <<EOF
PORT="$PORT"
BIND="$BIND"
DOMAIN="$DOMAIN"
FW_RULES="$FW_RULES"
EOF
}

# ---------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------
need_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行（或 sudo bash $0）"
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1; then
        docker info >/dev/null 2>&1 && return 0
        warn "已安装 docker 但服务没有运行，尝试启动 ..."
        systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1
        sleep 2
        docker info >/dev/null 2>&1 && return 0
        die "docker 服务无法启动，请先排查：systemctl status docker"
    fi
    warn "没有检测到 Docker。"
    ask_yn "用 Docker 官方安装脚本 (get.docker.com) 现在安装? (Y/n):" y \
        || die "已取消。请先自行安装 Docker 后再运行本脚本"
    command -v curl >/dev/null 2>&1 || die "需要 curl 才能下载安装脚本，请先安装 curl"
    curl -fsSL https://get.docker.com | sh || die "Docker 安装失败，请查看上面的报错"
    systemctl enable --now docker >/dev/null 2>&1
    docker info >/dev/null 2>&1 || die "Docker 已安装但服务未运行"
    ok "Docker 安装完成"
}

container_exists()  { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

port_in_use() {   # TCP 端口是否已被监听
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

port_owner() {
    command -v ss >/dev/null 2>&1 && ss -H -ltnp "sport = :$1" 2>/dev/null | head -n3 | sed 's/^/    /'
}

public_ip() {
    curl -fsS -m 6 https://api.ipify.org 2>/dev/null \
        || curl -fsS -m 6 https://ifconfig.me 2>/dev/null \
        || true
}

# 容器内部健康检查（不依赖是否对外发布端口）
alive() {
    docker exec "$CNAME" wget -q -O /dev/null -T 3 "http://127.0.0.1:$CPORT/" >/dev/null 2>&1
}

wait_up() {  # wait_up 最长秒数
    local i=0
    while [ "$i" -lt "$1" ]; do
        container_running "$CNAME" && alive && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------
# 防火墙：自动放行 / 卸载时自动关闭
#   只记录并关闭“本脚本新增”的规则，不碰原有规则（包括 SSH）
# ---------------------------------------------------------------------
fw_backend() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        echo ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        echo firewalld
    elif command -v iptables >/dev/null 2>&1 \
        && iptables -S INPUT 2>/dev/null | head -n1 | grep -qE -- '-P INPUT (DROP|REJECT)'; then
        echo iptables
    else
        echo none
    fi
}

fw_has()     { case " $FW_RULES " in *" $1 "*) return 0 ;; esac; return 1; }
fw_rec_add() { fw_has "$1" || { FW_RULES="${FW_RULES:+$FW_RULES }$1"; save_state; }; }
fw_rec_del() {
    local r n=""
    for r in $FW_RULES; do [ "$r" = "$1" ] || n="${n:+$n }$r"; done
    FW_RULES="$n"; save_state
}

fw_persist() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service iptables save >/dev/null 2>&1
    fi
    return 0
}

fw_open() {   # fw_open 3002/tcp
    local spec="$1" port proto be
    port="${spec%/*}"; proto="${spec#*/}"
    fw_has "$spec" && return 0
    be="$(fw_backend)"
    case "$be" in
        ufw)
            if ufw status 2>/dev/null | grep -qE "^${port}/${proto}[[:space:]]+ALLOW"; then
                info "ufw 里已有 $spec 的放行规则，保持不动"; return 0
            fi
            if ufw allow "$spec" >/dev/null 2>&1; then fw_rec_add "$spec"; ok "ufw 已放行 $spec"
            else warn "ufw 放行 $spec 失败"; fi ;;
        firewalld)
            if firewall-cmd --query-port="$spec" >/dev/null 2>&1; then
                info "firewalld 里已放行 $spec，保持不动"; return 0
            fi
            if firewall-cmd --permanent --add-port="$spec" >/dev/null 2>&1 \
                && firewall-cmd --reload >/dev/null 2>&1; then
                fw_rec_add "$spec"; ok "firewalld 已放行 $spec"
            else warn "firewalld 放行 $spec 失败"; fi ;;
        iptables)
            if iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                info "iptables 里已放行 $spec，保持不动"; return 0
            fi
            if iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
                fw_persist; fw_rec_add "$spec"; ok "iptables 已放行 $spec"
            else warn "iptables 放行 $spec 失败"; fi ;;
        *)
            info "没有检测到启用中的防火墙，$spec 无需放行" ;;
    esac
}

fw_close() {   # 只关闭本脚本打开过的规则
    local spec="$1" port proto
    port="${spec%/*}"; proto="${spec#*/}"
    fw_has "$spec" || return 0
    case "$(fw_backend)" in
        ufw)      ufw --force delete allow "$spec" >/dev/null 2>&1 ;;
        firewalld)
            firewall-cmd --permanent --remove-port="$spec" >/dev/null 2>&1
            firewall-cmd --reload >/dev/null 2>&1 ;;
        iptables) iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; fw_persist ;;
    esac
    fw_rec_del "$spec"
    ok "已关闭防火墙端口 $spec"
}

fw_close_all() {
    local r
    for r in $FW_RULES; do fw_close "$r"; done
}

# ---------------------------------------------------------------------
# 询问 / 创建容器
# ---------------------------------------------------------------------
ask_port() {   # 设置全局 PORT
    local p
    echo "（对外端口只是映射到容器内的 $CPORT，$DEFAULT_PORT 是官方示例，不是强制要求，可改成任意未占用端口）"
    while true; do
        read -r -p "对外端口 [${PORT:-$DEFAULT_PORT}]: " p
        p="${p:-${PORT:-$DEFAULT_PORT}}"
        case "$p" in ''|*[!0-9]*) warn "端口必须是数字"; continue ;; esac
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            warn "端口范围应为 1-65535"; continue
        fi
        if port_in_use "$p" && ! { container_exists "$CNAME" && [ "$p" = "${PORT:-}" ]; }; then
            warn "端口 $p 已被占用："
            port_owner "$p"
            continue
        fi
        PORT="$p"
        return 0
    done
}

ask_bind() {   # 设置全局 BIND
    local s tunnel_on=0
    container_running "$TUNNEL_NAME" && tunnel_on=1
    echo "监听方式："
    echo "  1) 0.0.0.0    所有网卡，可用 http://服务器IP:端口 直接访问"
    echo "  2) 127.0.0.1  仅本机"
    [ "$tunnel_on" -eq 1 ] && echo "  3) 不发布端口  只能通过 Cloudflare 隧道访问（最安全，推荐）"
    read -r -p "请选择 [${BIND_DEFAULT:-1}]: " s
    case "${s:-${BIND_DEFAULT:-1}}" in
        1) BIND="0.0.0.0" ;;
        2) BIND="127.0.0.1" ;;
        3) [ "$tunnel_on" -eq 1 ] && BIND="none" || { warn "隧道没在运行，不能选 3"; return 1; } ;;
        *) warn "无效选择"; return 1 ;;
    esac
}

ensure_net() {
    docker network inspect "$NET" >/dev/null 2>&1 && return 0
    docker network create "$NET" >/dev/null 2>&1 || { warn "创建 docker 网络 $NET 失败"; return 1; }
}

pull_image() {   # pull_image 镜像  失败自动重试 3 次；设了 SUNPANEL_MIRROR 时再走加速站
    local img="$1" n=1
    while [ "$n" -le 3 ]; do
        docker pull "$img" && return 0
        [ "$n" -lt 3 ] && { warn "拉取失败，3 秒后重试（第 $n/3 次）..."; sleep 3; }
        n=$((n + 1))
    done
    if [ -n "$MIRROR" ]; then
        warn "直连失败，改用加速站 $MIRROR ..."
        if docker pull "$MIRROR/$img"; then
            docker tag "$MIRROR/$img" "$img" && docker rmi "$MIRROR/$img" >/dev/null 2>&1
            return 0
        fi
    fi
    return 1
}

run_panel() {   # run_panel [镜像]  使用全局 PORT / BIND
    local image="${1:-$IMAGE}"
    local -a pub=()
    ensure_net || return 1
    mkdir -p "$DATA_DIR/conf" "$DATA_DIR/database" "$DATA_DIR/uploads" || { warn "无法创建数据目录 $DATA_DIR"; return 1; }
    docker rm -f "$CNAME" >/dev/null 2>&1
    [ "$BIND" != "none" ] && pub=(-p "${BIND}:${PORT}:${CPORT}")
    docker run -d --name "$CNAME" --restart always --network "$NET" \
        ${pub[@]+"${pub[@]}"} \
        -v "$DATA_DIR/conf:/app/conf" \
        -v "$DATA_DIR/database:/app/database" \
        -v "$DATA_DIR/uploads:/app/uploads" \
        "$image" >/dev/null
}

sync_panel_fw() {   # 按当前 BIND 放行/关闭面板端口
    if [ "$BIND" = "0.0.0.0" ]; then fw_open "$PORT/tcp"; else fw_close "$PORT/tcp"; fi
}

backup_data() {   # 备份到 ~/sun-panel-backup.tar.gz（只保留最新一份），路径放进 BACKUP_FILE
    BACKUP_FILE=""
    [ -d "$DATA_DIR" ] || return 0
    local files="" d tmp="$HOME/sun-panel-backup.tar.gz.tmp"
    for d in conf database uploads; do
        [ -e "$DATA_DIR/$d" ] && files="$files $d"
    done
    [ -n "$files" ] || return 0
    # shellcheck disable=SC2086
    if tar -czf "$tmp" -C "$DATA_DIR" $files; then
        rm -f "$HOME"/sun-panel-backup-*.tar.gz          # 清理旧版脚本留下的带时间戳备份
        mv -f "$tmp" "$HOME/sun-panel-backup.tar.gz"
        BACKUP_FILE="$HOME/sun-panel-backup.tar.gz"
        ok "数据已备份（覆盖旧备份）: $BACKUP_FILE"
    else
        rm -f "$tmp"; warn "备份失败（旧备份保持不变）"; return 1
    fi
}

show_access() {
    local ip
    if [ -n "$DOMAIN" ] && container_running "$TUNNEL_NAME"; then
        echo "访问地址: https://$DOMAIN"
    fi
    case "$BIND" in
        0.0.0.0)
            ip="$(public_ip)"
            echo "直连地址: http://${ip:-服务器IP}:$PORT"
            echo "   （打不开请检查云厂商安全组是否放行 TCP $PORT；安全组不在服务器上，脚本改不了）" ;;
        127.0.0.1) echo "当前仅监听本机 127.0.0.1:$PORT" ;;
        none)      echo "未发布端口，只能通过 Cloudflare 隧道访问" ;;
    esac
}

# ---------------------------------------------------------------------
# 1. 安装
# ---------------------------------------------------------------------
do_install() {
    echo "------------- 安装 Sun-Panel（Docker）-------------"
    need_root
    ensure_docker
    load_state
    if container_exists "$CNAME"; then
        warn "已经安装过了。升级请用菜单 2，重装请先卸载。"
        return 0
    fi

    ask_port
    BIND_DEFAULT=1; ask_bind || die "监听方式无效"

    info "拉取镜像 $IMAGE ..."
    pull_image "$IMAGE" || die "镜像拉取失败（网络问题？可设置 SUNPANEL_MIRROR=加速站域名 再运行）"

    info "启动容器 ..."
    run_panel || die "容器启动失败"
    save_state
    sync_panel_fw

    if wait_up 30; then
        ok "服务已正常响应"
    else
        warn "30 秒内没有响应，请用菜单 10 查看日志排查"
    fi

    echo "=============================================="
    ok "安装完成"
    show_access
    echo "默认账号: admin@sun.cc   默认密码: 12345678   —— 登录后请立刻修改！"
    echo "说明：Docker 发布的端口会绕过 ufw/firewalld 的过滤；想真正限制访问，请用隧道 + 不发布端口。"
    echo "=============================================="

    if ask_yn "现在配置 Cloudflare 隧道（用域名访问，不占 80/443）? (y/N):" n; then
        do_tunnel_setup
    fi
}

# ---------------------------------------------------------------------
# 2. 升级（拉取最新官方镜像，失败自动回滚）
# ---------------------------------------------------------------------
do_upgrade() {
    echo "------------- 升级 Sun-Panel -------------"
    need_root
    ensure_docker
    load_state
    container_exists "$CNAME" || { warn "尚未安装，请先选择“安装”"; return 0; }

    local old_id new_id created
    old_id="$(docker inspect -f '{{.Image}}' "$CNAME" 2>/dev/null)"
    [ -n "$old_id" ] || die "读取当前镜像失败，未做任何改动"

    info "拉取最新镜像 $IMAGE ..."
    pull_image "$IMAGE" || die "镜像拉取失败，未做任何改动（可设置 SUNPANEL_MIRROR=加速站域名 再试）"
    new_id="$(docker image inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null)"
    created="$(docker image inspect -f '{{.Created}}' "$IMAGE" 2>/dev/null | cut -c1-19)"

    if [ "$old_id" = "$new_id" ]; then
        ok "面板已经是最新镜像（构建时间 $created），无需升级"
        upgrade_tunnel_if_any
        return 0
    fi

    echo "发现新镜像（构建时间 $created）"
    ask_yn "升级? 会先备份数据，失败自动回滚 (y/N):" n || { echo "已取消"; return 0; }

    backup_data
    docker tag "$old_id" "$ROLLBACK_TAG" || die "无法给旧镜像打回滚标签，已停止（未做任何改动）"

    info "用新镜像重建容器 ..."
    if run_panel "$IMAGE" && wait_up 40; then
        ok "升级成功"
        docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1   # 只删自己的旧镜像标签，不动系统里其他镜像
        upgrade_tunnel_if_any
    else
        warn "新版本启动失败或没有响应，回滚到旧镜像 ..."
        if run_panel "$ROLLBACK_TAG" && wait_up 30; then
            ok "已回滚，旧版本恢复运行"
        else
            warn "回滚后仍无响应，请用菜单 10 查看日志；数据备份: ${BACKUP_FILE:-无}"
        fi
        return 1
    fi
}

upgrade_tunnel_if_any() {   # 升级面板时顺带检查 cloudflared 是否有新版
    container_exists "$TUNNEL_NAME" || return 0
    ask_yn "检测到 Cloudflare 隧道容器，同时检查并更新 cloudflared? (Y/n):" y || return 0
    do_tunnel_update
}

# ---------------------------------------------------------------------
# 3. 卸载（两种方式；自动关闭防火墙端口；只清理本脚本创建的东西）
# ---------------------------------------------------------------------
legacy_cleanup() {   # 清理旧版脚本（Caddy + 证书续期版）可能留下的东西
    local line
    LEGACY_FOUND=0
    if container_exists sunpanel-caddy; then
        LEGACY_FOUND=1; docker rm -f sunpanel-caddy >/dev/null 2>&1; ok "已删除旧版遗留的 Caddy 容器"
    fi
    if [ -f "$LEGACY_CRON" ]; then
        LEGACY_FOUND=1; rm -f "$LEGACY_CRON"; ok "已删除旧版遗留的证书续期定时任务"
    fi
    if [ -s "$DATA_DIR/.released" ]; then
        LEGACY_FOUND=1
        while IFS= read -r line; do
            case "$line" in
                systemd:*)
                    if systemctl start "${line#systemd:}" >/dev/null 2>&1; then ok "已还原被旧版停止的服务 $line"
                    else warn "还原 $line 失败，请手动启动"; fi ;;
                docker:*)
                    if docker start "${line#docker:}" >/dev/null 2>&1; then ok "已还原被旧版停止的容器 $line"
                    else warn "还原 $line 失败，请手动启动"; fi ;;
            esac
        done < "$DATA_DIR/.released"
        rm -f "$DATA_DIR/.released"
    fi
    return 0
}

wipe_data_dir() {   # 只删本脚本创建的内容，不 rm -rf 整个目录，避免误删别的东西
    rm -rf "$DATA_DIR/conf" "$DATA_DIR/database" "$DATA_DIR/uploads" \
           "$DATA_DIR/caddy" "$DATA_DIR/letsencrypt" "$DATA_DIR/sunpanel-vps.sh"
    rm -f "$STATE_FILE" "$TOKEN_FILE" "$DATA_DIR/.released"
    if [ -d "$DATA_DIR" ]; then
        rmdir "$DATA_DIR" 2>/dev/null || warn "$DATA_DIR 里还有不是本脚本创建的文件，已保留该目录"
    fi
}

do_uninstall() {
    echo "------------- 卸载 Sun-Panel -------------"
    need_root
    command -v docker >/dev/null 2>&1 || { warn "没有安装 Docker，无需卸载"; return 0; }
    load_state
    local mode a n backups
    echo "卸载方式："
    echo "  1) 保留数据：删容器/隧道/网络/防火墙规则，保留 $DATA_DIR 和备份，重装后账号数据还在"
    echo "  2) 彻底清除：在 1 的基础上，再删镜像、数据目录（账号/导航数据/上传的图标）和脚本生成的所有文件"
    read -r -p "请选择 [1]（其他键取消）: " mode
    mode="${mode:-1}"
    case "$mode" in 1|2) ;; *) echo "已取消"; return 0 ;; esac

    echo "两种方式都会："
    echo "  - 删除容器 $CNAME、隧道容器 $TUNNEL_NAME、docker 网络 $NET、隧道 token"
    echo "  - 关闭本脚本放行过的防火墙端口：${FW_RULES:-（无）}"
    echo "  - 清理旧版脚本（Caddy/证书续期版）的遗留，并还原当时被停止的服务"
    echo "  （不会动你机器上其他的 cloudflared / sing-box / docker 镜像）"
    if [ "$mode" = "2" ]; then
        warn "彻底清除后，面板里的账号、导航数据、上传的图标都无法恢复！"
        read -r -p "确认请输入 yes: " a
        [ "$a" = "yes" ] || { echo "已取消"; return 0; }
        if [ -d "$DATA_DIR" ] && ask_yn "清除前先备份一份数据到 $HOME ? (y/N):" n; then backup_data; fi
    else
        ask_yn "确认卸载? (y/N):" n || { echo "已取消"; return 0; }
        if [ -d "$DATA_DIR" ] && ask_yn "卸载前再备份一份到 $HOME ? (y/N):" n; then backup_data; fi
    fi

    docker rm -f "$CNAME" "$TUNNEL_NAME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1
    rm -f "$TOKEN_FILE"
    ok "容器、网络、隧道 token 已清理"

    fw_close_all
    legacy_cleanup

    if [ "$mode" = "2" ]; then
        docker rmi "$IMAGE" "$TUNNEL_IMAGE" >/dev/null 2>&1   # 被别的容器占用的会自动跳过
        [ "${LEGACY_FOUND:-0}" = "1" ] && docker rmi caddy:2 certbot/certbot >/dev/null 2>&1
        ok "镜像已清理（仍被其他容器使用的会保留）"
        wipe_data_dir
        ok "数据目录已清除"
        backups="$(ls "$HOME"/sun-panel-backup*.tar.gz 2>/dev/null)"
        if [ -n "$backups" ]; then
            n="$(echo "$backups" | wc -l | tr -d ' ')"
            echo "$HOME 下还有 $n 个本脚本生成的备份："
            echo "$backups" | sed 's/^/    /'
            if ask_yn "同时删除这些备份? 删除后无法恢复 (y/N):" n; then
                rm -f "$HOME"/sun-panel-backup*.tar.gz
                ok "备份已删除"
            else
                echo "备份已保留"
            fi
        fi
    else
        DOMAIN=""; save_state
        echo "数据目录保留在 $DATA_DIR；备份文件在 $HOME/sun-panel-backup.tar.gz"
    fi

    echo "脚本无法代劳的部分："
    echo "  - Cloudflare 后台：删除这条隧道，以及它的公开主机名 / DNS 记录"
    echo "  - Docker 本身不会被卸载（其他服务可能在用）；确认不需要时可用系统包管理器自行卸载"
    ok "卸载完成"
}

# ---------------------------------------------------------------------
# 4-6. 状态 / 重启 / 重置密码
# ---------------------------------------------------------------------
do_status() {
    command -v docker >/dev/null 2>&1 || { warn "没有安装 Docker"; return 0; }
    load_state
    if ! container_exists "$CNAME"; then
        warn "尚未安装"
        return 0
    fi
    echo "容器状态:"
    docker ps -a --filter "name=^${CNAME}\$" --format '    {{.Names}}  {{.Status}}  {{.Ports}}'
    echo "镜像构建时间: $(docker inspect -f '{{.Image}}' "$CNAME" 2>/dev/null | xargs docker image inspect -f '{{.Created}}' 2>/dev/null | cut -c1-19)"
    if container_running "$CNAME" && alive; then echo "服务响应: 正常"; else echo "服务响应: 无响应"; fi
    if container_exists "$TUNNEL_NAME"; then
        docker ps -a --filter "name=^${TUNNEL_NAME}\$" --format '    {{.Names}}  {{.Status}}'
        if tunnel_connected; then echo "隧道连接: 已连接 Cloudflare"; else echo "隧道连接: 未确认（请看菜单 10 的隧道日志）"; fi
        echo "域名: ${DOMAIN:-未记录}"
    else
        echo "Cloudflare 隧道: 未配置"
    fi
    echo "脚本放行的防火墙端口: ${FW_RULES:-无}"
    show_access
}

do_restart() {
    need_root
    container_exists "$CNAME" || { warn "尚未安装"; return 0; }
    docker restart "$CNAME" >/dev/null && ok "已重启" || warn "重启失败"
    container_exists "$TUNNEL_NAME" && docker restart "$TUNNEL_NAME" >/dev/null 2>&1
    wait_up 30 && ok "服务已响应" || warn "30 秒内没有响应，请查看日志"
}

do_reset_pw() {
    need_root
    container_running "$CNAME" || { warn "容器没有在运行"; return 0; }
    docker exec -it -w /app "$CNAME" ./sun-panel -password-reset
}

# ---------------------------------------------------------------------
# 7. 修改端口 / 监听方式（防火墙自动同步）
# ---------------------------------------------------------------------
do_port() {
    need_root
    ensure_docker
    load_state
    container_exists "$CNAME" || { warn "尚未安装"; return 0; }
    local old_port="$PORT"
    echo "当前: 监听 $BIND  端口 $PORT"
    ask_port
    BIND_DEFAULT=1; ask_bind || return 0
    info "重建容器 ..."
    run_panel || die "容器启动失败"
    [ "$old_port" != "$PORT" ] && fw_close "$old_port/tcp"
    save_state
    sync_panel_fw
    wait_up 30 && ok "已生效" || warn "没有响应，请查看日志"
    show_access
}

# ---------------------------------------------------------------------
# 8. Cloudflare 隧道
#    - 专用容器 sunpanel-cloudflared，和 sing-box 的 argo 隧道是两条独立的隧道
#    - 与面板同在 docker 网络里，Cloudflare 后台的服务地址填 http://sun-panel:3002
# ---------------------------------------------------------------------
parse_token() {   # 容忍用户粘贴整条命令，只取最后一段并去掉引号
    local t="$1"
    t="${t##* }"; t="${t//\"/}"; t="${t//\'/}"; t="${t//$'\r'/}"
    echo "$t"
}

run_tunnel() {
    [ -f "$TOKEN_FILE" ] || return 1
    ensure_net || return 1
    docker rm -f "$TUNNEL_NAME" >/dev/null 2>&1
    docker run -d --name "$TUNNEL_NAME" --restart always --network "$NET" \
        --env-file "$TOKEN_FILE" "$TUNNEL_IMAGE" tunnel --no-autoupdate run >/dev/null
}

tunnel_connected() {
    docker logs --tail 50 "$TUNNEL_NAME" 2>&1 | grep -q "Registered tunnel connection"
}

wait_tunnel() {  # wait_tunnel 最长秒数
    local i=0
    while [ "$i" -lt "$1" ]; do
        container_running "$TUNNEL_NAME" || return 1
        tunnel_connected && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

selfcheck_domain() {   # 非阻塞自检：从本机访问一次公开地址
    local i code
    [ -n "$DOMAIN" ] || return 0
    command -v curl >/dev/null 2>&1 || return 0
    info "自检 https://$DOMAIN ..."
    for i in 1 2 3; do
        code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null)"
        case "$code" in
            2??|3??) ok "域名可以访问（HTTP $code）"; return 0 ;;
        esac
        sleep 5
    done
    warn "暂时访问不通（最后返回 ${code:-无响应}）。常见原因："
    echo "    502/503   公开主机名的服务地址填错，应为 http://$CNAME:$CPORT"
    echo "    530/1033  隧道还没连上，或 token 不对"
    echo "    无响应    DNS 还没生效，等几分钟再试；或域名没有在 Cloudflare 托管"
}

do_tunnel_setup() {
    echo "------------- 配置 Cloudflare 隧道 -------------"
    need_root
    ensure_docker
    load_state
    container_exists "$CNAME" || { warn "请先安装 Sun-Panel"; return 0; }

    echo "先在 Cloudflare 后台为面板【新建一条专用隧道】（不要复用 sing-box 的 argo 隧道）："
    echo "  1. 控制台左侧 Networking → Tunnels → Create a tunnel"
    echo "     （旧版界面在 Zero Trust → Networks → Tunnels）"
    echo "  2. 填名字（如 sunpanel）→ Create Tunnel，页面会给出一条安装命令，里面有 token（eyJ 开头的一长串）"
    echo "     只需要复制这条命令（或 token），【不要】在服务器上运行它，粘贴到下面给脚本就行"
    echo "  3. 脚本连上隧道后，回到该页面点 Continue；或者进入 Tunnels → 点你的隧道 → Routes 标签"
    echo "     → Add route → Published application，填写："
    echo "       子域名 + 域名：如 nav.example.com"
    echo "       Service URL：  http://$CNAME:$CPORT"
    echo "     （旧版界面：隧道的 Public Hostname 标签 → Add a public hostname，服务类型 HTTP，URL 填 $CNAME:$CPORT）"
    echo "     DNS 记录没有自动创建的话，手动加一条 CNAME：名称=子域名，目标=<隧道ID>.cfargotunnel.com，开启代理"
    echo
    local raw token h
    read -r -s -p "粘贴隧道 token（输入时不显示，回车取消）: " raw; echo
    [ -n "$raw" ] || { echo "已取消"; return 0; }
    token="$(parse_token "$raw")"
    case "$token" in
        *[!A-Za-z0-9_=.-]*|'') warn "token 里有不该出现的字符，请重新复制"; return 0 ;;
    esac
    [ "${#token}" -ge 60 ] || { warn "token 太短，看起来不完整，请重新复制"; return 0; }
    case "$token" in eyJ*) ;; *) warn "token 通常以 eyJ 开头，你这个不是；继续尝试，失败请检查是否复制对了" ;; esac

    read -r -p "你在后台设置的公开主机名（如 nav.example.com，用于显示和自检，可留空）: " h
    if [ -n "$h" ]; then
        case "$h" in
            *[!A-Za-z0-9.-]*|.*|*..*|-*|*.) warn "域名格式不对，已忽略"; h="" ;;
            *.*) ;;
            *) warn "域名格式不对，已忽略"; h="" ;;
        esac
    fi

    mkdir -p "$DATA_DIR"
    ( umask 077; printf 'TUNNEL_TOKEN=%s\n' "$token" > "$TOKEN_FILE" )
    chmod 600 "$TOKEN_FILE"

    info "启动隧道容器（首次需要拉取镜像）..."
    pull_image "$TUNNEL_IMAGE" >/dev/null 2>&1 || warn "拉取 cloudflared 镜像失败，尝试使用本地已有镜像"
    run_tunnel || { warn "隧道容器启动失败"; return 1; }
    if wait_tunnel 40; then
        ok "隧道已连接 Cloudflare"
    else
        warn "40 秒内没有看到连接成功。最近日志："
        docker logs --tail 15 "$TUNNEL_NAME" 2>&1 | sed 's/^/    /'
        echo "    常见原因：token 复制不完整 / 服务器连不上 Cloudflare（出站 7844 端口被限制）"
    fi
    DOMAIN="$h"
    save_state

    if [ "$BIND" != "none" ] && ask_yn "关闭面板的公网直连端口 $PORT，只通过隧道访问（推荐）? (Y/n):" y; then
        BIND="none"
        run_panel || die "容器重建失败"
        save_state
        sync_panel_fw
        wait_up 30 && ok "已改为不发布端口" || warn "没有响应，请查看日志"
    fi
    selfcheck_domain
    show_access
}

do_tunnel_update() {
    need_root
    ensure_docker
    container_exists "$TUNNEL_NAME" || { warn "没有配置隧道"; return 0; }
    local old new
    old="$(docker inspect -f '{{.Image}}' "$TUNNEL_NAME" 2>/dev/null)"
    pull_image "$TUNNEL_IMAGE" >/dev/null 2>&1 || { warn "拉取 cloudflared 镜像失败"; return 1; }
    new="$(docker image inspect -f '{{.Id}}' "$TUNNEL_IMAGE" 2>/dev/null)"
    if [ "$old" = "$new" ]; then ok "cloudflared 已经是最新"; return 0; fi
    run_tunnel || { warn "重建失败"; return 1; }
    wait_tunnel 40 && ok "cloudflared 已更新并连接" || warn "已更新，但没有确认连接成功，请看日志"
}

do_tunnel_remove() {
    need_root
    load_state
    container_exists "$TUNNEL_NAME" || { warn "没有配置隧道"; return 0; }
    ask_yn "停止并删除隧道容器（通过域名将无法访问）? (y/N):" n || return 0
    docker rm -f "$TUNNEL_NAME" >/dev/null 2>&1
    rm -f "$TOKEN_FILE"
    DOMAIN=""
    if [ "$BIND" = "none" ]; then
        if ask_yn "恢复直连 http://服务器IP:$PORT ？选 n 则仅本机可访问 (Y/n):" y; then
            BIND="0.0.0.0"
        else
            BIND="127.0.0.1"
        fi
        run_panel || warn "容器重建失败"
    fi
    save_state
    sync_panel_fw
    ok "隧道已移除；面板现在监听 $BIND:$PORT"
    echo "别忘了到 Cloudflare 后台删除这条隧道（脚本无法代劳）"
}

do_tunnel() {
    local c
    load_state
    container_exists "$CNAME" || { warn "请先安装 Sun-Panel"; return 0; }
    echo "  1) 配置 / 更换隧道 token"
    echo "  2) 更新 cloudflared 镜像"
    echo "  3) 移除隧道"
    read -r -p "请选择 [1]: " c
    case "${c:-1}" in
        1) do_tunnel_setup ;;
        2) do_tunnel_update ;;
        3) do_tunnel_remove ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------------
# 9-10. 备份 / 日志
# ---------------------------------------------------------------------
do_backup() {
    need_root
    [ -d "$DATA_DIR" ] || { warn "没有数据目录"; return 0; }
    backup_data
}

do_logs() {
    command -v docker >/dev/null 2>&1 || { warn "没有安装 Docker"; return 0; }
    local t
    echo "  1) Sun-Panel 日志"
    echo "  2) Cloudflare 隧道日志"
    read -r -p "请选择 [1]: " t
    case "${t:-1}" in
        1) docker logs --tail 50 "$CNAME" 2>&1 ;;
        2) docker logs --tail 50 "$TUNNEL_NAME" 2>&1 ;;
        *) warn "无效选择" ;;
    esac
}

# ---------------------------------------------------------------------
# 菜单
# ---------------------------------------------------------------------
while true; do
    echo
    menu "=========================================="
    menu "  VPS - Sun-Panel 管理脚本（Docker + CF 隧道）"
    menu "=========================================="
    menu "  1) 安装"
    menu "  2) 升级（拉取最新官方镜像，失败自动回滚）"
    menu_red "  3) 卸载（自动关闭防火墙端口）"
    menu "  4) 查看状态"
    menu "  5) 重启服务"
    menu "  6) 重置管理员密码"
    menu "  7) 修改端口 / 监听方式"
    menu "  8) Cloudflare 隧道（配置 / 更新 / 移除）"
    menu "  9) 备份数据"
    menu " 10) 查看日志"
    menu "  0) 退出"
    read -r -p "${G}请选择 [0-10]: ${R}" choice
    case "$choice" in
        1) ( do_install ) ;;
        2) ( do_upgrade ) ;;
        3) ( do_uninstall ) ;;
        4) ( do_status ) ;;
        5) ( do_restart ) ;;
        6) ( do_reset_pw ) ;;
        7) ( do_port ) ;;
        8) ( do_tunnel ) ;;
        9) ( do_backup ) ;;
        10) ( do_logs ) ;;
        0) echo "Bye."; exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
