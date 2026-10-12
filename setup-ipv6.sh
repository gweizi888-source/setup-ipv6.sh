#!/bin/bash
#===============================================================================
# Ubuntu 22.04 IPv6 一键配置脚本
# 功能：Dedibox 网卡 ::N/64 + dhclient；随机地址靠 nonlocal_bind + lo local /64
#
# 用法：
#   1. 改下面「服务商面板」参数
#   2. chmod +x setup-ipv6.sh && sudo ./setup-ipv6.sh
#   3. 以后日常管理只需:  ipv6   （交互菜单，不用记命令）
#===============================================================================

set -euo pipefail

SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# 仅打开交互菜单（不重装）
if [[ "${1:-}" == "menu" || "${1:-}" == "-m" ]]; then
    exec /usr/local/bin/ipv6 2>/dev/null || { echo "请先运行一次: sudo $SCRIPT_SELF"; exit 1; }
fi

# ======================== 服务商面板（换机器只改这里）========================
IPV6_PREFIX="2001:bc8:32d7:2004"                # 面板 IPv6，不要带 ::/64
DUID="00:03:00:01:91:77:b4:24:60:71"            # 服务商面板 DUID（只用这个，不推导）
IPV6_HOST_ID="${IPV6_HOST_ID:-2}"               # 主 IPv6 后缀，2 = ::2
# ============================================================================

# 以下自动检测，一般不用改
INTERFACE="${INTERFACE:-}"
IPV4_ADDR="${IPV4_ADDR:-}"
IPV4_GATEWAY="${IPV4_GATEWAY:-}"
IPV6_BASE_ADDR="${IPV6_BASE_ADDR:-}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8,8.8.4.4}"           # Google Public DNS（IPv4）
DNS_SERVERS_V6="${DNS_SERVERS_V6:-2001:4860:4860::8888,2001:4860:4860::8844}"  # Google（IPv6）
RANDOM_ADDR_COUNT="${RANDOM_ADDR_COUNT:-5}"     # 测 IP 时随机生成几个地址（不往网卡 add）
IPV6_CHECK_URL="${IPV6_CHECK_URL:-https://api6.ipify.org}"  # 查 IP 接口
IPV6_CHECK_HOST="${IPV6_CHECK_HOST:-api6.ipify.org}"
ENABLE_NONLOCAL_BIND=true
DHCLIENT_BIN="${DHCLIENT_BIN:-/sbin/dhclient}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [[ $EUID -ne 0 ]]; then
    log_error "请使用 root 运行: sudo $0"
    exit 1
fi

if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    log_warn "未检测到 Ubuntu，脚本针对 Ubuntu 22.04 + netplan 编写，请自行核对"
fi

# ---------- 校验服务商参数 ----------
require_provider_params() {
    if [[ -z "$DUID" ]]; then
        log_error "请在本脚本顶部填写 DUID（服务商面板复制）"
        exit 1
    fi
    if [[ -z "$IPV6_PREFIX" ]]; then
        log_error "请在本脚本顶部填写 IPV6_PREFIX（服务商面板复制，不要带 ::/64）"
        exit 1
    fi

    IPV6_PREFIX="${IPV6_PREFIX%/64}"
    IPV6_PREFIX="${IPV6_PREFIX%::}"
}

# ---------- 自动检测本机网络参数 ----------
detect_default_interface() {
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "$iface" && -d "/sys/class/net/$iface" ]]; then
        echo "$iface"
        return
    fi
    for iface in /sys/class/net/*; do
        iface=$(basename "$iface")
        [[ "$iface" == "lo" ]] && continue
        [[ "$(cat "/sys/class/net/$iface/operstate" 2>/dev/null)" == "up" ]] || continue
        ip -4 addr show dev "$iface" scope global 2>/dev/null | grep -q 'inet ' && { echo "$iface"; return; }
    done
}

detect_ipv4_addr() {
    local iface="$1"
    ip -4 addr show dev "$iface" scope global 2>/dev/null | awk '/inet / {print $2; exit}'
}

detect_ipv4_gateway() {
  ip -4 route show default 2>/dev/null | awk '{print $3; exit}'
}

is_valid_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

detect_dns_servers() {
    local f ip
    for f in /run/systemd/resolve/resolv.conf /etc/resolv.conf; do
        [[ -f "$f" ]] || continue
        while read -r ip; do
            is_valid_ipv4 "$ip" && echo "$ip"
        done < <(awk '/^nameserver / {print $2}' "$f" | grep -v '^127\.')
    done | sort -u | paste -sd, -
}

filter_dns_servers() {
    local raw="$1" own="$2" filtered="" d
    if [[ -z "$raw" ]]; then
        echo "8.8.8.8,8.8.4.4"
        return
    fi
    IFS=',' read -ra arr <<< "$raw"
    for d in "${arr[@]}"; do
        d="${d// /}"
        is_valid_ipv4 "$d" || continue
        [[ "$d" == "$own" ]] && continue
        [[ "$filtered" == *"$d"* ]] && continue
        filtered="${filtered:+$filtered,}$d"
    done
    [[ -n "$filtered" ]] || filtered="8.8.8.8,8.8.4.4"
    echo "$filtered"
}

prefix_from_ipv6_cidr() {
    local cidr="$1" addr plen
    addr="${cidr%%/*}"
    plen="${cidr##*/}"
    [[ "$plen" == "$cidr" ]] && plen=64
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$addr" "$plen" <<'PY'
import ipaddress, sys
net = ipaddress.IPv6Network(f"{sys.argv[1]}/{sys.argv[2]}", strict=False)
n = str(net.network_address)
# /64 前缀取前 4 段
parts = n.split(':')
while len(parts) < 8:
    idx = parts.index('') if '' in parts else len(parts)
    parts.insert(idx, '0')
