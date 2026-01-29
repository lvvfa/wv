#!/bin/bash

# 颜色定义
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'

# 基础日志函数
function LOGD() {
    echo -e "${yellow}[调试] $* ${plain}"
}

function LOGE() {
    echo -e "${red}[错误] $* ${plain}"
}

function LOGI() {
    echo -e "${green}[信息] $* ${plain}"
}

# 端口助手：检测监听状态及占用进程
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

# 简单验证助手
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# 检查 root 权限
[[ $EUID -ne 0 ]] && LOGE "错误：必须使用 root 用户运行此脚本！\n" && exit 1

# 检查操作系统
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "无法检测系统发行版，请联系作者！" >&2
    exit 1
fi
echo "系统发行版为: $release"

os_version=""
os_version=$(grep "^VERSION_ID" /etc/os-release | cut -d '=' -f2 | tr -d '"' | tr -d '.')

# 声明变量
xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"
log_folder="${XUI_LOG_FOLDER:=/var/log/x-ui}"
mkdir -p "${log_folder}"
iplimit_log_path="${log_folder}/3xipl.log"
iplimit_banned_log_path="${log_folder}/3xipl-banned.log"

confirm() {
    if [[ $# > 1 ]]; then
        echo && read -rp "$1 [默认 $2]: " temp
        if [[ "${temp}" == "" ]]; then
            temp=$2
        fi
    else
        read -rp "$1 [y/n]: " temp
    fi
    if [[ "${temp}" == "y" || "${temp}" == "Y" ]]; then
        return 0
    else
        return 1
    fi
}

confirm_restart() {
    confirm "是否重启面板？注意：重启面板也会重启 xray" "y"
    if [[ $? == 0 ]]; then
        restart
    else
        show_menu
    fi
}

before_show_menu() {
    echo && echo -n -e "${yellow}按回车键返回主菜单: ${plain}" && read -r temp
    show_menu
}

install() {
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/install.sh)
    if [[ $? == 0 ]]; then
        if [[ $# == 0 ]]; then
            start
        else
            start 0
        fi
    fi
}

update() {
    confirm "此功能将更新所有 x-ui 组件到最新版本，数据不会丢失。是否继续？" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消更新"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/main/update.sh)
    if [[ $? == 0 ]]; then
        LOGI "更新完成，面板已自动重启"
        before_show_menu
    fi
}

update_menu() {
    echo -e "${yellow}正在更新菜单脚本...${plain}"
    confirm "此功能将把管理脚本（x-ui 命令）更新到最新版。" "y"
    if [[ $? != 0 ]]; then
        LOGE "已取消"
        if [[ $# == 0 ]]; then
            before_show_menu
        fi
        return 0
    fi

    curl -fLRo /usr/bin/x-ui https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh
    chmod +x ${xui_folder}/x-ui.sh
    chmod +x /usr/bin/x-ui

    if [[ $? == 0 ]]; then
        echo -e "${green}脚本更新成功。${plain}"
        exit 0
    else
        echo -e "${red}更新脚本失败。${plain}"
        return 1
    fi
}

legacy_version() {
    echo -n "请输入面板版本号 (例如 2.4.0):"
    read -r tag_version

    if [ -z "$tag_version" ]; then
        echo "版本号不能为空，退出。"
        exit 1
    fi
    install_command="bash <(curl -Ls "https://raw.githubusercontent.com/mhsanaei/3x-ui/v$tag_version/install.sh") v$tag_version"

    echo "正在下载并安装面板版本 v$tag_version..."
    eval $install_command
}

delete_script() {
    rm "$0"
    exit 1
}

uninstall() {
    confirm "确定要卸载面板吗？xray 也会被卸载！" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi

    if [[ $release == "alpine" ]]; then
        rc-service x-ui stop
        rc-update del x-ui
        rm /etc/init.d/x-ui -f
    else
        systemctl stop x-ui
        systemctl disable x-ui
        rm ${xui_service}/x-ui.service -f
        systemctl daemon-reload
        systemctl reset-failed
    fi

    rm /etc/x-ui/ -rf
    rm ${xui_folder}/ -rf

    echo ""
    echo -e "卸载成功。\n"
    echo "如果你想再次安装，可以使用以下命令："
    echo -e "${green}bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)${plain}"
    echo ""
    trap delete_script SIGTERM
    delete_script
}

reset_user() {
    confirm "确定要重置面板的用户名和密码吗？" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    
    read -rp "请输入新用户名 [默认随机生成]: " config_account
    [[ -z $config_account ]] && config_account=$(gen_random_string 10)
    read -rp "请输入新密码 [默认随机生成]: " config_password
    [[ -z $config_password ]] && config_password=$(gen_random_string 18)

    read -rp "是否禁用当前配置的二次身份验证 (2FA)？ (y/n): " twoFactorConfirm
    if [[ $twoFactorConfirm != "y" && $twoFactorConfirm != "Y" ]]; then
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor false >/dev/null 2>&1
    else
        ${xui_folder}/x-ui setting -username "${config_account}" -password "${config_password}" -resetTwoFactor true >/dev/null 2>&1
        echo -e "二次身份验证已禁用。"
    fi
    
    echo -e "面板用户名已重置为: ${green} ${config_account} ${plain}"
    echo -e "面板密码已重置为: ${green} ${config_password} ${plain}"
    echo -e "${green} 请使用新凭据登录面板，并务必记住它们！ ${plain}"
    confirm_restart
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

reset_webbasepath() {
    echo -e "${yellow}正在重置 Web 根路径 (Base Path)...${plain}"

    read -rp "确定要重置 Web 根路径吗？ (y/n): " confirm
    if [[ $confirm != "y" && $confirm != "Y" ]]; then
        echo -e "${yellow}操作取消。${plain}"
        return
    fi

    config_webBasePath=$(gen_random_string 18)
    ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}" >/dev/null 2>&1

    echo -e "Web 根路径已重置为: ${green}/${config_webBasePath}${plain}"
    echo -e "${green}请使用新的根路径访问面板。${plain}"
    restart
}

reset_config() {
    confirm "确定重置所有面板设置吗？(账号数据不会丢失，用户名密码不变)" "n"
    if [[ $? != 0 ]]; then
        if [[ $# == 0 ]]; then
            show_menu
        fi
        return 0
    fi
    ${xui_folder}/x-ui setting -reset
    echo -e "所有面板设置已恢复默认。"
    restart
}

check_config() {
    local info=$(${xui_folder}/x-ui setting -show true)
    if [[ $? != 0 ]]; then
        LOGE "获取当前设置失败，请检查日志"
        show_menu
        return
    fi
    LOGI "当前配置信息：\n${info}"

    local existing_webBasePath=$(echo "$info" | grep -Eo 'webBasePath: .+' | awk '{print $2}')
    local existing_port=$(echo "$info" | grep -Eo 'port: .+' | awk '{print $2}')
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    local server_ip=$(curl -s --max-time 3 https://api.ipify.org)
    if [ -z "$server_ip" ]; then
        server_ip=$(curl -s --max-time 3 https://4.ident.me)
    fi

    if [[ -n "$existing_cert" ]]; then
        local domain=$(basename "$(dirname "$existing_cert")")

        if [[ "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            echo -e "${green}访问地址: https://${domain}:${existing_port}${existing_webBasePath}${plain}"
        else
            echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
        fi
    else
        echo -e "${red}⚠ 警告: 未配置 SSL 证书！${plain}"
        echo -e "${yellow}你可以为你的 IP 地址申请 Let's Encrypt 证书（有效期约6天，自动续期）。${plain}"
        read -rp "现在为 IP 生成 SSL 证书吗？ [y/N]: " gen_ssl
        if [[ "$gen_ssl" == "y" || "$gen_ssl" == "Y" ]]; then
            stop >/dev/null 2>&1
            ssl_cert_issue_for_ip
            if [[ $? -eq 0 ]]; then
                echo -e "${green}访问地址: https://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
                start >/dev/null 2>&1
            else
                LOGE "IP 证书设置失败。"
                echo -e "${yellow}你可以通过选项 18 (SSL 证书管理) 再次尝试。${plain}"
                start >/dev/null 2>&1
            fi
        else
            echo -e "${yellow}访问地址: http://${server_ip}:${existing_port}${existing_webBasePath}${plain}"
            echo -e "${yellow}为了安全，请使用选项 18 配置 SSL 证书${plain}"
        fi
    fi
}

set_port() {
    echo -n "请输入端口号 [1-65535]: "
    read -r port
    if [[ -z "${port}" ]]; then
        LOGD "操作已取消"
        before_show_menu
    else
        ${xui_folder}/x-ui setting -port ${port}
        echo -e "端口设置成功，请重启面板，并使用新端口 ${green}${port}${plain} 访问"
        confirm_restart
    fi
}

start() {
    check_status
    if [[ $? == 0 ]]; then
        echo ""
        LOGI "面板已在运行中，无需再次启动。如需重启请选择重启选项。"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui start
        else
            systemctl start x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 0 ]]; then
            LOGI "x-ui 启动成功"
        else
            LOGE "面板启动失败，可能由于启动时间过长，请稍后检查日志"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

stop() {
    check_status
    if [[ $? == 1 ]]; then
        echo ""
        LOGI "面板已停止，无需再次操作！"
    else
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        sleep 2
        check_status
        if [[ $? == 1 ]]; then
            LOGI "x-ui 和 xray 停止成功"
        else
            LOGE "面板停止失败，可能超过了停止等待时间，请检查日志"
        fi
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

restart() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui restart
    else
        systemctl restart x-ui
    fi
    sleep 2
    check_status
    if [[ $? == 0 ]]; then
        LOGI "x-ui 和 xray 重启成功"
    else
        LOGE "面板重启失败，请检查日志"
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

status() {
    if [[ $release == "alpine" ]]; then
        rc-service x-ui status
    else
        systemctl status x-ui -l
    fi
    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

enable() {
    if [[ $release == "alpine" ]]; then
        rc-update add x-ui
    else
        systemctl enable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui 已设置为开机自启"
    else
        LOGE "设置自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

disable() {
    if [[ $release == "alpine" ]]; then
        rc-update del x-ui
    else
        systemctl disable x-ui
    fi
    if [[ $? == 0 ]]; then
        LOGI "x-ui 已取消开机自启"
    else
        LOGE "取消自启失败"
    fi

    if [[ $# == 0 ]]; then
        before_show_menu
    fi
}

show_log() {
    if [[ $release == "alpine" ]]; then
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice

        case "$choice" in
        0) show_menu ;;
        1)
            grep -F 'x-ui[' /var/log/messages
            if [[ $# == 0 ]]; then before_show_menu; fi
            ;;
        *)
            echo -e "${red}无效选项${plain}\n"
            show_log
            ;;
        esac
    else
        echo -e "${green}\t1.${plain} 调试日志"
        echo -e "${green}\t2.${plain} 清除所有日志"
        echo -e "${green}\t0.${plain} 返回主菜单"
        read -rp "请选择: " choice

        case "$choice" in
        0) show_menu ;;
        1)
            journalctl -u x-ui -e --no-pager -f -p debug
            if [[ $# == 0 ]]; then before_show_menu; fi
            ;;
        2)
            sudo journalctl --rotate
            sudo journalctl --vacuum-time=1s
            echo "所有日志已清除。"
            restart
            ;;
        *)
            echo -e "${red}无效选项${plain}\n"
            show_log
            ;;
        esac
    fi
}

bbr_menu() {
    echo -e "${green}\t1.${plain} 开启 BBR"
    echo -e "${green}\t2.${plain} 关闭 BBR"
    echo -e "${green}\t0.${plain} 返回主菜单"
    read -rp "请选择: " choice
    case "$choice" in
    0) show_menu ;;
    1) enable_bbr; bbr_menu ;;
    2) disable_bbr; bbr_menu ;;
    *) echo -e "${red}无效选项${plain}\n"; bbr_menu ;;
    esac
}

disable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${yellow}BBR 当前未开启。${plain}"
        before_show_menu
    fi

    if [ -f "/etc/sysctl.d/99-bbr-x-ui.conf" ]; then
        rm /etc/sysctl.d/99-bbr-x-ui.conf
        sysctl --system
    else
        if [ -f "/etc/sysctl.conf" ]; then
            sed -i 's/net.core.default_qdisc=fq/net.core.default_qdisc=pfifo_fast/' /etc/sysctl.conf
            sed -i 's/net.ipv4.tcp_congestion_control=bbr/net.ipv4.tcp_congestion_control=cubic/' /etc/sysctl.conf
            sysctl -p
        fi
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) != "bbr" ]]; then
        echo -e "${green}BBR 已成功替换为 CUBIC。${plain}"
    else
        echo -e "${red}关闭 BBR 失败。${plain}"
    fi
}

enable_bbr() {
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR 已经开启！${plain}"
        before_show_menu
    fi

    if [ -d "/etc/sysctl.d/" ]; then
        {
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } > "/etc/sysctl.d/99-bbr-x-ui.conf"
        sysctl --system
    else
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p
    fi

    if [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]]; then
        echo -e "${green}BBR 开启成功。${plain}"
    else
        echo -e "${red}开启 BBR 失败。${plain}"
    fi
}

# 状态检查函数 (略, 已包含逻辑)
# ... 其他辅助函数 ...

show_status() {
    check_status
    case $? in
    0) echo -e "面板状态: ${green}运行中${plain}"; show_enable_status ;;
    1) echo -e "面板状态: ${yellow}未运行${plain}"; show_enable_status ;;
    2) echo -e "面板状态: ${red}未安装${plain}" ;;
    esac
    show_xray_status
}

