#!/usr/bin/env bash
set -euo pipefail

# Debian 13 nftables 端口转发一键脚本
# - 安装 nftables
# - 开启 IPv4 转发并持久化
# - 自动检测出口网卡
# - 写入 /etc/nftables.d/*.nft 并让 /etc/nftables.conf include
# - 配置 DNAT + MASQUERADE（SNAT）与必要的 forward 放行

usage() {
  cat >&2 <<EOF
Usage:
  $0 --src-port <A_port> --dst-ip <B_ip_or_hostname> --dst-port <B_port> [--proto tcp|udp|both] [--wan-if <iface>]

Examples:
  $0 --src-port 80  --dst-ip 10.0.0.2    --dst-port 8080 --proto both
  $0 --src-port 443 --dst-ip 203.0.113.5 --dst-port 8443 --proto tcp

Notes:
  - 需要 root 运行
  - 默认 --proto both
  - 自动检测出口网卡；如需指定请用 --wan-if
EOF
  exit 1
}

# ---------- 参数解析 ----------
SRC_PORT=""
DST_HOST=""
DST_PORT=""
PROTO="both"
WAN_IF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-port)
      SRC_PORT="${2:-}"; shift 2;;
    --dst-ip)
      DST_HOST="${2:-}"; shift 2;;
    --dst-port)
      DST_PORT="${2:-}"; shift 2;;
    --proto)
      PROTO="${2:-}"; shift 2;;
    --wan-if)
      WAN_IF="${2:-}"; shift 2;;
    -h|--help)
      usage;;
    *)
      echo "Unknown argument: $1" >&2; usage;;
  esac
done

[[ -n "${SRC_PORT}" && -n "${DST_HOST}" && -n "${DST_PORT}" ]] || usage
if [[ ! "${PROTO}" =~ ^(tcp|udp|both)$ ]]; then
  echo "--proto 必须为 tcp|udp|both" >&2
  exit 1
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "请以 root 运行" >&2
  exit 1
fi

# ---------- 依赖安装 ----------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nftables iproute2

# ---------- 解析目标 IP ----------
is_ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
if [[ "${DST_HOST}" =~ ${is_ipv4} ]]; then
  DST_IP="${DST_HOST}"
else
  if ! command -v getent >/dev/null 2>&1; then
    apt-get install -y libc-bin >/dev/null 2>&1 || true
  fi
  DST_IP="$(getent ahostsv4 "${DST_HOST}" | awk 'NR==1{print $1}')"
  if [[ -z "${DST_IP}" ]]; then
    echo "无法解析目标主机到 IPv4: ${DST_HOST}" >&2
    exit 1
  fi
fi

# ---------- 检测出口网卡 ----------
detect_wan_if() {
  local ip="$1"
  local dev
  dev="$(ip -4 route get "$ip" 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1 || true)"
  if [[ -z "$dev" ]]; then
    dev="$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}' || true)"
  fi
  echo "$dev"
}

if [[ -z "${WAN_IF}" ]]; then
  WAN_IF="$(detect_wan_if "${DST_IP}")"
  if [[ -z "${WAN_IF}" ]]; then
    echo "无法自动检测出口网卡，请使用 --wan-if 指定" >&2
    exit 1
  fi
fi

echo "配置参数:"
echo "  源(A)端口: ${SRC_PORT}"
echo "  目标(B)地址: ${DST_IP}"
echo "  目标(B)端口: ${DST_PORT}"
echo "  协议: ${PROTO}"
echo "  出口网卡: ${WAN_IF}"

# ---------- 开启并持久化 IPv4 转发 ----------
mkdir -p /etc/sysctl.d
SYSCTL_FILE="/etc/sysctl.d/99-port-forwarding.conf"
cat > "${SYSCTL_FILE}" <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl -w net.ipv4.ip_forward=1 >/dev/null
# 仅加载当前文件，避免干扰其他 sysctl 配置
sysctl -p "${SYSCTL_FILE}" >/dev/null

# ---------- 配置 nftables 持久化 ----------
mkdir -p /etc/nftables.d

NFT_MAIN="/etc/nftables.conf"
if [[ ! -f "${NFT_MAIN}" ]]; then
  cat > "${NFT_MAIN}" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

# 将独立规则片段集中放在 /etc/nftables.d
include "/etc/nftables.d/*.nft"
EOF
else
  if ! grep -q 'include "/etc/nftables.d/\*\.nft"' "${NFT_MAIN}"; then
    # 在末尾添加 include
    printf '\ninclude "/etc/nftables.d/*.nft"\n' >> "${NFT_MAIN}"
  fi
fi

# 生成规则文件名（替换 IP 中的点为下划线）
safe_ip="${DST_IP//./_}"
RULE_FILE="/etc/nftables.d/portfwd_${SRC_PORT}_${safe_ip}_${DST_PORT}.nft"

# ---------- 写入规则 ----------
# 说明：
# - NAT: PREROUTING 做 DNAT，将 A:src_port -> B:dst_port
# - NAT: POSTROUTING 对目标为 B 的流量做 MASQUERADE，保证回包回到 A
# - FILTER: FORWARD 放行转发的 TCP/UDP 会话
{
  echo "table ip nat_portfwd_${SRC_PORT} {"
  echo "  chain prerouting {"
  echo "    type nat hook prerouting priority -100; policy accept;"
  if [[ "${PROTO}" == "tcp" || "${PROTO}" == "both" ]]; then
    echo "    tcp dport ${SRC_PORT} dnat to ${DST_IP}:${DST_PORT} comment \"port-fwd TCP ${SRC_PORT}->${DST_IP}:${DST_PORT}\""
  fi
  if [[ "${PROTO}" == "udp" || "${PROTO}" == "both" ]]; then
    echo "    udp dport ${SRC_PORT} dnat to ${DST_IP}:${DST_PORT} comment \"port-fwd UDP ${SRC_PORT}->${DST_IP}:${DST_PORT}\""
  fi
  echo "  }"
  echo "  chain postrouting {"
  echo "    type nat hook postrouting priority 100; policy accept;"
  echo "    ip daddr ${DST_IP} oifname \"${WAN_IF}\" masquerade comment \"SNAT replies to ${DST_IP} via ${WAN_IF}\""
  echo "  }"
  echo "}"

  echo ""
  echo "table inet filter_portfwd_${SRC_PORT} {"
  echo "  chain forward {"
  echo "    type filter hook forward priority 0; policy accept;"
  echo "    ct state established,related accept"
  if [[ "${PROTO}" == "tcp" || "${PROTO}" == "both" ]]; then
    echo "    ip daddr ${DST_IP} tcp dport ${DST_PORT} accept"
  fi
  if [[ "${PROTO}" == "udp" || "${PROTO}" == "both" ]]; then
    echo "    ip daddr ${DST_IP} udp dport ${DST_PORT} accept"
  fi
  echo "  }"
  echo "}"
} > "${RULE_FILE}"

# ---------- 启用并加载 ----------
systemctl enable --now nftables >/dev/null
# 先语法检查，再加载
nft -c -f "${NFT_MAIN}" >/dev/null
nft -f "${NFT_MAIN}"

echo
echo "已完成配置并加载。当前规则集："
nft list ruleset | sed -n '1,80p'
echo
echo "规则片段：${RULE_FILE}"
echo "主配置：  ${NFT_MAIN}"
