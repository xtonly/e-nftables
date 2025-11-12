#!/bin/bash

# =================================================================
#           Nftables 转发 (NAT 网关) TUI 管理面板
# =================================================================
#
# 功能:
#   提供一个类似 E-Gost 面板的 TUI 菜单，用于管理 nftables
#   转发、NAT 和持久化。
#
# =================================================================

# --- [ 1. 配置变量 ] (请根据您的环境修改) ---

# 外部(公网)接口
EXT_IF="eth0"
# 内部(局域网)接口
INT_IF="eth1"
# 内部(局域网)网段
INT_NET="192.168.1.0/24"
# 允许外部访问服务器的 SSH 端口
SSH_PORT="22"
# Nftables 配置文件路径
NFT_CONFIG_FILE="/etc/nftables.conf"

# --- [ 2. 端口转发 (DNAT) 规则 ] ---
#   格式: "协议:外部端口:内部IP:内部端口"
declare -a DNAT_RULES=(
    # "tcp:80:192.168.1.100:80"
    # "tcp:443:192.168.1.100:443"
)


# =================================================================
#                 [ 脚本核心功能 - 请勿修改下方内容 ]
# =================================================================

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本必须以 root 权限运行。" >&2
  exit 1
fi

# ----------------- [ 核心功能函数 ] -----------------

# [ 启动/应用规则 ]
do_start() {
    echo "1. 启用内核IP转发..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    echo "2. 清空当前所有 Nftables 规则..."
    nft flush ruleset
    echo "3. 创建 Tables 和 Chains..."
    nft add table inet filter
    nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
    nft add chain inet filter forward { type filter hook forward priority 0\; policy drop\; }
    nft add chain inet filter output { type filter hook output priority 0\; policy accept\; }
    nft add table ip nat
    nft add chain ip nat prerouting { type nat hook prerouting priority 0\; }
    nft add chain ip nat postrouting { type nat hook postrouting priority 100\; }
    echo "4. 添加 'filter' 防火墙规则..."
    nft add rule inet filter input iifname "lo" accept
    nft add rule inet filter input ct state related,established accept
    nft add rule inet filter input ip protocol icmp accept
    nft add rule inet filter input ip6 nexthdr icmpv6 accept
    nft add rule inet filter input tcp dport $SSH_PORT accept
    nft add rule inet filter forward ct state related,established accept
    nft add rule inet filter forward iifname $INT_IF oifname $EXT_IF accept
    echo "5. 添加 'nat' (SNAT/Masquerade) 规则..."
    nft add rule ip nat postrouting oifname $EXT_IF ip saddr $INT_NET masquerade
    echo "6. 添加 'nat' (DNAT/端口转发) 规则..."
    for rule in "${DNAT_RULES[@]}"; do
        IFS=':' read -r proto ext_port int_ip int_port <<< "$rule"
        echo "   -> 转发 $proto 端口 $ext_port 至 $int_ip:$int_port"
        nft add rule ip nat prerouting iifname $EXT_IF $proto dport $ext_port dnat to $int_ip:$int_port
        nft add rule inet filter forward iifname $EXT_IF oifname $INT_IF ip daddr $int_ip $proto dport $int_port accept
    done
    echo "---"
    echo "✅ Nftables 转发网关已启动."
}

# [ 停止/清空规则 ]
do_stop() {
    echo "停止 Nftables 网关并清空所有规则..."
    nft flush ruleset
    echo "✅ 所有规则已清空."
}

# [ 查看当前规则 (详细) ]
do_status_detail() {
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
    mkdir -p "$(dirname "$NFT_CONFIG_FILE")"
    if nft list ruleset > "$NFT_CONFIG_FILE"; then
        chmod 600 "$NFT_CONFIG_FILE"
        echo "✅ 规则已成功保存到 $NFT_CONFIG_FILE"
    else
        echo "❌ 保存失败! 无法写入 $NFT_CONFIG_FILE"
    fi
}

# [ 启用开机自启 ]
do_enable_boot() {
    if [ ! -f "$NFT_CONFIG_FILE" ]; then
        echo "警告: 配置文件 $NFT_CONFIG_FILE 不存在。"
        echo "      请先运行 '5. 保存规则'。"
        return 1
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


# ----------------- [ TUI 界面函数 ] -----------------

# [ 1. 显示状态顶栏 ]
show_status_header() {
    clear
    
    # 获取内核转发状态
    local fwd_status
    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
        fwd_status="\e[32m已开启\e[0m" # 绿色
    else
        fwd_status="\e[31m已关闭\e[0m" # 红色
    fi

    # 获取 Nftables 服务状态
    local service_status
    if systemctl is-active --quiet nftables.service; then
        service_status="\e[32m运行中\e[0m" # 绿色
    else
        service_status="\e[31m已停止\e[0m" # 红色
    fi

    # 获取开机自启状态
    local enable_status
    if systemctl is-enabled --quiet nftables.service; then
        enable_status="\e[32m已启用\e[0m" # 绿色
    else
        enable_status="\e[31m已禁用\e[0m" # 红色
    fi

    # 获取 DNAT 规则数
    local dnat_count="${#DNAT_RULES[@]}"

    echo "========================================================"
    echo " 当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================"
    echo "                Nftables 转发管理面板"
    echo "========================================================"
    echo -e " 核心转发: $fwd_status   | 服务状态: $service_status   | 开机自启: $enable_status"
    echo " 配置规则: $dnat_count 条 DNAT 规则"
    echo "========================================================"
}

# [ 2. 显示主菜单 ]
show_main_menu() {
    echo " 1. 启动转发 (应用配置)"
    echo " 2. 停止转发 (清空规则)"
    echo " 3. 重启转发"
    echo "--------------------------------------------------------"
    echo " 4. 查看当前规则 (详细)"
    echo " 5. 保存规则到 $NFT_CONFIG_FILE"
    echo " 6. 启用服务 (开机自启)"
    echo " 7. 禁用服务 (取消自启)"
    echo "========================================================"
    echo " 00. 退出"
    echo "--------------------------------------------------------"
}

# ----------------- [ 3. 主循环 ] -----------------
main_loop() {
    while true; do
        show_status_header
        show_main_menu
        read -p "请选择操作 [1-7, 00]: " choice

        # 清除状态顶栏和菜单，准备显示操作输出
        clear
        echo "========================================================"
        echo "                 执行操作: $choice"
        echo "========================================================"
        
        case "$choice" in
            1)
                do_start
                ;;
            2)
                do_stop
                ;;
            3)
                echo "--- 正在停止... ---"
                do_stop
                echo ""
                echo "--- 正在启动... ---"
                do_start
                echo "✅ 重启完成."
                ;;
            4)
                do_status_detail
                ;;
            5)
                do_save
                ;;
            6)
                do_enable_boot
                ;;
            7)
                do_disable_boot
                ;;
            00)
                echo "退出脚本。"
                echo "========================================================"
                exit 0
                ;;
            *)
                echo -e "\e[31m错误: 无效输入 '$choice'。\e[0m"
                ;;
        esac

        echo "========================================================"
        read -p "按 [Enter] 键返回主菜单..." -r
    done
}

# 启动主循环
main_loop