print(':'.join(parts[:4]))
PY
        return
    fi
    if [[ "$addr" == *::* ]]; then
        echo "${addr%%::*}"
    else
        echo "$addr" | awk -F: '{print $1":"$2":"$3":"$4}'
    fi
}

detect_ipv6_prefix_from_iface() {
    local iface="$1" cidr
    while read -r cidr; do
        [[ -z "$cidr" ]] && continue
        prefix_from_ipv6_cidr "$cidr"
        return
    done < <(ip -6 addr show dev "$iface" scope global 2>/dev/null | awk '/inet6/ {print $2}')
}

detect_ipv6_prefix_from_routes() {
    local iface="$1" cidr
    while read -r cidr; do
        [[ "$cidr" == fe80::* ]] && continue
        prefix_from_ipv6_cidr "$cidr"
        return
    done < <(ip -6 route show dev "$iface" 2>/dev/null | awk '/^[0-9a-fA-F]/ {print $1}')
}

detect_ipv6_prefix_from_leases() {
    local cidr prefix
    for f in /var/lib/dhcp/dhclient6.leases /var/lib/dhcp/dhclient.leases /var/lib/dhcp/dhclient6.lease; do
        [[ -f "$f" ]] || continue
        cidr=$(grep -oE 'prefix [0-9a-f:]+/[0-9]+' "$f" 2>/dev/null | awk '{print $2}' | head -1)
        [[ -n "$cidr" ]] && { prefix_from_ipv6_cidr "$cidr"; return; }
        cidr=$(grep -oE 'ia-na [0-9a-f:]+/[0-9]+' "$f" 2>/dev/null | awk '{print $2}' | head -1)
        [[ -n "$cidr" ]] && { prefix_from_ipv6_cidr "$cidr"; return; }
    done
}

