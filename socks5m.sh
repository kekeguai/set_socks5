#!/bin/bash
# =====================================================================
# socks5m - 多用户 SOCKS5 代理管理脚本
# 基于 microsocks + systemd + iptables 流量统计
# 每个用户独占一个端口，支持：安装 / 添加 / 删除 / 改密码 / 改端口 /
#                         流量统计 / 重置统计 / 列表 / 卸载
# 支持系统：Debian / Ubuntu / CentOS / RHEL / Rocky / AlmaLinux
# =====================================================================

set -u

APP_NAME="socks5m"
BIN_PATH="/usr/local/sbin/socks5m"
MS_BIN="/usr/local/bin/microsocks"
CONF_DIR="/etc/socks5m"
USER_DB="${CONF_DIR}/users.db"          # 每行: 端口 用户名 密码
UNIT_FILE="/etc/systemd/system/socks5m@.service"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || err "请使用 root 或 sudo 运行"; }
svc()       { echo "socks5m@$1"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_name(){ [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; }
valid_pass(){ [[ "$1" =~ ^[A-Za-z0-9_.@%+=-]{6,64}$ ]]; }
rand_str()  { tr -dc "$1" </dev/urandom | head -c "$2"; }

get_ip() {
    curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 ip.sb || echo "无法获取"
}

port_listening() { ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
db_get()         { awk -v p="$1" '$1==p' "$USER_DB" 2>/dev/null; }
db_exists()      { [[ -n "$(db_get "$1")" ]]; }
db_remove()      { sed -i "/^$1 /d" "$USER_DB"; }
set_field() {    # 参数: 端口 字段序号 新值
    awk -v p="$1" -v i="$2" -v v="$3" '$1==p{$i=v} {print}' "$USER_DB" > "$USER_DB.tmp" \
        && mv "$USER_DB.tmp" "$USER_DB"
}

write_env() {    # 根据数据库生成 systemd 环境文件
    local n pw
    read -r _ n pw <<<"$(db_get "$1")"
    umask 077
    printf 'SOCKS_USER=%s\nSOCKS_PASS=%s\n' "$n" "$pw" > "$CONF_DIR/$1.env"
    chmod 600 "$CONF_DIR/$1.env"
}

# ---------- 防火墙 ----------
open_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$1/tcp" >/dev/null
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$1/tcp" >/dev/null
        firewall-cmd --reload >/dev/null
    else
        warn "未检测到活动防火墙，请自行确认端口 $1 已放行"
    fi
}
close_firewall() {
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
        ufw delete allow "$1/tcp" >/dev/null 2>&1
    elif command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --remove-port="$1/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ---------- 流量统计（iptables 无目标规则计数）----------
stat_add() {
    local p=$1 c="${APP_NAME}-$1"
    command -v iptables >/dev/null || return 0
    iptables -C INPUT  -p tcp --dport "$p" -m comment --comment "$c" 2>/dev/null \
        || iptables -I INPUT  -p tcp --dport "$p" -m comment --comment "$c"
    iptables -C OUTPUT -p tcp --sport "$p" -m comment --comment "$c" 2>/dev/null \
        || iptables -I OUTPUT -p tcp --sport "$p" -m comment --comment "$c"
}
stat_del() {
    local p=$1 c="${APP_NAME}-$1"
    command -v iptables >/dev/null || return 0
    while iptables -D INPUT  -p tcp --dport "$p" -m comment --comment "$c" 2>/dev/null; do :; done
    while iptables -D OUTPUT -p tcp --sport "$p" -m comment --comment "$c" 2>/dev/null; do :; done
}
get_bytes() {    # 参数: 端口 链名(INPUT/OUTPUT)
    iptables -w -nvxL "$2" 2>/dev/null \
        | awk -v s="/* ${APP_NAME}-$1 */" 'index($0,s){print $2; f=1; exit} END{if(!f) print 0}'
}
hsize() {
    awk -v b="$1" 'BEGIN{split("B KB MB GB TB",U," "); i=1; while(b>=1024 && i<5){b/=1024; i++}
                  printf "%.2f %s", b, U[i]}'
}

# ---------- 依赖与安装 ----------
install_deps() {
    info "安装依赖..."
    if command -v apt-get &>/dev/null; then
        apt-get update -y
        apt-get install -y git gcc make curl iptables iproute2
    elif command -v dnf &>/dev/null; then
        dnf install -y git gcc make curl iptables iproute
    elif command -v yum &>/dev/null; then
        yum install -y git gcc make curl iptables iproute
    else
        err "不支持的包管理器"
    fi
}

build_microsocks() {
    if [[ -x "$MS_BIN" ]]; then info "microsocks 已存在，跳过编译"; return; fi
    info "编译 microsocks..."
    local tmp; tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/rofl0r/microsocks.git "$tmp/microsocks" || err "克隆失败"
    make -C "$tmp/microsocks" || err "编译失败"
    install -m 755 "$tmp/microsocks/microsocks" "$MS_BIN"
    rm -rf "$tmp"
}

write_unit() {
    cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=socks5m SOCKS5 proxy on port %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/socks5m/%i.env
ExecStart=/usr/local/bin/microsocks -i 0.0.0.0 -p %i -u ${SOCKS_USER} -P ${SOCKS_PASS}
ExecStartPost=-/usr/local/sbin/socks5m _stat_add %i
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

cmd_install() {
    install_deps
    build_microsocks
    mkdir -p "$CONF_DIR"; touch "$USER_DB"; chmod 700 "$CONF_DIR"
    if [[ -f "$0" && "$(readlink -f "$0")" != "$BIN_PATH" ]]; then
        install -m 755 "$0" "$BIN_PATH"
    fi
    write_unit
    systemctl daemon-reload
    info "socks5m 安装完成，管理命令: socks5m {add|del|list|passwd|port|stats|reset|restart|uninstall}"
}

# ---------- 用户管理 ----------
print_info() {
    local p=$1 n pw
    read -r _ n pw <<<"$(db_get "$p")"
    local ip; ip=$(get_ip)
    echo "--------------------------------------------"
    echo " 服务器 IP : $ip"
    echo " 端口     : $p"
    echo " 用户名   : $n"
    echo " 密码     : $pw"
    echo " 连接串   : socks5://$n:$pw@$ip:$p"
    echo "--------------------------------------------"
}

cmd_add() {
    local p=${1:-$(shuf -i 10000-60000 -n 1)}
    local n=${2:-$(rand_str 'a-z0-9' 8)}
    local pw=${3:-$(rand_str 'A-Za-z0-9' 16)}
    valid_port "$p" || err "端口无效: $p"
    valid_name "$n" || err "用户名仅允许字母/数字/_.- 且 1-32 位"
    valid_pass "$pw" || err "密码仅允许字母/数字及 _.@%+=-，长度 6-64"
    db_exists "$p" && err "端口 $p 已被 socks5m 用户占用"
    port_listening "$p" && err "端口 $p 已被其他程序占用"
    if awk -v n="$n" '$2==n{f=1} END{exit !f}' "$USER_DB" 2>/dev/null; then
        err "用户名 $n 已存在"
    fi

    echo "$p $n $pw" >> "$USER_DB"
    write_env "$p"
    systemctl enable "$(svc "$p")" >/dev/null 2>&1
    systemctl restart "$(svc "$p")"
    sleep 1
    if ! systemctl is-active --quiet "$(svc "$p")"; then
        systemctl disable --now "$(svc "$p")" >/dev/null 2>&1
        db_remove "$p"; rm -f "$CONF_DIR/$p.env"
        err "服务启动失败，请执行 journalctl -u $(svc "$p") 查看日志"
    fi
    open_firewall "$p"
    info "用户添加成功"
    print_info "$p"
}

cmd_del() {
    local p=$1
    valid_port "$p" && db_exists "$p" || err "未找到端口 $p 的用户"
    systemctl disable --now "$(svc "$p")" >/dev/null 2>&1
    stat_del "$p"
    close_firewall "$p"
    db_remove "$p"
    rm -f "$CONF_DIR/$p.env"
    info "已删除端口 $p 的用户"
}

cmd_passwd() {
    local p=$1 pw=${2:-$(rand_str 'A-Za-z0-9' 16)}
    valid_port "$p" && db_exists "$p" || err "未找到端口 $p 的用户"
    valid_pass "$pw" || err "密码仅允许字母/数字及 _.@%+=-，长度 6-64"
    set_field "$p" 3 "$pw"
    write_env "$p"
    systemctl restart "$(svc "$p")"
    info "密码已修改"
    print_info "$p"
}

cmd_port() {
    local old=$1 new=$2
    valid_port "$old" && db_exists "$old" || err "未找到端口 $old 的用户"
    valid_port "$new" || err "新端口无效: $new"
    db_exists "$new" && err "端口 $new 已被占用"
    port_listening "$new" && err "端口 $new 已被其他程序占用"

    systemctl disable --now "$(svc "$old")" >/dev/null 2>&1
    stat_del "$old"
    close_firewall "$old"
    set_field "$old" 1 "$new"
    rm -f "$CONF_DIR/$old.env"
    write_env "$new"
    systemctl enable "$(svc "$new")" >/dev/null 2>&1
    systemctl restart "$(svc "$new")"
    open_firewall "$new"
    info "端口已由 $old 修改为 $new"
    print_info "$new"
}

cmd_list() {
    if [[ ! -s "$USER_DB" ]]; then info "暂无用户"; return; fi
    printf "%-8s %-16s %-20s %s\n" "端口" "用户名" "密码" "状态"
    while read -r p n pw; do
        local st; st=$(systemctl is-active "$(svc "$p")" 2>/dev/null)
        printf "%-8s %-16s %-20s %s\n" "$p" "$n" "$pw" "$st"
    done < "$USER_DB"
}

# ---------- 流量统计 ----------
cmd_stats() {
    local only=${1:-}
    if [[ ! -s "$USER_DB" ]]; then info "暂无用户"; return; fi
    printf "%-8s %-14s %-14s %-14s %-14s\n" "端口" "用户名" "上传(入站)" "下载(出站)" "合计"
    while read -r p n _; do
        [[ -n "$only" && "$only" != "$p" ]] && continue
        local up down
        up=$(get_bytes "$p" INPUT)
        down=$(get_bytes "$p" OUTPUT)
        printf "%-8s %-14s %-14s %-14s %-14s\n" "$p" "$n" \
            "$(hsize "$up")" "$(hsize "$down")" "$(hsize $((up+down)))"
    done < "$USER_DB"
    echo "（统计自上次重置或系统重启起累计，重启后计数清零）"
}

cmd_reset() {
    local p=${1:-}
    if [[ -n "$p" ]]; then
        valid_port "$p" && db_exists "$p" || err "未找到端口 $p 的用户"
        stat_del "$p"; stat_add "$p"
        info "端口 $p 流量统计已重置"
    else
        while read -r q _; do stat_del "$q"; stat_add "$q"; done < "$USER_DB"
        info "全部流量统计已重置"
    fi
}

# ---------- 卸载 ----------
cmd_uninstall() {
    read -rp "确认卸载 socks5m 并删除所有用户? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    if [[ -s "$USER_DB" ]]; then
        while read -r p _; do
            systemctl disable --now "$(svc "$p")" >/dev/null 2>&1
            stat_del "$p"
            close_firewall "$p"
        done < "$USER_DB"
    fi
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    rm -rf "$CONF_DIR"
    rm -f "$MS_BIN"
    info "socks5m 已卸载"
    rm -f "$BIN_PATH"
}

usage() {
    cat <<EOF
socks5m - 多用户 SOCKS5 管理脚本

用法:
  socks5m install [端口 用户名 密码]   安装环境并创建首个用户（不填则随机）
  socks5m add [端口 用户名 密码]       添加用户（每用户独占一个端口）
  socks5m del <端口>                   删除用户
  socks5m passwd <端口> [新密码]       修改密码（不填则随机生成）
  socks5m port <旧端口> <新端口>       修改端口
  socks5m list                         列出所有用户及运行状态
  socks5m stats [端口]                 查看流量统计
  socks5m reset [端口]                 重置流量统计（不填则全部重置）
  socks5m restart                      重启全部代理服务
  socks5m uninstall                    卸载
EOF
}

# ---------- 入口 ----------
case "${1:-help}" in
    help|-h|--help) usage ;;
    _stat_add)      stat_add "$2" ;;      # 由 systemd ExecStartPost 调用
    list|ls)        cmd_list ;;
    stats)          need_root; cmd_stats "${2:-}" ;;
    *)
        need_root
        cmd=$1; shift
        case "$cmd" in
            install)   cmd_install; cmd_add "$@" ;;
            add)       cmd_add "$@" ;;
            del|remove) cmd_del "$@" ;;
            passwd)    cmd_passwd "$@" ;;
            port)      [[ $# -eq 2 ]] || err "用法: socks5m port <旧端口> <新端口>"; cmd_port "$@" ;;
            reset)     cmd_reset "$@" ;;
            restart)   [[ -s "$USER_DB" ]] && while read -r p _; do systemctl restart "$(svc "$p")"; done < "$USER_DB"
                       info "服务已重启" ;;
            uninstall) cmd_uninstall ;;
            *)         usage ;;
        esac
        ;;
esac
