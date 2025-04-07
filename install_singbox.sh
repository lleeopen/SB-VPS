#!/bin/bash

# 确保使用Bash执行（Debian默认dash可能导致问题）
if [ -z "$BASH_VERSION" ]; then
    exec bash "$0" "$@"
fi

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[31m请使用root用户运行此脚本！\033[0m"
    exit 1
fi

# 安装必要依赖（针对Debian 11特别处理）
check_deps() {
    local missing=()
    for cmd in curl tar openssl systemctl; do
        if ! command -v $cmd &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "\033[33m安装依赖: ${missing[*]}...\033[0m"
        apt update
        apt install -y ${missing[@]}
    fi
}

# 安装sing-box
install_singbox() {
    echo -e "\033[32m正在获取最新sing-box版本...\033[0m"
    LATEST_VER=$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | cut -d'"' -f4)
    [ -z "$LATEST_VER" ] && { echo -e "\033[31m获取版本失败\033[0m"; exit 1; }

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo -e "\033[31m不支持的架构: $ARCH\033[0m"; exit 1 ;;
    esac

    echo -e "\033[32m下载sing-box ${LATEST_VER}...\033[0m"
    URL="https://github.com/SagerNet/sing-box/releases/download/${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz"
    if ! curl -Lo sing-box.tar.gz "$URL"; then
        echo -e "\033[31m下载失败！\033[0m"
        exit 1
    fi

    tar -xzf sing-box.tar.gz
    cp sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box

    # 创建服务文件
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target

[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=always
User=root
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    rm -rf sing-box.tar.gz sing-box-*
}

# 生成配置
generate_config() {
    local tuic_port hysteria_port

    while :; do
        read -p "输入TUIC监听端口 [默认: 11443]: " tuic_port
        tuic_port=${tuic_port:-11443}
        [[ $tuic_port =~ ^[0-9]+$ ]] && [ $tuic_port -gt 0 -a $tuic_port -lt 65536 ] && break
        echo -e "\033[31m无效端口！请输入1-65535之间的数字\033[0m"
    done

    while :; do
        read -p "输入Hysteria2监听端口 [默认: 11543]: " hysteria_port
        hysteria_port=${hysteria_port:-11543}
        [[ $hysteria_port =~ ^[0-9]+$ ]] && [ $hysteria_port -gt 0 -a $hysteria_port -lt 65536 ] && [ $hysteria_port -ne $tuic_port ] && break
        echo -e "\033[31m无效端口！请输入1-65535之间且不同于TUIC端口的数字\033[0m"
    done

    mkdir -p /etc/sing-box/certs
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/sing-box/certs/key.pem \
        -out /etc/sing-box/certs/cert.pem \
        -subj "/CN=www.bing.com" -days 3650

    local uuid=$(/usr/local/bin/sing-box generate uuid)
    local tuic_pass=$(openssl rand -hex 8)
    local hysteria_pass=$(openssl rand -hex 8)

    cat > /etc/sing-box/config.json <<EOF
{
    "log": {"level": "info"},
    "inbounds": [
        {
            "type": "tuic",
            "listen": "::",
            "listen_port": $tuic_port,
            "sniff": true,
            "users": [{"uuid": "$uuid", "password": "$tuic_pass"}],
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "certificate_path": "/etc/sing-box/certs/cert.pem",
                "key_path": "/etc/sing-box/certs/key.pem"
            }
        },
        {
            "type": "hysteria2",
            "listen": "::",
            "listen_port": $hysteria_port,
            "users": [{"password": "$hysteria_pass"}],
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "certificate_path": "/etc/sing-box/certs/cert.pem",
                "key_path": "/etc/sing-box/certs/key.pem"
            }
        }
    ],
    "outbounds": [
        {"type": "direct", "tag": "direct"},
        {"type": "block", "tag": "block"}
    ]
}
EOF

    echo -e "\n\033[32m配置生成成功！\033[0m"
    echo -e "TUIC配置:"
    echo -e "端口: \033[33m$tuic_port\033[0m"
    echo -e "UUID: \033[33m$uuid\033[0m"
    echo -e "密码: \033[33m$tuic_pass\033[0m"
    echo -e "Hysteria2配置:"
    echo -e "端口: \033[33m$hysteria_port\033[0m"
    echo -e "密码: \033[33m$hysteria_pass\033[0m"
    echo -e "TLS SNI: \033[33mwww.bing.com\033[0m"
}

# 控制命令
create_control_script() {
    cat > /usr/local/bin/sb <<'EOF'
#!/bin/bash
case "$1" in
    start|stop|restart|status)
        systemctl $1 sing-box
        ;;
    log)
        journalctl -u sing-box -f
        ;;
    reconfig)
        /usr/local/bin/sing-box generate config > /etc/sing-box/config.json
        systemctl restart sing-box
        ;;
    *)
        echo "用法: sb {start|stop|restart|status|log|reconfig}"
        exit 1
        ;;
esac
EOF
    chmod +x /usr/local/bin/sb
}

# 主菜单
show_menu() {
    clear
    echo -e "\033[36m================================="
    echo " Sing-box 安装管理脚本 (Debian 11)"
    echo "================================="
    echo -e "\033[32m1. 安装并配置 sing-box"
    echo "2. 卸载 sing-box"
    echo -e "3. 退出脚本\033[0m"
    echo -e "\033[36m=================================\033[0m"

    while :; do
        read -p "请输入选择 [1-3]: " choice
        case $choice in
            1)
                check_deps
                install_singbox
                generate_config
                create_control_script
                systemctl enable --now sing-box
                echo -e "\033[32m安装完成！使用 'sb' 命令管理服务\033[0m"
                break
                ;;
            2)
                systemctl stop sing-box 2>/dev/null
                systemctl disable sing-box 2>/dev/null
                rm -rf /usr/local/bin/sing-box /usr/local/bin/sb /etc/sing-box
                echo -e "\033[32m已卸载 sing-box\033[0m"
                break
                ;;
            3)
                exit 0
                ;;
            *)
                echo -e "\033[31m无效输入！请输入1-3之间的数字\033[0m"
                ;;
        esac
    done
}

# 启动脚本
show_menu
