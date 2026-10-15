#!/usr/bin/env bash
# Sun-Panel 管理脚本（Docker + Cloudflare 隧道），需要 root：bash sunpanel-vps.sh
set -u

IMAGE="${SUNPANEL_IMAGE:-hslr/sun-panel:latest}"
CNAME="sun-panel"
TUNNEL_NAME="sunpanel-cloudflared"
TUNNEL_IMAGE="cloudflare/cloudflared:latest"
NET="sunpanel-net"
DATA_DIR="${SUNPANEL_DIR:-/opt/sun-panel}"
STATE_FILE="$DATA_DIR/.sunpanel-vps.env"
TOKEN_FILE="$DATA_DIR/.cf-tunnel.env"
LEGACY_CRON="${SUNPANEL_CRON_FILE:-/etc/cron.d/sunpanel-renew}"
ROLLBACK_TAG="sun-panel-rollback:prev"
SP_BIN="${SUNPANEL_SHORTCUT:-/usr/local/bin/sp}"
SP_MARK="sunpanel-vps-shortcut-v1"
IPV6_SYSCTL="/etc/sysctl.d/99-sunpanel-ipv6.conf"
IPV6_SUBNET="fd7a:5e6c:3b1d::/64"
MIRROR="${SUNPANEL_MIRROR:-}"
CPORT=3002
DEFAULT_PORT=3002

if [ -t 1 ]; then G=$'\033[1;92m'; Y=$'\033[1;93m'; RD=$'\033[1;91m'; PU=$'\033[1;95m'; R=$'\033[0m'
else G=""; Y=""; RD=""; PU=""; R=""; fi

info() { echo "➜ $*"; }
ok()   { echo "${G}✅ $*${R}"; }
warn() { echo "${Y}⚠️  $*${R}"; }
die()  { echo "${RD}❌ $*${R}" >&2; exit 1; }
menu() { echo "${G}$*${R}"; }
menu_purple() { echo "${PU}$*${R}"; }
note() { echo "${Y}$*${R}"; }
imp()  { echo "${RD}$*${R}"; }

has() { command -v "$1" >/dev/null 2>&1; }
drm() { docker rm -f "$@" >/dev/null 2>&1; }

ask_yn() {
    local a
    read -r -p "${G}$1 ${R}" a
    case "${a:-${2:-n}}" in y|Y) return 0 ;; *) return 1 ;; esac
}

net_is_v6() { [ "$(docker network inspect "$NET" -f '{{.EnableIPv6}}' 2>/dev/null)" = "true" ]; }

load_state() {
    PORT="$DEFAULT_PORT"; BIND="0.0.0.0"; DOMAIN=""; FW_RULES=""; TUNNEL_HOST=0; NET_MODE=""; PANEL_IMAGE=""
    # shellcheck disable=SC1090
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    if [ -z "${SUNPANEL_IMAGE:-}" ] && [ -n "$PANEL_IMAGE" ]; then IMAGE="$PANEL_IMAGE"; fi
    if [ -z "$NET_MODE" ]; then
        if net_is_v6; then NET_MODE="v6"; else NET_MODE="v4"; fi
    fi
    return 0
}

save_state() {
    mkdir -p "$DATA_DIR"
    cat > "$STATE_FILE" <<EOF
PORT="$PORT"
BIND="$BIND"
DOMAIN="$DOMAIN"
FW_RULES="$FW_RULES"
TUNNEL_HOST="$TUNNEL_HOST"
NET_MODE="$NET_MODE"
PANEL_IMAGE="$IMAGE"
EOF
}

need_root() {
    [ "$(id -u)" -eq 0 ] || die "请用 root 运行（或 sudo bash $0）"
}

ensure_docker() {
    if has docker; then
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
    has curl || die "需要 curl 才能下载安装脚本，请先安装 curl"
    curl -fsSL https://get.docker.com | sh || die "Docker 安装失败，请查看上面的报错"
    systemctl enable --now docker >/dev/null 2>&1
    docker info >/dev/null 2>&1 || die "Docker 已安装但服务未运行"
    ok "Docker 安装完成"
}

prep() { need_root; ensure_docker; load_state; }

