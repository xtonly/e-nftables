#!/bin/bash

# =================================================================
#           Nftables 转发 (NAT 网关) TUI 管理面板 (v2.2)
# =================================================================
#
# v2.2 更新:
#   - 自动检测公网接口 (EXT_IF)
#   - 自动检测并安装依赖 (nftables, iproute2, libc-bin)
#   - 添加规则时支持输入主机名 (自动解析为 IP)
#
# v2.1 更新:
#   - 添加规则时, 协议默认为 'both' (TCP+UDP)
#
# =================================================================

# --- [ 1. 配置变量 ] (请根据您的环境修改) ---

# 内部(局域网)接口
INT_IF="eth1"
# 内部(局域网)网段
INT_NET="192.168.1.0/24"
# 允许外部访问服务器的 SSH 端口
SSH_PORT="22"

# --- [ 2. 全局变量 ] (脚本自动填充) ---

# 公网接口 (将由 detect_wan_if 自动填充)
EXT_IF=""

# 规则存储文件
NFT_CONFIG_FILE="/etc/nftables.conf"
DNAT_RULES_FILE="/etc/nft_menu_dnat.rules"

# 内存中的规则数组
declare -a DNAT_RULES=()


# =================================================================
#                 [ 脚本核心功能 - 请勿修改下方内容 ]
# =================================================================

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
  echo "错误: 此脚本必须以 root 权限运行。" >&2
  exit 1
fi

# ----------------- [ 核心功能函数 ] -----------------

# [ 0. 自动安装依赖 ]
check_deps() {
    local missing=0
    for cmd in nft ip getent; do
        if ! command -v "$cmd" &> /dev/null; then
            missing=1
        fi
    done
    
    if [[ "$missing" -eq 1 ]]; then
        echo "正在安装所需依赖 (nftables, iproute2, libc-bin)..."
        export DEBIAN_FRONTEND=noninteractive
        if command -v apt-get &> /dev/null; then
            apt-get update -y >/dev/null 2>&1
            apt-get install -y nftables iproute2 libc-bin >/dev/null 2>&1
            if [[ "$?" -ne 0 ]]; then
                echo "❌ 依赖安装失败。请手动安装: nftables, iproute2, libc-bin"
                exit 1
            fi
            echo "✅ 依赖安装完毕。"
        else
             echo "❌ 找不到 apt-get。请手动安装: nftables, iproute2, libc-bin"
             exit 1
        fi
    fi
}

# [ 0. 自动检测公网接口 ]
detect_wan_if() {
    # 尝试通过路由到 8.8.8.8 (公共DNS) 来找到出口
    local dev
    dev=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/ dev / {print $5}' | head -n1)
    
    if [[ -z "$dev" ]]; then
        # 失败则回退到查找默认路由
        dev=$(ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}')
    fi
    
    if [[ -n "$dev" ]]; then
        echo "$dev"
    else
        return 1 # 返回失败
    fi
}

# [ 0. 从文件加载 DNAT 规则到内存数组 ]
load_dnat_rules() {
    DNAT_RULES=() # 清空内存数组
    if [ -f "$DNAT_RULES_FILE" ]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" == "" || "$line" == \#* ]] && continue
            DNAT_RULES+=("$line")
        done < "$DNAT_RULES_FILE"
    else
        touch "$DNAT_RULES_FILE"
    fi
}