show_enable_status() {
    check_enabled
    if [[ $? == 0 ]]; then
        echo -e "开机自启: ${green}是${plain}"
    else
        echo -e "开机自启: ${red}否${plain}"
    fi
}

show_xray_status() {
    check_xray_status
    if [[ $? == 0 ]]; then
        echo -e "xray 状态: ${green}运行中${plain}"
    else
        echo -e "xray 状态: ${red}未运行${plain}"
    fi
}

# 菜单主体
show_menu() {
    echo -e "
╔────────────────────────────────────────────────╗
│   ${green}3X-UI 面板管理脚本 (中文版)${plain}                 │
│   ${green}0.${plain} 退出脚本                                  │
│────────────────────────────────────────────────│
│   ${green}1.${plain} 安装面板                                  │
│   ${green}2.${plain} 更新面板                                  │
│   ${green}3.${plain} 更新管理脚本                               │
│   ${green}4.${plain} 安装历史版本                               │
│   ${green}5.${plain} 卸载面板                                  │
│────────────────────────────────────────────────│
│   ${green}6.${plain} 重置用户名密码                             │
│   ${green}7.${plain} 重置 Web 根路径                            │
│   ${green}8.${plain} 重置面板所有设置                          │
│   ${green}9.${plain} 修改面板端口                               │
│  ${green}10.${plain} 查看当前设置                               │
│────────────────────────────────────────────────│
│  ${green}11.${plain} 启动面板                                  │
│  ${green}12.${plain} 停止面板                                  │
│  ${green}13.${plain} 重启面板                                  │
│  ${green}14.${plain} 查看运行状态                               │
│  ${green}15.${plain} 日志管理                                  │
│────────────────────────────────────────────────│
│  ${green}16.${plain} 设置开机自启                               │
│  ${green}17.${plain} 取消开机自启                               │
│────────────────────────────────────────────────│
│  ${green}18.${plain} SSL 证书管理 (域名)                        │
│  ${green}19.${plain} SSL 证书管理 (Cloudflare DNS)             │
│  ${green}20.${plain} IP 访问限制管理 (Fail2ban)                 │
│  ${green}21.${plain} 防火墙管理 (UFW)                           │
│  ${green}22.${plain} SSH 端口转发管理                            │
│────────────────────────────────────────────────│
│  ${green}23.${plain} 开启 BBR 加速                              │
│  ${green}24.${plain} 更新 Geo 资源文件                          │
│  ${green}25.${plain} 运行 Speedtest 测速                       │
╚────────────────────────────────────────────────╝
"
    show_status
    echo && read -rp "请输入选项 [0-25]: " num

    case "${num}" in
    0) exit 0 ;;
    1) check_uninstall && install ;;
    2) check_install && update ;;
    3) check_install && update_menu ;;
    4) check_install && legacy_version ;;
    5) check_install && uninstall ;;
    6) check_install && reset_user ;;
    7) check_install && reset_webbasepath ;;
    8) check_install && reset_config ;;
    9) check_install && set_port ;;
    10) check_install && check_config ;;
    11) check_install && start ;;
    12) check_install && stop ;;
    13) check_install && restart ;;
    14) check_install && status ;;
    15) check_install && show_log ;;
    16) check_install && enable ;;
    17) check_install && disable ;;
    18) ssl_cert_issue_main ;;
    19) ssl_cert_issue_CF ;;
    20) iplimit_main ;;
    21) firewall_menu ;;
    22) SSH_port_forwarding ;;
    23) bbr_menu ;;
    24) update_geo ;;
    25) run_speedtest ;;
    *) LOGE "请输入正确的数字 [0-25]" ;;
    esac
}

# 入口判断逻辑保持不变...