container_exists()  { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

port_in_use() {
    if has ss; then
        ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
    elif has netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

port_owner() {
    has ss && ss -H -ltnp "sport = :$1" 2>/dev/null | head -n3 | sed 's/^/    /'
}

public_ip() {
    curl -fsS -m 6 https://api.ipify.org 2>/dev/null \
        || curl -fsS -m 6 https://ifconfig.me 2>/dev/null \
        || true
}

alive() {
    docker exec "$CNAME" wget -q -O /dev/null -T 3 "http://127.0.0.1:$CPORT/" >/dev/null 2>&1
}

wait_up() {
    local i
    for ((i = 0; i < $1; i++)); do
        container_running "$CNAME" && alive && return 0
        sleep 1
    done
    return 1
}

fw_backend() {
    if has ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
        echo ufw
    elif has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        echo firewalld
    elif has iptables \
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
    if has netfilter-persistent; then
        netfilter-persistent save >/dev/null 2>&1
    elif has service; then
        service iptables save >/dev/null 2>&1
    fi
    return 0
}

fw_open() {
    local spec="$1" port proto
    port="${spec%/*}"; proto="${spec#*/}"
    fw_has "$spec" && return 0
    case "$(fw_backend)" in
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

fw_close() {
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

ask_port() {
    local p tries
    echo "（对外端口只是映射到容器内的 $CPORT，$DEFAULT_PORT 是官方示例，不是强制要求，可改成任意未占用端口）"
    while true; do
        read -r -p "${G}对外端口 [${PORT:-$DEFAULT_PORT}]（输入 r 随机生成 10000 以上的端口）: ${R}" p
        p="${p:-${PORT:-$DEFAULT_PORT}}"
        case "$p" in
            r|R)
                for ((tries = 0; tries < 50; tries++)); do
                    p=$(( 10000 + (RANDOM * 32768 + RANDOM) % 55536 ))
                    port_in_use "$p" || break
                done
                if port_in_use "$p"; then warn "没找到空闲的随机端口，请手动输入"; continue; fi
                info "已随机选择端口 $p" ;;
        esac
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

ask_bind() {
    local s tunnel_on=0
    if [ "${TUNNEL_HOST:-0}" = "1" ]; then
        BIND="127.0.0.1"
        info "隧道使用宿主机网络模式，监听方式固定为 127.0.0.1（仅本机，外网只能走隧道）"
        return 0
    fi
    container_running "$TUNNEL_NAME" && tunnel_on=1
    echo "监听方式："
    echo "  1) 0.0.0.0    所有网卡，可用 http://服务器IP:端口 直接访问"
    echo "  2) 127.0.0.1  仅本机"
    [ "$tunnel_on" -eq 1 ] && echo "  3) 不发布端口  只能通过 Cloudflare 隧道访问（最安全，推荐）"
    read -r -p "${G}请选择 [1]: ${R}" s
    case "${s:-1}" in
        1) BIND="0.0.0.0" ;;
        2) BIND="127.0.0.1" ;;
        3) [ "$tunnel_on" -eq 1 ] && BIND="none" || { warn "隧道没在运行（或隧道用宿主机网络模式，需要发布端口），不能选 3"; return 1; } ;;
        *) warn "无效选择"; return 1 ;;
    esac
}

ensure_net() {
    docker network inspect "$NET" >/dev/null 2>&1 && return 0
    if [ "${NET_MODE:-v4}" = "v6" ]; then
        docker network create --ipv6 --subnet "$IPV6_SUBNET" "$NET" >/dev/null 2>&1 \
            || { warn "创建 IPv6 docker 网络 $NET 失败（Docker 版本过旧或 ip6tables 不可用？）"; return 1; }
    else
        docker network create "$NET" >/dev/null 2>&1 || { warn "创建 docker 网络 $NET 失败"; return 1; }
    fi
}

pull_image() {
    local img="$1" n
    for ((n = 1; n <= 3; n++)); do
        docker pull "$img" && return 0
        [ "$n" -lt 3 ] && { warn "拉取失败，3 秒后重试（第 $n/3 次）..."; sleep 3; }
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

run_panel() {
    local image="${1:-$IMAGE}"
    local -a pub=()
    ensure_net || return 1
    mkdir -p "$DATA_DIR/conf" "$DATA_DIR/database" "$DATA_DIR/uploads" || { warn "无法创建数据目录 $DATA_DIR"; return 1; }
    drm "$CNAME"
    [ "$BIND" != "none" ] && pub=(-p "${BIND}:${PORT}:${CPORT}")
    docker run -d --name "$CNAME" --restart always --network "$NET" \
        ${pub[@]+"${pub[@]}"} \
        -v "$DATA_DIR/conf:/app/conf" \
        -v "$DATA_DIR/database:/app/database" \
        -v "$DATA_DIR/uploads:/app/uploads" \
        "$image" >/dev/null
}

sync_panel_fw() {
    if [ "$BIND" = "0.0.0.0" ]; then fw_open "$PORT/tcp"; else fw_close "$PORT/tcp"; fi
}

apply_panel() {
    run_panel || die "容器重建失败"
    save_state
    sync_panel_fw
    wait_up 30 && ok "${1:-已生效}" || warn "没有响应，请查看日志"
}

pack_data() {
    local -a files=()
    local d
    for d in conf database uploads; do [ -e "$DATA_DIR/$d" ] && files+=("$d"); done
    [ "${#files[@]}" -gt 0 ] || return 2
    tar -czf "$1.tmp" -C "$DATA_DIR" "${files[@]}" && mv -f "$1.tmp" "$1" \
        || { rm -f "$1.tmp"; return 1; }
}

backup_data() {
    BACKUP_FILE=""
    [ -d "$DATA_DIR" ] || return 0
    local out="$HOME/sun-panel-backup.tar.gz"
    pack_data "$out"
    case $? in
        0) rm -f "$HOME"/sun-panel-backup-*.tar.gz
           BACKUP_FILE="$out"
           ok "数据已备份（覆盖旧备份）: $BACKUP_FILE" ;;
        2) return 0 ;;
        *) warn "备份失败（旧备份保持不变）"; return 1 ;;
    esac
}

show_access() {
    local ip
    if [ -n "$DOMAIN" ] && container_running "$TUNNEL_NAME"; then
        echo "${G}访问地址: https://$DOMAIN${R}"
    fi
    case "$BIND" in
        0.0.0.0)
            ip="$(public_ip)"
            echo "直连地址: http://${ip:-服务器IP}:$PORT"
            note "   （打不开请检查云厂商安全组是否放行 TCP $PORT；安全组不在服务器上，脚本改不了）" ;;
        127.0.0.1) echo "当前仅监听本机 127.0.0.1:$PORT" ;;
        none)      echo "未发布端口，只能通过 Cloudflare 隧道访问" ;;
    esac
}