detect_ipv6_prefix_from_netplan() {
    local cidr saved
    for f in /etc/netplan/*.yaml; do
        [[ -f "$f" ]] || continue
        cidr=$(grep -oE '[0-9a-fA-F:]+/[0-9]+' "$f" 2>/dev/null | grep ':' | grep -v '::1/128' | head -1)
        [[ -n "$cidr" && "$cidr" == *:* ]] && { prefix_from_ipv6_cidr "$cidr"; return; }
    done
    if [[ -f /etc/ipv6-random.conf ]]; then
        saved=$(grep -E '^IPV6_PREFIX=' /etc/ipv6-random.conf | cut -d= -f2- | tr -d '"')
        [[ -n "$saved" ]] && echo "$saved"
    fi
}

try_dhclient_for_prefix() {
    local iface="$1" duid="$2" tmpconf
    log_info "尝试运行 dhclient 获取 IPv6 前缀委派 ..."
    mkdir -p /etc/dhcp /var/lib/dhcp
    tmpconf=$(mktemp)
    cat > "$tmpconf" <<EOF
interface "${iface}" {
  send dhcp6.client-id ${duid};
}
EOF
    pkill -f "dhclient.*${iface}" 2>/dev/null || true
    sleep 1
    "$DHCLIENT_BIN" -cf "$tmpconf" -6 -P -pf "/var/run/dhclient6-${iface}.pid" -lf "/var/lib/dhcp/dhclient6.leases" "$iface" 2>/dev/null || true
    sleep 3
    cp -a "$tmpconf" /etc/dhcp/dhclient6.conf 2>/dev/null || true
    rm -f "$tmpconf"
    detect_ipv6_prefix_from_leases || detect_ipv6_prefix_from_iface "$iface" || detect_ipv6_prefix_from_routes "$iface"
}

auto_detect_all() {
    [[ -z "$INTERFACE" ]] && INTERFACE=$(detect_default_interface || true)
    [[ -n "$INTERFACE" ]] || { log_error "无法自动检测网卡，请设置: INTERFACE=eth0 $0"; exit 1; }

    [[ -z "$IPV4_ADDR" ]] && IPV4_ADDR=$(detect_ipv4_addr "$INTERFACE" || true)
    [[ -n "$IPV4_ADDR" ]] || { log_error "网卡 $INTERFACE 上未找到 IPv4，请先配置 IPv4 或设置 IPV4_ADDR"; exit 1; }

    [[ -z "$IPV4_GATEWAY" ]] && IPV4_GATEWAY=$(detect_ipv4_gateway || true)
    if [[ -z "$IPV4_GATEWAY" && "$IPV4_ADDR" == */* ]]; then
        local ip="${IPV4_ADDR%%/*}"
        IPV4_GATEWAY="${ip%.*}.1"
        log_warn "未检测到默认网关，推测为 $IPV4_GATEWAY"
    fi

    [[ -z "$DNS_SERVERS" ]] && DNS_SERVERS="8.8.8.8,8.8.4.4"
    DNS_SERVERS=$(filter_dns_servers "$DNS_SERVERS" "${IPV4_ADDR%%/*}")

    require_provider_params

    [[ -z "$IPV6_BASE_ADDR" ]] && IPV6_BASE_ADDR="${IPV6_PREFIX}::${IPV6_HOST_ID}"

    log_info "配置参数:"
    echo "  网卡:     $INTERFACE          （自动）"
    echo "  IPv4:     $IPV4_ADDR    （自动）"
    echo "  网关:     ${IPV4_GATEWAY:-（无）}       （自动）"
    echo "  DNS:      ${DNS_SERVERS} / ${DNS_SERVERS_V6}  （Google）"
    echo "  DUID:     $DUID  （服务商面板）"
    echo "  IPv6前缀: ${IPV6_PREFIX}::/64  （服务商面板）"
    echo "  主IPv6:   $IPV6_BASE_ADDR"
    echo ""
}

# 检测 dhclient
if [[ ! -x "$DHCLIENT_BIN" ]]; then
    DHCLIENT_BIN="$(command -v dhclient || true)"
fi
if [[ -z "$DHCLIENT_BIN" ]]; then
    log_info "安装 isc-dhcp-client ..."
    apt-get update -qq
    apt-get install -y isc-dhcp-client curl
    DHCLIENT_BIN="$(command -v dhclient)"
fi
command -v curl >/dev/null 2>&1 || apt-get install -y curl

auto_detect_all

# ---------- 1. dhclient6 配置 ----------
log_info "写入 /etc/dhcp/dhclient6.conf"
mkdir -p /etc/dhcp
cat > /etc/dhcp/dhclient6.conf <<EOF
# 由 setup-ipv6.sh 生成
interface "${INTERFACE}" {
  send dhcp6.client-id ${DUID};
}
EOF

# ---------- 2. systemd dhclient 服务 ----------
log_info "创建 dhclient systemd 服务"
cat > /etc/systemd/system/dhclient-ipv6.service <<EOF
[Unit]
Description=DHCPv6 client (DUID prefix delegation)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Restart=always
RestartSec=10
ExecStart=${DHCLIENT_BIN} -cf /etc/dhcp/dhclient6.conf -6 -P -v ${INTERFACE}
ExecStop=${DHCLIENT_BIN} -x -pf /var/run/dhclient6.pid

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable dhclient-ipv6.service