# [ 1. 启动/应用规则 ]
do_start() {
    load_dnat_rules
    echo "1. 启用内核IP转发..."
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    echo "2. 清空当前所有 Nftables 规则..."
    nft flush ruleset
    echo "3. 创建 Tables 和 Chains... (使用公网接口: $EXT_IF)"
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
    nft add rule inet filter input ip6 nexhdr icmpv6 accept
    nft add rule inet filter input tcp dport $SSH_PORT accept
    nft add rule inet filter forward ct state related,established accept
    nft add rule inet filter forward iifname $INT_IF oifname $EXT_IF accept
    
    echo "5. 添加 'nat' (SNAT/Masquerade) 规则..."
    nft add rule ip nat postrouting oifname $EXT_IF ip saddr $INT_NET masquerade
    
    echo "6. 添加 'nat' (DNAT/端口转发) 规则..."
    if [ ${#DNAT_RULES[@]} -eq 0 ]; then
        echo "   (未配置 DNAT 规则，跳过)"
    else
        for rule in "${DNAT_RULES[@]}"; do
            IFS=':' read -r proto ext_port int_ip int_port <<< "$rule"
            echo "   -> 应用: $rule"
            nft add rule ip nat prerouting iifname $EXT_IF $proto dport $ext_port dnat to $int_ip:$int_port
            nft add rule inet filter forward iifname $EXT_IF oifname $INT_IF ip daddr $int_ip $proto dport $int_port accept
        done
    fi
    
    echo "---"
    echo "✅ Nftables 转发网关已启动."
}

# [ 2. 停止/清空规则 ]
do_stop() {
    echo "停止 Nftables 网关并清空所有规则..."
    nft flush ruleset
    echo "✅ 所有规则已清空."
}

# [ 3. 查看当前规则 (详细) ]
do_status_detail() {
    echo "--- [ 内核转发状态 ] ---"
    sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
    echo ""
    echo "--- [ Nftables 规则集 (当前生效) ] ---"
    nft list ruleset
    echo ""
    echo "--- [ 脚本 DNAT 规则 (已保存) ] ---"
    if [ -f "$DNAT_RULES_FILE" ] && [ "$(cat "$DNAT_RULES_FILE" | wc -l)" -gt 0 ]; then
        cat -n "$DNAT_RULES_FILE"
    else
        echo "(无)"
    fi
    echo "-----------------------------------"
}

# [ 4. 保存规则 (到系统配置) ]
do_save() {
    echo "正在保存当前 *生效的* 规则集到 $NFT_CONFIG_FILE..."
    mkdir -p "$(dirname "$NFT_CONFIG_FILE")"
    if nft list ruleset > "$NFT_CONFIG_FILE"; then
        chmod 600 "$NFT_CONFIG_FILE"
        echo "✅ 规则已成功保存到 $NFT_CONFIG_FILE"
        echo "   (要使其开机生效, 请运行 '启用服务')"
    else
        echo "❌ 保存失败! 无法写入 $NFT_CONFIG_FILE"
    fi
}

# [ 5. 傻瓜式 - 添加规则 ]
# --- (v2.2) ---
do_add_rule() {
    echo "--- 添加新的 DNAT 规则 ---"
    
    read -p "协议 (tcp, udp, both) [默认: both]: " proto
    [[ -z "$proto" ]] && proto="both" # 默认值为 both
    
    if [[ "$proto" != "tcp" && "$proto" != "udp" && "$proto" != "both" ]]; then
        echo -e "\e[31m错误: 协议必须是 tcp, udp, 或 both。\e[0m"
        return 1
    fi
    
    read -p "公网端口 (例如 80): " ext_port
    if ! [[ "$ext_port" =~ ^[0-9]+$ ]] || [ "$ext_port" -lt 1 ] || [ "$ext_port" -gt 65535 ]; then
        echo -e "\e[31m错误: 无效的端口号。\e[0m"
        return 1
    fi
    
    # --- 智能 IP/主机名 解析 ---
    read -p "内网 IP 或 主机名 (例如 192.168.1.100 或 my.nas.com): " int_host
    if [[ -z "$int_host" ]]; then
        echo -e "\e[31m错误: 必须输入 IP 或 主机名。\e[0m"
        return 1
    fi

    local int_ip
    local is_ipv4='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    
    if [[ "$int_host" =~ $is_ipv4 ]]; then
        int_ip="$int_host"
        echo "   -> 输入为 IP: $int_ip"
    else
        echo "   -> 输入为 主机名: $int_host, 正在解析..."
        # 使用 getent (来自 libc-bin) 解析 IPv4
        int_ip=$(getent ahostsv4 "$int_host" | awk 'NR==1{print $1}')
        if [[ -z "$int_ip" ]]; then
            echo -e "\e[31m错误: 无法将 '$int_host' 解析为 IPv4 地址。\e[0m"
            return 1
        fi
        echo -e "   -> \e[32m解析成功: $int_ip\e[0m"
    fi
    # --- 解析结束 ---
    
    read -p "内网端口 [留空 = $ext_port]: " int_port
    [[ -z "$int_port" ]] && int_port="$ext_port"
    if ! [[ "$int_port" =~ ^[0-9]+$ ]] || [ "$int_port" -lt 1 ] || [ "$int_port" -gt 65535 ]; then
        echo -e "\e[31m错误: 无效的内网端口号。\e[0m"
        return 1
    fi
    
    echo "---"
    
    if [[ "$proto" == "both" ]]; then
        local new_rule_tcp="tcp:$ext_port:$int_ip:$int_port"
        local new_rule_udp="udp:$ext_port:$int_ip:$int_port"
        
        read -p "您要添加 [TCP] 和 [UDP] 两条规则吗? [Y/n]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "" ]]; then
            echo "$new_rule_tcp" >> "$DNAT_RULES_FILE"
            echo "$new_rule_udp" >> "$DNAT_RULES_FILE"
            echo "✅ [TCP] 和 [UDP] 规则已保存到 $DNAT_RULES_FILE"
        else
            echo "操作已取消。"
        fi
        
    else
        local new_rule="$proto:$ext_port:$int_ip:$int_port"
        
        read -p "您要添加的规则: $new_rule [Y/n]: " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" || "$confirm" == "" ]]; then
            echo "$new_rule" >> "$DNAT_RULES_FILE"
            echo "✅ 规则已保存到 $DNAT_RULES_FILE"
        else
            echo "操作已取消。"
        fi
    fi
    
    echo "请 '重启转发' (选项3) 或 '启动转发' (选项1) 来应用新规则。"
}
# --- (v2.2 结束) ---

# [ 6. 傻瓜式 - 删除规则 ]
do_delete_rule() {
    load_dnat_rules
    if [ ${#DNAT_RULES[@]} -eq 0 ]; then
        echo "没有任何 DNAT 规则可供删除。"
        return
    fi
    
    echo "--- 删除 DNAT 规则 ---"
    echo "当前的规则:"
    local i=1
    for rule in "${DNAT_RULES[@]}"; do
        echo -e " \e[33m[$i]\e[0m $rule"
        ((i++))
    done
    echo " [0] 取消"
    echo "------------------------"
    read -p "请输入要删除的规则编号: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        echo -e "\e[31m错误: 无效输入。\e[0m"
        return 1
    fi
    
    if [ "$choice" -eq 0 ]; then
        echo "操作已取消。"
        return
    fi
    
    if [ "$choice" -gt "${#DNAT_RULES[@]}" ]; then
        echo -e "\e[31m错误: 编号 $choice 不存在。\e[0m"
        return 1
    fi
    
    local rule_to_delete="${DNAT_RULES[$((choice-1))]}"
    read -p "确定要删除规则: $rule_to_delete ? [y/N]: " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        sed -i "${choice}d" "$DNAT_RULES_FILE"
        echo "✅ 规则已从 $DNAT_RULES_FILE 中删除。"
        echo "请 '重启转发' (选项3) 来使更改生效。"
    else
        echo "操作已取消。"
    fi
}

# [ 7. 启用开机自启 ]
do_enable_boot() {
    if [ ! -f "$NFT_CONFIG_FILE" ]; then
        echo "警告: 配置文件 $NFT_CONFIG_FILE 不存在。"
        echo "      请先运行 '7. 保存规则到系统配置'。"
        return 1
    fi
    echo "正在启用 'nftables.service' (开机自动加载 $NFT_CONFIG_FILE)..."
    systemctl enable nftables.service
    echo "✅ 'nftables.service' 已启用."
}

# [ 8. 禁用开机自启 ]
do_disable_boot() {
    echo "正在禁用 'nftables.service' (开机不再自动加载规则)..."
    systemctl disable nftables.service
    echo "✅ 'nftables.service' 已禁用."
}


# ----------------- [ TUI 界面函数 ] -----------------

# [ 1. 显示状态顶栏 ]
show_status_header() {
    clear
    
    local fwd_status
    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then
        fwd_status="\e[32m已开启\e[0m"
    else
        fwd_status="\e[31m已关闭\e[0m"
    fi

    local service_status
    if systemctl is-active --quiet nftables.service; then
        service_status="\e[32m运行中\e[0m"
    else
        service_status="\e[31m已停止\e[0m"
    fi

    local enable_status
    if systemctl is-enabled --quiet nftables.service; then
        enable_status="\e[32m已启用\e[0m"
    else
        enable_status="\e[31m已禁用\e[0m"
    fi

    load_dnat_rules
    local dnat_count="${#DNAT_RULES[@]}"

    echo "========================================================"
    echo " 当前时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================================"
    echo "                Nftables 转发管理面板 (v2.2)"
    echo "========================================================"
    echo -e " 公网接口: \e[36m$EXT_IF\e[0m (自动检测) | 内网接口: $INT_IF"
    echo -e " 核心转发: $fwd_status   | 服务状态: $service_status   | 开机自启: $enable_status"
    echo -e " 配置规则: \e[33m$dnat_count\e[0m 条 DNAT 规则"
    echo "========================================================"
}

# [ 2. 显示主菜单 ]
show_main_menu() {
    echo " 1. 启动转发 (应用配置)"
    echo " 2. 停止转发 (清空规则)"
    echo " 3. 重启转发"
    echo " 4. 查看当前状态/规则"
    echo "--------------------------------------------------------"
    echo " 5. 添加 DNAT 转发规则 (支持主机名)"
    echo " 6. 删除 DNAT 转发规则"
    echo "--------------------------------------------------------"
    echo " 7. 保存规则到系统配置 (用于开机)"
    echo " 8. 启用服务 (开机自启)"
    echo " 9. 禁用服务 (取消自启)"
    echo "========================================================"
    echo " 00. 退出"
    echo "--------------------------------------------------------"
}

# ----------------- [ 3. 主循环 ] -----------------
main_loop() {
    while true; do
        show_status_header
        show_main_menu
        read -p "请选择操作 [1-9, 00]: " choice

        clear
        echo "========================================================"
        echo "                 执行操作: $choice"
        echo "========================================================"
        
        case "$choice" in
            1) do_start ;;
            2) do_stop ;;
            3)
                echo "--- 正在停止... ---"
                do_stop
                echo ""
                echo "--- 正在启动... ---"
                do_start
                echo "✅ 重启完成."
                ;;
            4) do_status_detail ;;
            5) do_add_rule ;;
            6) do_delete_rule ;;
            7) do_save ;;
            8) do_enable_boot ;;
            9) do_disable_boot ;;
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

# ----------------- [ 4. 启动脚本 ] -----------------

# 1. 检查依赖
check_deps

# 2. 检测公网接口
EXT_IF=$(detect_wan_if)
if [[ -z "$EXT_IF" ]]; then
    echo "❌ 致命错误: 无法自动检测公网接口 (EXT_IF)。" >&2
    echo "   请检查您的网络连接和默认路由。" >&2
    exit 1
fi

# 3. 启动主 TUI 循环
main_loop