do_install() {
    echo "------------- 安装 Sun-Panel（Docker）-------------"
    prep
    if container_exists "$CNAME"; then
        warn "已经安装过了。更新 / 切换版本请用菜单 2，重装请先卸载。"
        return 0
    fi

    ask_net_mode || die "网络类型选择无效"
    if [ "$NET_MODE" = "v6" ]; then
        ipv6_mode_notice
        ask_yn "继续? (y/N):" n || { info "已取消"; return 0; }
        prepare_ipv6_host || die "IPv6 模式准备失败（已回滚），可重新运行并选择 IPv4"
    fi
    if docker network inspect "$NET" >/dev/null 2>&1; then
        local have=v4
        net_is_v6 && have=v6
        [ "$have" = "$NET_MODE" ] || docker network rm "$NET" >/dev/null 2>&1 || warn "旧的 docker 网络 $NET 删除失败，可能仍有容器在用"
    fi

    ask_port
    ask_bind || die "监听方式无效"

    info "拉取镜像 $IMAGE ..."
    pull_image "$IMAGE" || die "镜像拉取失败（网络问题？可设置 SUNPANEL_MIRROR=加速站域名 再运行）"

    info "启动容器 ..."
    run_panel || die "容器启动失败"
    save_state
    sync_panel_fw

    wait_up 30 && ok "服务已正常响应" || warn "30 秒内没有响应，请用菜单 11 查看日志排查"
    if [ "$NET_MODE" = "v6" ]; then
        net_probe && ok "容器 IPv6 出网正常（在线更新 / 在线图标可用）" \
            || warn "容器 IPv6 出网测试没通过，可到菜单 9 查看 / 重试"
    fi

    echo "=============================================="
    ok "安装完成"
    show_access
    imp "默认账号: admin@sun.cc   默认密码: 12345678   —— 登录后请立刻修改！"
    note "说明：Docker 发布的端口会绕过 ufw/firewalld 的过滤；想真正限制访问，请用隧道 + 不发布端口。"
    echo "=============================================="

    ask_yn "现在配置 Cloudflare 隧道（用域名访问，不占 80/443）? (y/N):" n && do_tunnel_setup
}

image_repo() {
    case "${1##*/}" in
        *:*) echo "${1%:*}" ;;
        *)   echo "$1" ;;
    esac
}

