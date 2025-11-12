#!/bin/bash

# =================================================================
#           Nftables 转发 (NAT 网关) 管理脚本
# =================================================================
#
# 功能:
#   使用参数管理 nftables 转发规则和持久化。
#
# 用法:
#   sudo ./manage_forwarding.sh [start|stop|restart|status|save|enable-boot|disable-boot]
#
# =================================================================

# --- [ 1. 配置变量 ] (请根据您的环境修改) ---

# 外部(公网)接口 (例如: eth0, enp1s0)
EXT_IF="eth0"

# 内部(局域网)接口 (例如: eth1, enp2s0)
INT_IF="eth1"

# 内部(局域网)网段 (例如: 192.168.1.0/24)
INT_NET="192.168.1.0/24"

# 允许外部访问服务器的 SSH 端口
SSH_PORT="22"

# Nftables 配置文件路径
NFT_CONFIG_FILE="/etc/nftables.conf"


# --- [ 2. 端口转发 (DNAT) 规则 ] ---
#
#   格式: "协议:外部端口:内部IP:内部端口"
#   示例: "tcp:80:192.168.1.100:80" (将公网80端口转发到内网 1.100 的 80)
#
#   在此处添加您的 DNAT 规则:
declare -a DNAT_RULES=(
    # "tcp:80:192.168.1.100:80"
    # "tcp:443:192.168.1.100:443"
    # "udp:53:192.168.1.53:53"
)


# =================================================================
#                 [ 脚本核心逻辑 - 请勿修改下方内容 ]
# =================================================================

# 启用严格模式
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本必须以 root 权限运行。" >&2
  exit 1
fi

# ----------------- [ 核心功能函数 ] -----------------

# [ 启动/应用规则 ]
do_start() {
    echo "1. 启用内核IP转发..."
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    sysctl -w net.ipv4.conf.all.accept_redirects=0
    sysctl -w net.ipv4.conf.all.send_redirects=0

    echo "2. 清空当前所有 Nftables 规则..."
    nft flush ruleset

    echo "3. 创建 Tables 和 Chains..."
    # 'inet filter' table (IPv4/IPv6 防火墙)
    nft add table inet filter
    nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
    nft add chain inet filter forward { type filter hook forward priority 0\; policy drop\; }
    nft add chain inet filter output { type filter hook output priority 0\; policy accept\; }

    # 'ip nat' table (仅 IPv4 NAT)
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority 0\; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100\; }

    echo "4. 添加 'filter' (Input) 规则 (保护服务器)..."
    nft add rule inet filter input iifname "lo" accept
    nft add rule inet filter input ct state related,established accept
    nft add rule inet filter input ip protocol icmp accept
    nft add rule inet filter input ip6 nexthdr icmpv6 accept
    nft add rule inet filter input tcp dport $SSH_PORT accept

    echo "5. 添加 'filter' (Forward) 规则 (控制转发)..."
    nft add rule inet filter forward ct state related,established accept
    nft add rule inet filter forward iifname $INT_IF oifname $EXT_IF accept

    echo "6. 添加 'nat' (SNAT/Masquerade) 规则..."
    nft add rule ip nat postrouting oifname $EXT_IF ip saddr $INT_NET masquerade

    echo "7. 添加 'nat' (DNAT/端口转发) 规则..."
    if [ ${#DNAT_RULES[@]} -eq 0 ]; then
        echo "   (未配置 DNAT 规则，跳过)"
    else
        for rule in "${DNAT_RULES[@]}"; do
            IFS=':' read -r proto ext_port int_ip int_port <<< "$rule"
            echo "   -> 转发 $proto 端口 $ext_port 至 $int_ip:$int_port"
            
            # 1. 添加 DNAT 规则
            nft add rule ip nat prerouting iifname $EXT_IF $proto dport $ext_port dnat to $int_ip:$int_port
            
            # 2. (重要) 在 filter:forward 链中放行此流量
            nft add rule inet filter forward iifname $EXT_IF oifname $INT_IF ip daddr $int_ip $proto dport $int_port accept
        done
    fi

    echo "---"
    echo "✅ Nftables 转发网关已启动."
    echo "---"
}

# [ 停止/清空规则 ]
do_stop() {
    echo "停止 Nftables 网关并清空所有规则..."
    nft flush ruleset
    echo "✅ 所有规则已清空."
    # 注意: 内核转发 (ip_forward) 保持不变，以免影响其他服务。
    # 如果需要，可以取消下一行的注释来禁用它：
    # sysctl -w net.ipv4.ip_forward=0
}

# [ 查看状态 ]
do_status() {
    echo "--- [ 内核转发状态 ] ---"
    sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
    echo ""
    echo "--- [ Nftables 规则集 ] ---"
    nft list ruleset
    echo "--------------------------"
}

# [ 保存规则 ]
do_save() {
    echo "正在保存当前规则集到 $NFT_CONFIG_FILE..."
    # 确保目录存在
    mkdir -p "$(dirname "$NFT_CONFIG_FILE")"
    
    # 导出规则
    if nft list ruleset > "$NFT_CONFIG_FILE"; then
        chmod 600 "$NFT_CONFIG_FILE"
        echo "✅ 规则已成功保存到 $NFT_CONFIG_FILE"
        echo "   (要使其开机生效, 请运行: $0 enable-boot)"
    else
        echo "❌ 保存失败! 无法写入 $NFT_CONFIG_FILE"
    fi
}

# [ 启用开机自启 ]
do_enable_boot() {
    if [ ! -f "$NFT_CONFIG_FILE" ]; then
        echo "警告: 配置文件 $NFT_CONFIG_FILE 不存在。"
        echo "      请先运行 '$0 save' 保存规则。"
        exit 1
    fi
    echo "正在启用 'nftables.service' (开机自动加载 $NFT_CONFIG_FILE)..."
    systemctl enable nftables.service
    echo "✅ 'nftables.service' 已启用."
}

# [ 禁用开机自启 ]
do_disable_boot() {
    echo "正在禁用 'nftables.service' (开机不再自动加载规则)..."
    systemctl disable nftables.service
    echo "✅ 'nftables.service' 已禁用."
}

# [ 显示用法 ]
usage() {
    echo "用法: $0 [start|stop|restart|status|save|enable-boot|disable-boot]"
    echo "  start         : 应用脚本中定义的 NAT 转发规则"
    echo "  stop          : 清空所有 Nftables 规则"
    echo "  restart       : 停止 (清空) 并重新启动规则"
    echo "  status        : 显示内核转发状态和当前 Nftables 规则"
    echo "  save          : 将当前生效的规则保存到 $NFT_CONFIG_FILE"
    echo "  enable-boot   : 启用 nftables 服务, 使其开机自动加载 $NFT_CONFIG_FILE"
    echo "  disable-boot  : 禁用 nftables 服务开机自启"
}

# ----------------- [ 3. 参数解析器 ] -----------------

# 检查是否提供了参数
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

ACTION="$1"

case "$ACTION" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_stop
        do_start
        ;;
    status)
        do_status
        ;;
    save)
        do_save
        ;;
    enable-boot)
        do_enable_boot
        ;;
    disable-boot)
        do_disable_boot
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "错误: 未知操作 '$ACTION'"
        usage
        exit 1
        ;;
esac