# ---------- 3. netplan（独立文件，避免被 cloud-init 覆盖）----------
log_info "配置 netplan"
NETPLAN_BACKUP="/etc/netplan/backup.$(date +%Y%m%d%H%M%S)"
mkdir -p "$NETPLAN_BACKUP"
for f in /etc/netplan/*.yaml; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "99-dedibox-ipv6.yaml" ]] && continue
    cp -a "$f" "$NETPLAN_BACKUP/" && rm -f "$f"
done
log_info "旧 netplan 已备份到 $NETPLAN_BACKUP"

# 禁止 cloud-init 再次覆盖网络
mkdir -p /etc/cloud/cloud.cfg.d
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

NETPLAN_FILE="/etc/netplan/99-dedibox-ipv6.yaml"

IFS=',' read -ra DNS_ARR <<< "$DNS_SERVERS"
DNS_YAML=""
for d in "${DNS_ARR[@]}"; do
    d="${d// /}"
    is_valid_ipv4 "$d" || continue
    DNS_YAML="${DNS_YAML}        - ${d}"$'\n'
done
IFS=',' read -ra DNS6_ARR <<< "$DNS_SERVERS_V6"
for d in "${DNS6_ARR[@]}"; do
    d="${d// /}"
    [[ -n "$d" ]] || continue
    DNS_YAML="${DNS_YAML}        - ${d}"$'\n'
done
[[ -n "$DNS_YAML" ]] || DNS_YAML="        - 8.8.8.8"$'\n'"        - 8.8.4.4"$'\n'"        - 2001:4860:4860::8888"$'\n'"        - 2001:4860:4860::8844"$'\n'

cat > "$NETPLAN_FILE" <<EOF
# 由 setup-ipv6.sh 生成 — Dedibox 官方：网卡 ::${IPV6_HOST_ID}/64 + default via fe80::1
network:
  version: 2
  renderer: networkd
  ethernets:
    ${INTERFACE}:
      dhcp4: no
      dhcp6: no
      accept-ra: true
      addresses:
        - "${IPV4_ADDR}"
        - "${IPV6_BASE_ADDR}/64"
      nameservers:
        addresses:
${DNS_YAML}
      routes:
        - to: default
          via: ${IPV4_GATEWAY}
          on-link: true
        - to: "::/0"
          via: "fe80::1"
          on-link: true
EOF

chmod 600 "$NETPLAN_FILE"

# ---------- 4. sysctl：RA / 非本地 bind ----------
log_info "配置 sysctl"
SYSCTL_DROP="/etc/sysctl.d/99-ipv6-random.conf"
cat > "$SYSCTL_DROP" <<EOF
# 由 setup-ipv6.sh 生成
# Dedibox 官方：有静态 IPv4 时 accept_ra=2 才能正常收 RA / 连 fe80::1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
net.ipv6.conf.${INTERFACE}.accept_ra = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.${INTERFACE}.rp_filter = 2
EOF

if [[ "$ENABLE_NONLOCAL_BIND" == "true" ]]; then
    cat >> "$SYSCTL_DROP" <<EOF

# 允许绑定/使用尚未 ip addr add 的段内地址（段已路由到本机时生效）
net.ipv6.ip_nonlocal_bind = 1
EOF
fi

sysctl --system >/dev/null 2>&1 || true

# ---------- 4b. Dedibox 网卡 /64 + lo local /64（随机地址双核心）----------
log_info "安装 ipv6-smart-apply（网卡主 IPv6 + lo local /64 随机出站）"

cat > /usr/local/bin/ipv6-smart-apply <<'SCRIPT'
#!/bin/bash
# 双核心（与 HE 隧道相同）：
#   1) 主 IPv6/64 在物理网卡 + default via fe80::1（Dedibox 官方，保证 ::N 能通）
#   2) local PREFIX::/64 dev lo + ip_nonlocal_bind（段内随机地址不 add 网卡也能出站）
set -euo pipefail
CONF="/etc/ipv6-random.conf"
[[ -f "$CONF" ]] && source "$CONF"

IFACE="${1:-${INTERFACE:?}}"
PREFIX="${IPV6_PREFIX:?}"
SRC="${IPV6_BASE_ADDR:?}"
GW="${IPV6_GATEWAY:-fe80::1}"
PREFIX64="${PREFIX}::/64"

log() { echo "[ipv6-smart-apply] $*"; }

flush_ipv6_default() {
    local i=0
    while ip -6 route show default 2>/dev/null | grep -q . && [[ $i -lt 20 ]]; do
        ip -6 route del default 2>/dev/null || true
        i=$((i + 1))
    done
}

clean_stale_lo_routes() {
    local cidr
    while read -r cidr; do
        [[ "$cidr" == "${PREFIX64}" ]] && continue
        [[ "$cidr" == "${PREFIX}"* ]] || continue
        ip -6 route del local "$cidr" dev lo 2>/dev/null || true
    done < <(ip -6 route show table local 2>/dev/null | awk '/^local '"${PREFIX}"'/ {print $2}')
}

remove_lo_prefix_addrs() {
    ip -6 addr show dev lo 2>/dev/null | awk '/inet6/ {print $2}' | while read -r cidr; do
        [[ "$cidr" == "${PREFIX}"* ]] || continue
        ip -6 addr del "$cidr" dev lo 2>/dev/null || true
    done
}

clean_iface_extra_v6() {
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '/inet6/ {print $2}' | while read -r cidr; do
        [[ "$cidr" == "${SRC}/64" || "$cidr" == "${SRC}/128" ]] && continue
        [[ "$cidr" == "${PREFIX}"* ]] || continue
        ip -6 addr del "$cidr" dev "$IFACE" 2>/dev/null || true
    done
}

ensure_iface_addr() {
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -qF "${SRC}/" && return 0
    ip -6 addr add "${SRC}/64" dev "$IFACE" nodad 2>/dev/null || \
        ip -6 addr replace "${SRC}/64" dev "$IFACE" nodad
}

apply_lo_local() {
    ip -6 route replace local "${PREFIX64}" dev lo
}

ensure_default() {
    # 不 flush：保留 RA 下发的 nexthop（随机 --interface 出站常依赖 multipath default）
    if ! ip -6 route show default 2>/dev/null | grep -q .; then
        ip -6 route add default via "$GW" dev "$IFACE" onlink 2>/dev/null || true
    elif ! ip -6 route show default 2>/dev/null | grep -q "via ${GW}.*dev ${IFACE}"; then
        ip -6 route add default via "$GW" dev "$IFACE" onlink 2>/dev/null || true
    fi
}

verify_ok() {
    ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -qF "${SRC}/" && \
    ip -6 route show table local 2>/dev/null | grep -q "local ${PREFIX64} dev lo" && \
    ip -6 route show default 2>/dev/null | grep -q "via ${GW}.*dev ${IFACE}"
}

log "应用 ${SRC}/64@${IFACE} + default + local ${PREFIX64} dev lo ..."
clean_stale_lo_routes
remove_lo_prefix_addrs
clean_iface_extra_v6
ensure_iface_addr
ensure_default
apply_lo_local

if verify_ok; then
    log "完成"
    exit 0
fi

sleep 1
ensure_iface_addr
ensure_default
apply_lo_local
verify_ok || {
    log "失败。请执行: ip -6 route show table local | grep ${PREFIX}"
    ip -6 route show table local 2>/dev/null | grep "$PREFIX" || true
    exit 1
}
log "完成（重试成功）"
SCRIPT
chmod +x /usr/local/bin/ipv6-smart-apply

# 合并为一个服务，避免两个 service 抢改路由
cat > /etc/systemd/system/ipv6-routes.service <<EOF
[Unit]
Description=IPv6 routes: iface /64 + lo local /64 for random bind
After=network-online.target netplan-wait-online.service dhclient-ipv6.service
Wants=network-online.target
# 等 RA 下发 default nexthop 后再加 lo local
ExecStartPre=/bin/sleep 3

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/ipv6-smart-apply ${INTERFACE}

[Install]
WantedBy=multi-user.target
EOF

# 停用旧的双 service
systemctl disable ipv6-local-route.service ipv6-default-src.service 2>/dev/null || true
systemctl stop ipv6-local-route.service ipv6-default-src.service 2>/dev/null || true
rm -f /etc/systemd/system/ipv6-local-route.service
rm -f /etc/systemd/system/ipv6-default-src.service
rm -f /usr/local/bin/ipv6-apply-default-src

systemctl daemon-reload
systemctl enable ipv6-routes.service

# 交互式管理菜单（以后只记: ipv6）
cat > /usr/local/bin/ipv6 <<'MENU'
#!/bin/bash
CONF="/etc/ipv6-random.conf"
[[ -f "$CONF" ]] && source "$CONF"

if [[ $EUID -ne 0 ]]; then
    echo "请用 root 运行: sudo ipv6"
    exit 1
fi

show_status() {
    echo ""
    echo "========== IPv6 状态 =========="
    [[ -f "$CONF" ]] && echo "  前缀:     ${IPV6_PREFIX:-?}::/64"
    [[ -f "$CONF" ]] && echo "  主 IPv6:  ${IPV6_BASE_ADDR:-?}"
    [[ -f "$CONF" ]] && echo "  网卡:     ${INTERFACE:-?}"
    echo ""
    echo "--- 路由 ---"
    ip -6 route show 2>/dev/null || true
    echo ""
    echo "--- lo local（随机 IP 必需）---"
    ip -6 route show table local 2>/dev/null | grep -E "${IPV6_PREFIX:-XXXX}::/64" || echo "  （缺失！sudo ipv6 选 1）"
    echo ""
    echo "--- nonlocal_bind ---"
    sysctl net.ipv6.ip_nonlocal_bind 2>/dev/null || true
    echo ""
    echo "--- 网卡 IPv6 ---"
    ip -6 addr show dev "${INTERFACE:-enp1s0f0}" 2>/dev/null | grep inet6 || true
    echo ""
    systemctl is-active dhclient-ipv6 ipv6-routes 2>/dev/null | paste -sd' ' - | \
        xargs -r echo "服务 dhclient-ipv6 / ipv6-routes:"
}

while true; do
    echo ""
    echo "╔══════════════════════════════════════╗"
    echo "║         IPv6 管理（交互菜单）         ║"
    echo "╠══════════════════════════════════════╣"
    echo "║  1) 修复 IPv6 路由（乱了点这个）      ║"
    echo "║  2) 查看当前状态                      ║"
    echo "║  3) 测随机 IP 出站                    ║"
    echo "║  4) 重跑完整安装                      ║"
    echo "║  0) 退出                              ║"
    echo "╚══════════════════════════════════════╝"
    read -r -p "请输入选项 [0-4]: " choice
    case "$choice" in
        1)
            echo ""
            if command -v ipv6-smart-apply >/dev/null 2>&1; then
                ipv6-smart-apply "${INTERFACE:-}" && echo "✓ 路由修复完成" || echo "✗ 修复失败"
            else
                echo "未安装 ipv6-smart-apply，请先运行 setup-ipv6.sh"
            fi
            ;;
        2) show_status ;;
        3)
            echo ""
            read -r -p "测几个 IP [默认 ${RANDOM_ADDR_COUNT:-5}]: " n
            n="${n:-${RANDOM_ADDR_COUNT:-5}}"
            ipv6-random-test "$n" 2>/dev/null || echo "测试失败或未安装"
            ;;
        4)
            SETUP="${SETUP_SCRIPT:-}"
            if [[ -z "$SETUP" || ! -f "$SETUP" ]]; then
                for p in /sdb/ipv6/setup-ipv6.sh /root/setup-ipv6.sh ./setup-ipv6.sh; do
                    [[ -f "$p" ]] && SETUP="$p" && break
                done
            fi
            if [[ -n "$SETUP" && -f "$SETUP" ]]; then
                read -r -p "确认重跑安装 [$SETUP]? [y/N]: " ok
                [[ "$ok" =~ ^[yY]$ ]] && bash "$SETUP"
            else
                echo "找不到 setup-ipv6.sh，请手动指定路径"
            fi
            ;;
        0) echo "再见"; exit 0 ;;
        *) echo "无效选项" ;;
    esac
done
MENU
chmod +x /usr/local/bin/ipv6

# ---------- 5. 随机出站工具（不往网卡 add 其它地址）----------
log_info "安装随机 IPv6 出站工具（不 add 到网卡）"

# 清理旧版「往网卡加 IP」的服务
systemctl disable ipv6-random.service 2>/dev/null || true
systemctl stop ipv6-random.service 2>/dev/null || true
rm -f /etc/systemd/system/ipv6-random.service
rm -f /usr/local/bin/ipv6-random-add /usr/local/bin/ipv6-random-del
systemctl daemon-reload 2>/dev/null || true

cat > /usr/local/bin/ipv6-random-test <<'SCRIPT'
#!/bin/bash
# 从 /64 段内随机生成 IPv6，不 ip addr add，直接 --interface 出站测 IP
# 依赖: net.ipv6.ip_nonlocal_bind=1 + local PREFIX::/64 dev lo
# 用法: ipv6-random-test [数量]
set -uo pipefail
CONF="/etc/ipv6-random.conf"
[[ -f "$CONF" ]] && source "$CONF"
COUNT="${1:-${RANDOM_ADDR_COUNT:-5}}"
PREFIX="${IPV6_PREFIX:?}"
URL="${IPV6_CHECK_URL:-https://api6.ipify.org}"
CHECK_HOST="${IPV6_CHECK_HOST:-api6.ipify.org}"

command -v curl >/dev/null 2>&1 || { echo "需要 curl"; exit 1; }

if [[ "$(sysctl -n net.ipv6.ip_nonlocal_bind 2>/dev/null)" != "1" ]]; then
    echo "错误: 需要 net.ipv6.ip_nonlocal_bind=1（请 sudo ipv6 选 1 或重跑 setup-ipv6.sh）"
    exit 1
fi

LOCAL_CIDR="${PREFIX}::/64"
if ! ip -6 route show table local 2>/dev/null | grep -q "local ${LOCAL_CIDR} dev lo"; then
    echo "错误: 缺少 local ${LOCAL_CIDR} dev lo（请 sudo ipv6 选 1 或重跑 setup-ipv6.sh）"
    exit 1
fi

gen_random_addr() {
    local addr skip="${IPV6_BASE_ADDR:-}"
    # 必须在 /64 内生成合法 128 位地址；禁止 PREFIX::h1:h2:h3:h4（:: 压缩错误，curl 无法 bind）
    if command -v python3 >/dev/null 2>&1; then
        addr=$(python3 - "$PREFIX" "$skip" <<'PY'
import random, ipaddress, sys
net = ipaddress.IPv6Network(sys.argv[1] + "::/64", strict=False)
skip = sys.argv[2].strip()
skip_a = ipaddress.IPv6Address(skip) if skip else None
for _ in range(64):
    n = random.getrandbits(64)
    if n == 0:
        continue
    a = net.network_address + n
    if skip_a is not None and a == skip_a:
        continue
    print(a)
    break
PY
        )
        [[ -n "$addr" ]] && { echo "$addr"; return; }
    fi
    local hex
    hex=$(od -An -tx1 -N8 /dev/urandom | tr -d ' \n')
    echo "${PREFIX}:${hex:0:4}:${hex:4:4}:${hex:8:4}:${hex:12:4}"
}

normalize_ip() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r$//'
}

same_ipv6() {
    local a="$1" b="$2"
    if python3 -c "import ipaddress; exit(0 if ipaddress.IPv6Address('${a}') == ipaddress.IPv6Address('${b}') else 1)" 2>/dev/null; then
        return 0
    fi
    [[ "$(normalize_ip "$a")" == "$(normalize_ip "$b")" ]]
}

curl_with_src() {
    local src="$1"
    # 与手动成功命令一致：curl -6 --interface ADDR https://api6.ipify.org
    curl -6 -sS --max-time 20 --connect-timeout 10 --interface "$src" "$URL" 2>/dev/null
}

ADDRS=()
for ((i = 0; i < COUNT; i++)); do
    ADDRS+=("$(gen_random_addr)")
done

echo "模式: 不 add 网卡，随机地址 --interface 出站（nonlocal_bind + lo local /64）"
echo "查 IP: ${URL}"
echo "----------------------------------------------"
printf "%-4s %-42s %-42s %s\n" "序号" "随机 IPv6" "接口返回 IP" "结果"
echo "----------------------------------------------"

ok=0 fail=0
for i in "${!ADDRS[@]}"; do
    local_ip="${ADDRS[$i]}"
    raw=$(curl_with_src "$local_ip" || true)
    remote=$(normalize_ip "$raw")
    if [[ -z "$remote" ]]; then
        status="失败"
        fail=$((fail + 1))
    elif same_ipv6 "$remote" "$local_ip"; then
        status="一致"
        ok=$((ok + 1))
    else
        status="不一致"
        fail=$((fail + 1))
    fi
    printf "%-4s %-42s %-42s %s\n" "$((i+1))" "$local_ip" "${remote:-（无响应）}" "$status"
done
echo "----------------------------------------------"
echo "成功 ${ok}/${COUNT}，失败 ${fail}/${COUNT}（网卡上未添加以上地址）"
[[ $ok -gt 0 ]]
SCRIPT
chmod +x /usr/local/bin/ipv6-random-test

# 持久化参数
cat > /etc/ipv6-random.conf <<EOF
# 由 setup-ipv6.sh 生成
SETUP_SCRIPT="${SCRIPT_SELF}"
INTERFACE="${INTERFACE}"
IPV6_PREFIX="${IPV6_PREFIX}"
IPV6_GATEWAY="${IPV6_GATEWAY:-fe80::1}"
IPV6_HOST_ID=${IPV6_HOST_ID}
IPV6_BASE_ADDR="${IPV6_BASE_ADDR}"
RANDOM_ADDR_COUNT=${RANDOM_ADDR_COUNT}
IPV6_CHECK_URL="${IPV6_CHECK_URL}"
IPV6_CHECK_HOST="${IPV6_CHECK_HOST}"
EOF

# ---------- 6. 防火墙：DHCPv6 端口 ----------
wait_for_apt_lock() {
    local i=0 max="${1:-60}"
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        i=$((i + 1))
        [[ $i -gt $max ]] && return 1
        [[ $i -eq 1 ]] && log_warn "apt 被占用，等待锁释放（最多 ${max} 秒）..."
        sleep 1
    done
    return 0
}

install_iptables_persistent() {
    if dpkg -l iptables-persistent &>/dev/null; then
        return 0
    fi
    if ! wait_for_apt_lock 120; then
        log_warn "apt 锁超时，跳过 iptables-persistent 安装（可稍后: apt install iptables-persistent）"
        return 1
    fi
    log_info "安装 iptables-persistent ..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq debconf-utils 2>/dev/null || true
    debconf-set-selections <<'DEB'
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
DEB
    if ! apt-get install -y -qq iptables-persistent; then
        log_warn "iptables-persistent 安装失败（apt 忙或网络问题），跳过；DHCPv6 规则仍会临时写入"
        return 1
    fi
    return 0
}

save_firewall_rules() {
    mkdir -p /etc/iptables
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
    else
        command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6
        command -v iptables-save  >/dev/null 2>&1 && iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    fi
}

log_info "配置防火墙 DHCPv6 规则"
install_iptables_persistent || true

if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -C INPUT -p udp --dport 546 -j ACCEPT 2>/dev/null || \
        ip6tables -I INPUT -p udp --dport 546 -j ACCEPT
    ip6tables -C OUTPUT -p udp --dport 547 -j ACCEPT 2>/dev/null || \
        ip6tables -I OUTPUT -p udp --dport 547 -j ACCEPT
    save_firewall_rules
    log_info "DHCPv6 防火墙规则已写入（546/547 ACCEPT）"
else
    log_warn "未找到 ip6tables，跳过防火墙规则"
fi

# ---------- 7. 应用网络（顺序：netplan → dhclient 注册 DUID → 清遗留）----------
sysctl --system >/dev/null 2>&1 || true

log_info "应用 netplan ..."
netplan apply
sleep 2
systemctl restart systemd-resolved 2>/dev/null || true

log_info "运行 dhclient 注册 DUID（Dedibox 必须先注册前缀）..."
systemctl stop dhclient-ipv6.service 2>/dev/null || true
pkill -f "dhclient.*${INTERFACE}" 2>/dev/null || true
sleep 1
"${DHCLIENT_BIN}" -cf /etc/dhcp/dhclient6.conf -6 -P -pf /var/run/dhclient6.pid "${INTERFACE}" &
sleep 5
systemctl start dhclient-ipv6.service --no-block 2>/dev/null || true
sleep 3

log_info "清理并应用 IPv6 双路由（网卡 /64 + lo local /64）..."
for try in 1 2 3; do
    if /usr/local/bin/ipv6-smart-apply "$INTERFACE"; then
        break
    fi
    log_warn "第 ${try} 次应用失败，${try} 秒后重试 ..."
    sleep "$try"
    [[ $try -eq 3 ]] && { log_error "IPv6 路由应用失败"; exit 1; }
done
systemctl restart ipv6-routes.service 2>/dev/null || systemctl start ipv6-routes.service 2>/dev/null || true

# ---------- 8. 验证 ----------
echo ""
log_info "========== IPv6 路由 =========="
ip -6 route show || true
ip -6 addr show dev "${INTERFACE}" scope global 2>/dev/null | grep inet6 || log_warn "网卡上无全局 IPv6"
ip -6 route show table local 2>/dev/null | grep "${IPV6_PREFIX}" || log_warn "lo local /64 未生效（随机 IP 会失败）"
echo ""
log_info "========== 连通性测试 =========="
if ping6 -c 2 -W 5 ipv6.google.com 2>/dev/null; then
    log_info "ping6 ipv6.google.com 成功"
elif ping6 -c 2 -W 5 -I "${IPV6_BASE_ADDR}" 2001:4860:4860::8888; then
    log_info "ping6 成功（源 ${IPV6_BASE_ADDR}）"
else
    log_warn "ping6 失败，请检查: ip -6 addr show dev ${INTERFACE}; ip -6 route; ip -6 neigh show dev ${INTERFACE}"
fi

echo ""
log_info "========== 随机 ${RANDOM_ADDR_COUNT} 个 IPv6 出站测 IP（不 add 网卡）=========="
if ipv6-random-test "$RANDOM_ADDR_COUNT"; then
    log_info "随机 IPv6 出站测试通过"
else
    log_warn "部分随机 IP 测 IP 失败，可稍后重试: ipv6-random-test ${RANDOM_ADDR_COUNT}"
fi

echo ""
echo "=============================================="
log_info "配置完成"
echo ""
echo "  ★ 以后只需记一个命令（交互菜单）:"
echo ""
echo "       sudo ipv6"
echo ""
echo "     路由乱了 → 选 1"
echo "     看状态   → 选 2"
echo "     测 IP    → 选 3"
echo ""
echo "  配置文件:"
echo "    - /etc/dhcp/dhclient6.conf"
echo "    - /etc/netplan/$(basename "$NETPLAN_FILE")"
echo "    - /etc/ipv6-random.conf"
echo ""
echo "  主 IPv6: ${IPV6_BASE_ADDR}/64（网卡 ${INTERFACE}）"
echo "  随机 IP: local ${IPV6_PREFIX}::/64 dev lo + nonlocal_bind（不 add 网卡）"
echo "=============================================="
echo ""
read -r -p "是否现在打开交互菜单? [Y/n]: " open_menu
[[ ! "$open_menu" =~ ^[nN]$ ]] && /usr/local/bin/ipv6 || true