list_remote_tags() {
    local repo="$1" first="${1%%/*}"
    case "$first" in *.*|*:*) return 0 ;; esac
    case "$repo" in */*) ;; *) repo="library/$repo" ;; esac
    curl -m 8 -fsS "https://hub.docker.com/v2/repositories/$repo/tags?page_size=20&ordering=last_updated" 2>/dev/null \
        | grep -o '"name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' | head -n 15 | tr '\n' ' '
}

image_created() {
    docker image inspect -f '{{.Created}}' "$1" 2>/dev/null | cut -c1-19
}

do_version_update() {
    echo "------------- 更新到指定版本 -------------"
    prep
    container_exists "$CNAME" || { warn "尚未安装，请先选择“安装”"; return 0; }

    local cur_img cur_id repo tags tag target new_id created
    cur_img="$(docker inspect -f '{{.Config.Image}}' "$CNAME" 2>/dev/null)"
    cur_id="$(docker inspect -f '{{.Image}}' "$CNAME" 2>/dev/null)"
    [ -n "$cur_id" ] || die "读取当前镜像失败，未做任何改动"
    repo="$(image_repo "$IMAGE")"

    echo "当前镜像：$cur_img（构建时间 $(image_created "$cur_id")）"
    note "面板网页里也可以直接在线更新；这里用来安装指定版本，或回退到旧版本。"
    tags="$(list_remote_tags "$repo")"
    [ -n "$tags" ] && echo "最近的版本（Docker Hub）：$tags"
    read -r -p "${G}输入要更新到的版本号，如 1.3.0（latest 为最新，回车取消）: ${R}" tag
    [ -n "$tag" ] || { echo "已取消"; return 0; }
    [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { warn "版本号格式不对"; return 1; }

    target="$repo:$tag"
    info "拉取镜像 $target ..."
    pull_image "$target" || { warn "镜像拉取失败（版本号不存在？网络问题？），未做任何改动（可设置 SUNPANEL_MIRROR=加速站域名 再试）"; return 1; }
    new_id="$(docker image inspect -f '{{.Id}}' "$target" 2>/dev/null)"
    created="$(image_created "$target")"

    if [ "$cur_id" = "$new_id" ]; then
        IMAGE="$target"; save_state
        ok "当前运行的已经是这个版本（$target，构建时间 $created），无需更新"
        return 0
    fi

    echo "将更新到 $target（构建时间 $created）"
    note "回退到旧版本时，若新版本已升级过数据库结构，旧版本可能无法启动；脚本会先备份数据，启动失败会自动回滚。"
    ask_yn "继续? (y/N):" n || { echo "已取消"; return 0; }

    backup_data
    docker tag "$cur_id" "$ROLLBACK_TAG" || die "无法给旧镜像打回滚标签，已停止（未做任何改动）"

    info "用 $target 重建容器 ..."
    if run_panel "$target" && wait_up 40; then
        IMAGE="$target"; save_state
        ok "已更新到 $target"
        docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1
    else
        warn "新版本启动失败或没有响应，回滚到旧镜像 ..."
        if run_panel "$ROLLBACK_TAG" && wait_up 30; then
            ok "已回滚，旧版本恢复运行"
        else
            warn "回滚后仍无响应，请用菜单 11 查看日志；数据备份: ${BACKUP_FILE:-无}（可用菜单 10 恢复）"
        fi
        return 1
    fi
}

legacy_cleanup() {
    local line what
    local -a cmd
    LEGACY_FOUND=0
    if container_exists sunpanel-caddy; then
        LEGACY_FOUND=1; drm sunpanel-caddy; ok "已删除旧版遗留的 Caddy 容器"
    fi
    if [ -f "$LEGACY_CRON" ]; then
        LEGACY_FOUND=1; rm -f "$LEGACY_CRON"; ok "已删除旧版遗留的证书续期定时任务"
    fi
    if [ -s "$DATA_DIR/.released" ]; then
        LEGACY_FOUND=1
        while IFS= read -r line; do
            case "$line" in
                systemd:*) cmd=(systemctl start "${line#*:}"); what="服务" ;;
                docker:*)  cmd=(docker start "${line#*:}");    what="容器" ;;
                *) continue ;;
            esac
            if "${cmd[@]}" >/dev/null 2>&1; then ok "已还原被旧版停止的$what $line"
            else warn "还原 $line 失败，请手动启动"; fi
        done < "$DATA_DIR/.released"
        rm -f "$DATA_DIR/.released"
    fi
    return 0
}

wipe_data_dir() {
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
    has docker || { warn "没有安装 Docker，无需卸载"; return 0; }
    load_state
    local mode a n backups
    echo "卸载方式："
    echo "  1) 保留数据：删容器/隧道/网络/防火墙规则，保留 $DATA_DIR 和备份，重装后账号数据还在"
    echo "  2) 彻底清除：在 1 的基础上，再删镜像、数据目录（账号/导航数据/上传的图标）和脚本生成的所有文件"
    read -r -p "${G}请选择 [1]（其他键取消）: ${R}" mode
    mode="${mode:-1}"
    case "$mode" in 1|2) ;; *) echo "已取消"; return 0 ;; esac

    note "两种方式都会："
    echo "  - 删除容器 $CNAME、隧道容器 $TUNNEL_NAME、docker 网络 $NET、隧道 token"
    echo "  - 关闭本脚本放行过的防火墙端口：${FW_RULES:-（无）}"
    echo "  - 清理旧版脚本（Caddy/证书续期版）的遗留，并还原当时被停止的服务"
    echo "  （不会动你机器上其他的 cloudflared / sing-box / docker 镜像）"
    if [ "$mode" = "2" ]; then
        warn "彻底清除后，面板里的账号、导航数据、上传的图标都无法恢复！"
        read -r -p "${G}确认请输入 yes: ${R}" a
        [ "$a" = "yes" ] || { echo "已取消"; return 0; }
        if [ -d "$DATA_DIR" ] && ask_yn "清除前先备份一份数据到 $HOME ? (y/N):" n; then backup_data; fi
    else
        ask_yn "确认卸载? (y/N):" n || { echo "已取消"; return 0; }
        if [ -d "$DATA_DIR" ] && ask_yn "卸载前再备份一份到 $HOME ? (y/N):" n; then backup_data; fi
    fi

    drm "$CNAME" "$TUNNEL_NAME"
    docker network rm "$NET" >/dev/null 2>&1
    docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1
    rm -f "$TOKEN_FILE"
    ok "容器、网络、隧道 token 已清理"

    fw_close_all
    legacy_cleanup

    if [ "$mode" = "2" ]; then
        docker rmi "$IMAGE" "$TUNNEL_IMAGE" >/dev/null 2>&1
        [ "$LEGACY_FOUND" = "1" ] && docker rmi caddy:2 certbot/certbot >/dev/null 2>&1
        ok "镜像已清理（仍被其他容器使用的会保留）"
        wipe_data_dir
        ok "数据目录已清除"
        remove_shortcut
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
        DOMAIN=""; TUNNEL_HOST=0; save_state
        echo "数据目录保留在 $DATA_DIR；备份文件在 $HOME/sun-panel-backup.tar.gz"
    fi

    note "脚本无法代劳的部分："
    echo "  - Cloudflare 后台：删除这条隧道，以及它的公开主机名 / DNS 记录"
    echo "  - Docker 本身不会被卸载（其他服务可能在用）；确认不需要时可用系统包管理器自行卸载"
    ok "卸载完成"
}

do_status() {
    has docker || { warn "没有安装 Docker"; return 0; }
    load_state
    container_exists "$CNAME" || { warn "尚未安装"; return 0; }
    echo "容器状态:"
    docker ps -a --filter "name=^${CNAME}\$" --format '    {{.Names}}  {{.Status}}  {{.Ports}}'
    echo "镜像构建时间: $(image_created "$(docker inspect -f '{{.Image}}' "$CNAME" 2>/dev/null)")"
    if container_running "$CNAME" && alive; then echo "服务响应: 正常"; else echo "服务响应: 无响应"; fi
    if container_exists "$TUNNEL_NAME"; then
        docker ps -a --filter "name=^${TUNNEL_NAME}\$" --format '    {{.Names}}  {{.Status}}'
        if tunnel_connected; then echo "隧道连接: 已连接 Cloudflare"; else echo "隧道连接: 未确认（请看菜单 11 的隧道日志）"; fi
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

do_port() {
    prep
    container_exists "$CNAME" || { warn "尚未安装"; return 0; }
    local old_port="$PORT"
    echo "当前: 监听 $BIND  端口 $PORT"
    ask_port
    ask_bind || return 0
    info "重建容器 ..."
    apply_panel
    [ "$old_port" != "$PORT" ] && fw_close "$old_port/tcp"
    show_access
}

parse_token() {
    local t="$1"
    t="${t##* }"; t="${t//\"/}"; t="${t//\'/}"; t="${t//$'\r'/}"
    echo "$t"
}

run_tunnel() {
    [ -f "$TOKEN_FILE" ] || return 1
    ensure_net || return 1
    drm "$TUNNEL_NAME"
    local net="$NET"
    local -a edge=()
    if [ "${TUNNEL_HOST:-0}" = "1" ]; then
        net="host"; edge=(--edge-ip-version 6)
    elif [ "${NET_MODE:-v4}" = "v6" ]; then
        edge=(--edge-ip-version 6)
    fi
    docker run -d --name "$TUNNEL_NAME" --restart always --network "$net" \
        --env-file "$TOKEN_FILE" "$TUNNEL_IMAGE" tunnel --no-autoupdate ${edge[@]+"${edge[@]}"} run >/dev/null
}

tunnel_connected() {
    docker logs --tail 50 "$TUNNEL_NAME" 2>&1 | grep -q "Registered tunnel connection"
}

wait_tunnel() {
    local i
    for ((i = 0; i < $1; i++)); do
        container_running "$TUNNEL_NAME" || return 1
        tunnel_connected && return 0
        sleep 1
    done
    return 1
}

selfcheck_domain() {
    local i code
    [ -n "$DOMAIN" ] && has curl || return 0
    info "自检 https://$DOMAIN ..."
    for i in 1 2 3; do
        code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$DOMAIN/" 2>/dev/null)"
        case "$code" in
            2??|3??) ok "域名可以访问（HTTP $code）"; return 0 ;;
        esac
        sleep 5
    done
    warn "暂时访问不通（最后返回 ${code:-无响应}）。常见原因："
    if [ "${TUNNEL_HOST:-0}" = "1" ]; then
        echo "    502/503   公开主机名的服务地址填错，应为 http://127.0.0.1:$PORT"
    else
        echo "    502/503   公开主机名的服务地址填错，应为 http://$CNAME:$CPORT"
    fi
    echo "    530/1033  隧道还没连上，或 token 不对"
    echo "    无响应    DNS 还没生效，等几分钟再试；或域名没有在 Cloudflare 托管"
}

do_tunnel_setup() {
    echo "------------- 配置 Cloudflare 隧道 -------------"
    prep
    container_exists "$CNAME" || { warn "请先安装 Sun-Panel"; return 0; }

    echo "先在 Cloudflare 后台为面板【新建一条专用隧道】（不要复用 sing-box 的 argo 隧道）："
    echo "  1. 控制台左侧 Networking → Tunnels → Create a tunnel"
    echo "     （旧版界面在 Zero Trust → Networks → Tunnels）"
    echo "  2. 填名字（如 sunpanel）→ Create Tunnel，页面会给出一条安装命令，里面有 token（eyJ 开头的一长串）"
    imp "     只需要复制这条命令（或 token），【不要】在服务器上运行它，粘贴到下面给脚本就行"
    echo "  3. 脚本连上隧道后，回到该页面点 Continue；或者进入 Tunnels → 点你的隧道 → Routes 标签"
    echo "     → Add route → Published application，填写："
    echo "       子域名 + 域名：如 nav.example.com"
    echo "       Service URL：  http://$CNAME:$CPORT"
    echo "     （旧版界面：隧道的 Public Hostname 标签 → Add a public hostname，服务类型 HTTP，URL 填 $CNAME:$CPORT）"
    echo "     DNS 记录没有自动创建的话，手动加一条 CNAME：名称=子域名，目标=<隧道ID>.cfargotunnel.com，开启代理"
    note "  ※ 纯 IPv6 / NAT64 的机器请先到菜单 9 切换为 IPv6 模式，隧道才连得上 Cloudflare"
    echo
    local raw token h
    read -r -p "${G}粘贴隧道 token（回车取消）: ${R}" raw
    [ -n "$raw" ] || { echo "已取消"; return 0; }
    token="$(parse_token "$raw")"
    case "$token" in
        *[!A-Za-z0-9_=.-]*|'') warn "token 里有不该出现的字符，请重新复制"; return 0 ;;
    esac
    [ "${#token}" -ge 60 ] || { warn "token 太短，看起来不完整，请重新复制"; return 0; }
    case "$token" in eyJ*) ;; *) warn "token 通常以 eyJ 开头，你这个不是；继续尝试，失败请检查是否复制对了" ;; esac

    local was_host="$TUNNEL_HOST"
    TUNNEL_HOST="${SUNPANEL_TUNNEL_HOST:-0}"
    [ "$TUNNEL_HOST" = "1" ] || TUNNEL_HOST=0

    read -r -p "${G}你在后台设置的公开主机名（如 nav.example.com，用于显示和自检，可留空）: ${R}" h
    if [ -n "$h" ]; then
        case "$h" in
            *[!A-Za-z0-9.-]*|.*|*..*|-*|*.) h="" ;;
            *.*) ;;
            *) h="" ;;
        esac
        [ -n "$h" ] || warn "域名格式不对，已忽略"
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
        note "    常见原因：token 复制不完整 / 服务器连不上 Cloudflare（出站 7844 端口被限制）"
        note "    纯 IPv6 / NAT64 机器：请到菜单 9 把网络模式切到 IPv6，再重试"
        note "    若日志里 precheck 的 TCP 443 / api.cloudflare.com 也失败，说明是【容器出网】有问题（DNS / 转发 / NAT），不是 token 的事："
        echo "      docker run --rm --network $NET busybox nslookup api.cloudflare.com"
        echo "      docker run --rm --network $NET busybox wget -T 8 -qO- https://api.cloudflare.com/cdn-cgi/trace"
    fi
    DOMAIN="$h"
    save_state

    if [ "$TUNNEL_HOST" = "1" ]; then
        if [ "$BIND" != "127.0.0.1" ]; then
            BIND="127.0.0.1"
            info "宿主机网络模式：面板改为只监听 127.0.0.1:$PORT（外网不可直连，仅隧道可访问）"
            apply_panel
        fi
        imp "★ Cloudflare 后台该隧道的 Service URL 请填：http://127.0.0.1:$PORT"
    elif [ "$BIND" != "none" ] && ask_yn "关闭面板的公网直连端口 $PORT，只通过隧道访问（推荐）? (Y/n):" y; then
        BIND="none"
        apply_panel "已改为不发布端口"
    fi
    if [ "$was_host" = "1" ] && [ "$TUNNEL_HOST" = "0" ]; then
        imp "★ 隧道已改为容器网络模式：Cloudflare 后台该隧道的 Service URL 请改回 http://$CNAME:$CPORT"
    fi
    selfcheck_domain
    show_access
}

do_tunnel_update() {
    need_root
    ensure_docker
    load_state
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
    drm "$TUNNEL_NAME"
    rm -f "$TOKEN_FILE"
    DOMAIN=""; TUNNEL_HOST=0
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
    note "别忘了到 Cloudflare 后台删除这条隧道（脚本无法代劳）"
}

do_tunnel() {
    local c
    load_state
    container_exists "$CNAME" || { warn "请先安装 Sun-Panel"; return 0; }
    echo "  1) 配置 / 更换隧道 token"
    echo "  2) 更新 cloudflared 镜像"
    echo "  3) 移除隧道"
    read -r -p "${G}请选择 [1]: ${R}" c
    case "${c:-1}" in
        1) do_tunnel_setup ;;
        2) do_tunnel_update ;;
        3) do_tunnel_remove ;;
        *) warn "无效选择" ;;
    esac
}

restore_data() {
    need_root
    local -a arr
    local f i pick src bad list prerestore="$HOME/sun-panel-backup.prerestore.tar.gz"
    mapfile -t arr < <(ls -t "$HOME"/sun-panel-backup.tar.gz "$HOME"/sun-panel-backup-*.tar.gz 2>/dev/null)

    echo "可用的备份："
    i=1
    for f in "${arr[@]}"; do
        menu "  $i) $f   ($(du -h "$f" | cut -f1), $(date -r "$f" '+%F %T'))"
        i=$((i + 1))
    done
    menu "  p) 指定其他备份文件路径（比如从别的服务器传过来的 .tar.gz）"
    [ "${#arr[@]}" -eq 0 ] && note "  （$HOME 下没有找到本脚本生成的备份）"
    read -r -p "${G}请选择（回车取消）: ${R}" pick
    case "$pick" in
        '') echo "已取消"; return 0 ;;
        p|P) read -r -p "${G}备份文件完整路径: ${R}" src; [ -n "$src" ] || { echo "已取消"; return 0; } ;;
        *[!0-9]*) warn "无效选择"; return 1 ;;
        *) [ "$pick" -ge 1 ] && [ "$pick" -le "${#arr[@]}" ] || { warn "无效选择"; return 1; }
           src="${arr[$((pick - 1))]}" ;;
    esac
    [ -f "$src" ] || { warn "找不到文件：$src"; return 1; }

    list="$(tar -tzf "$src" 2>/dev/null)" || { warn "不是有效的 tar.gz 备份文件"; return 1; }
    bad="$(grep -Ev '^(\./)?(conf|database|uploads)(/|$)' <<<"$list" | head -n1)"
    [ -z "$bad" ] || { warn "备份内容不符合预期（出现：$bad），已拒绝恢复"; return 1; }
    grep -Eq '(^|/)\.\.(/|$)' <<<"$list" && { warn "备份里含有不安全的路径，已拒绝恢复"; return 1; }

    imp "恢复会用备份覆盖当前面板数据（账号、书签、上传文件等）。"
    note "当前数据会先另存为 $prerestore（只保留最近一次）。"
    note "备份里没有的内容：隧道 token、端口 / 监听方式 / 网络模式。需要的话恢复后到菜单 8 / 7 / 9 重新设置。"
    ask_yn "确认恢复? (y/N):" n || { echo "已取消"; return 0; }

    mkdir -p "$DATA_DIR"
    pack_data "$prerestore"
    case $? in
        0) ok "当前数据已另存: $prerestore" ;;
        2) ;;
        *) warn "无法另存当前数据，已中止（没有改动任何数据）"; return 1 ;;
    esac

    container_exists "$CNAME" && docker stop "$CNAME" >/dev/null 2>&1
    rm -rf "$DATA_DIR/conf" "$DATA_DIR/database" "$DATA_DIR/uploads"
    if ! tar -xzf "$src" -C "$DATA_DIR"; then
        warn "解压失败"
        if [ -f "$prerestore" ]; then
            tar -xzf "$prerestore" -C "$DATA_DIR" && ok "已还原为恢复前的数据"
        fi
        container_exists "$CNAME" && docker start "$CNAME" >/dev/null 2>&1
        return 1
    fi
    ok "数据已恢复"

    if container_exists "$CNAME"; then
        docker restart "$CNAME" >/dev/null 2>&1
        wait_up 30 && ok "面板已重启，请用恢复后的账号登录" || warn "面板暂时没有响应，请用菜单 11 查看日志"
    else
        note "还没有安装面板：请先用菜单 1 安装，安装后会直接使用这份数据。"
    fi
}

do_backup() {
    need_root
    echo "------------- 备份与恢复 -------------"
    menu "  1) 备份数据（覆盖 $HOME/sun-panel-backup.tar.gz）"
    menu "  2) 恢复数据（重装后用）"
    local c
    read -r -p "${G}请选择（回车取消）: ${R}" c
    case "$c" in
        1) [ -d "$DATA_DIR" ] || { warn "没有数据目录"; return 0; }; backup_data ;;
        2) restore_data ;;
        '') echo "已取消" ;;
        *) warn "无效选择" ;;
    esac
}

do_logs() {
    has docker || { warn "没有安装 Docker"; return 0; }
    local t
    echo "  1) Sun-Panel 日志"
    echo "  2) Cloudflare 隧道日志"
    read -r -p "${G}请选择 [1]: ${R}" t
    case "${t:-1}" in
        1) docker logs --tail 50 "$CNAME" 2>&1 ;;
        2) docker logs --tail 50 "$TUNNEL_NAME" 2>&1 ;;
        *) warn "无效选择" ;;
    esac
}

net_probe() {
    docker run --rm --network "$NET" busybox wget -T 8 -qO- "http://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null | grep -q '^ip='
}

ask_net_mode() {
    local v4ok=0 v6ok=0 def=1 c
    info "检测宿主机出网 ..."
    curl -4 -m 6 -fsS "https://api.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1 && v4ok=1
    curl -6 -m 6 -fsS "https://api.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1 && v6ok=1
    [ "$v4ok" = "0" ] && [ "$v6ok" = "1" ] && def=2
    echo "服务器网络类型："
    menu "  1) IPv4  普通 VPS（默认）"
    menu "  2) IPv6  纯 IPv6 / NAT64 机器（IPv4 出不去：面板在线更新、在线图标、隧道都会连不上）"
    note "  检测结果：宿主机 IPv4 出网 $([ "$v4ok" = "1" ] && echo 正常 || echo 不通)，IPv6 出网 $([ "$v6ok" = "1" ] && echo 正常 || echo 不通)"
    read -r -p "${G}请选择 [$def]: ${R}" c
    case "${c:-$def}" in
        1) NET_MODE="v4" ;;
        2) NET_MODE="v6" ;;
        *) warn "无效选择"; return 1 ;;
    esac
}

ipv6_mode_notice() {
    note "IPv6 模式会："
    note "  1) 给出口网卡设置 accept_ra=2，再开启 IPv6 转发（写入 $IPV6_SYSCTL 持久化）"
    note "     —— 开转发后内核默认会不再接收路由通告，可能丢掉默认 IPv6 路由导致断连，accept_ra=2 就是防这个的"
    note "  2) docker 网络 $NET 使用 IPv6（子网 $IPV6_SUBNET，NAT66 出网）"
    imp  "  改网络有断连风险，建议确认能从云厂商控制台（VNC / 救援）进入服务器后再继续"
}

prepare_ipv6_host() {
    has ip6tables || { warn "没有 ip6tables，Docker 的 IPv6 NAT 需要它（apt install iptables）"; return 1; }
    info "检查宿主机自身的 IPv6 出网 ..."
    curl -6 -m 8 -fsS "https://api.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1 || { warn "宿主机 IPv6 出网不通，IPv6 模式用不了"; return 1; }
    ok "宿主机 IPv6 正常"

    local iface old_fwd old_ra
    iface=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
    [ -n "$iface" ] || { warn "找不到 IPv6 出口网卡"; return 1; }
    old_fwd=$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null || echo 0)
    old_ra=$(sysctl -n "net.ipv6.conf.$iface.accept_ra" 2>/dev/null || echo 1)
    sysctl -w "net.ipv6.conf.$iface.accept_ra=2" >/dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
    printf 'net.ipv6.conf.%s.accept_ra=2\nnet.ipv6.conf.all.forwarding=1\n' "$iface" > "$IPV6_SYSCTL"
    sleep 2
    if ! ip -6 route show default 2>/dev/null | grep -q . || ! curl -6 -m 8 -fsS "https://api.cloudflare.com/cdn-cgi/trace" >/dev/null 2>&1; then
        warn "开启转发后宿主机 IPv6 出网异常，已回滚设置"
        sysctl -w net.ipv6.conf.all.forwarding="$old_fwd" >/dev/null
        sysctl -w "net.ipv6.conf.$iface.accept_ra=$old_ra" >/dev/null
        rm -f "$IPV6_SYSCTL"
        return 1
    fi
    ok "IPv6 转发已开启，宿主机 IPv6 仍正常"
}

rebuild_net() {
    drm "$CNAME" "$TUNNEL_NAME"
    docker network rm "$NET" >/dev/null 2>&1
    ensure_net || return 1
    run_panel || return 1
    if [ -f "$TOKEN_FILE" ]; then
        run_tunnel || warn "隧道容器重建失败，请到菜单 8 处理"
    fi
    return 0
}

do_net_mode() {
    echo "------------- 网络模式（IPv4 / IPv6）-------------"
    prep
    container_exists "$CNAME" || { warn "请先安装 Sun-Panel（安装时会让你选择网络类型）"; return 0; }
    local cur="$NET_MODE" new c
    echo "当前网络模式：${cur/v/IPv}"
    menu "  1) IPv4  普通 VPS"
    menu "  2) IPv6  纯 IPv6 / NAT64 机器（容器靠 IPv6 出网）"
    read -r -p "${G}选择要切换到的模式（回车取消）: ${R}" c
    case "$c" in
        1) new="v4" ;;
        2) new="v6" ;;
        '') echo "已取消"; return 0 ;;
        *) warn "无效选择"; return 0 ;;
    esac
    [ "$new" = "$cur" ] && { ok "已经是 ${new/v/IPv} 模式，无需切换"; return 0; }

    if [ "$new" = "v6" ]; then
        ipv6_mode_notice
        note "  3) 重建面板容器（隧道若是容器网络模式也会重建）"
        ask_yn "继续? (y/N):" n || { info "已取消"; return 0; }
        prepare_ipv6_host || { warn "没有改动 docker 网络"; return 1; }
    else
        note "切回 IPv4 模式会重建 docker 网络和面板容器（隧道若是容器网络模式也会重建），数据不受影响。"
        ask_yn "继续? (y/N):" n || { info "已取消"; return 0; }
    fi

    NET_MODE="$new"
    if ! rebuild_net; then
        warn "切换失败，恢复为 ${cur/v/IPv} 模式"
        NET_MODE="$cur"
        rebuild_net || warn "恢复也没成功，请用菜单 11 查看日志，或再运行一次本菜单"
        return 1
    fi
    save_state
    wait_up 30 && ok "面板已重新启动" || warn "面板暂时没有响应，请查看日志"
    if [ "$new" = "v6" ]; then
        info "测试容器 IPv6 出网 ..."
        if net_probe; then
            ok "容器已能通过 IPv6 出网，可以试试在线更新 / 在线图标"
        else
            warn "容器 IPv6 出网测试没通过。可查看：docker network inspect $NET ；ip6tables -t nat -S POSTROUTING"
        fi
    else
        ok "已切换为 IPv4 模式"
    fi
}

install_shortcut() {
    [ "$(id -u)" -eq 0 ] || return 0
    local self="${BASH_SOURCE[0]:-$0}"
    [ -f "$self" ] && [ -r "$self" ] || return 0
    if [ -e "$SP_BIN" ] && ! grep -q "$SP_MARK" "$SP_BIN" 2>/dev/null; then
        warn "$SP_BIN 已存在且不是本脚本安装的，跳过快捷命令 sp"
        return 0
    fi
    [ -e "$SP_BIN" ] && cmp -s "$self" "$SP_BIN" && return 0
    mkdir -p "$(dirname "$SP_BIN")" 2>/dev/null
    if cp -f "$self" "$SP_BIN" 2>/dev/null && chmod 755 "$SP_BIN"; then
        ok "已安装快捷命令：以后在终端输入 sp 即可打开本菜单"
    else
        warn "快捷命令安装失败（不影响使用）"
    fi
}

remove_shortcut() {
    [ -e "$SP_BIN" ] && grep -q "$SP_MARK" "$SP_BIN" 2>/dev/null && rm -f "$SP_BIN" && ok "已删除快捷命令 sp"
    return 0
}

install_shortcut

while true; do
    echo
    menu "=========================================="
    menu "  VPS - Sun-Panel 管理脚本（Docker + CF 隧道）"
    menu "=========================================="
    menu "  1) 安装脚本"
    menu "  2) 更新到指定版本"
    imp  "  3) 卸载脚本"
    menu "  4) 查看状态"
    menu "  5) 重启服务"
    menu "  6) 重置管理员密码"
    menu "  7) 修改端口/监听方式"
    menu "  8) CF隧道管理"
    menu "  9) 网络模式切换"
    menu " 10) 备份与恢复"
    menu " 11) 查看日志"
    menu_purple "  0) 退出"
    [ -e "$SP_BIN" ] && note "  （快捷命令：在终端输入 sp 随时打开本菜单）"
    read -r -p "${G}请选择 [0-11]: ${R}" choice
    case "$choice" in
        1) ( do_install ) ;;
        2) ( do_version_update ) ;;
        3) ( do_uninstall ) ;;
        4) ( do_status ) ;;
        5) ( do_restart ) ;;
        6) ( do_reset_pw ) ;;
        7) ( do_port ) ;;
        8) ( do_tunnel ) ;;
        9) ( do_net_mode ) ;;
        10) ( do_backup ) ;;
        11) ( do_logs ) ;;
        0) echo "Bye."; exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
