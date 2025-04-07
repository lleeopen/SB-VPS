#!/bin/bash

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用root用户运行此脚本！"
    exit 1
fi

# 检测系统
detect_system() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    else
        echo "未知系统，脚本将退出"
        exit 1
    fi
}

SYSTEM=$(detect_system)

# 安装依赖
install_deps() {
    echo "安装系统依赖..."
    if [ "$SYSTEM" = "alpine" ]; then
        apk update
        apk add --no-cache bash openssl curl jq openssh-client
    elif [ "$SYSTEM" = "debian" ]; then
        apt update
        apt install -y bash openssl curl jq openssh-client
    fi
}

# 安装sing-box
install_singbox() {
    LATEST_VERSION=$(curl -sL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | cut -d'"' -f4)
    echo "最新sing-box版本: $LATEST_VERSION"
    
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") ARCH="amd64" ;;
        "aarch64") ARCH="arm64" ;;
        "armv7l") ARCH="armv7" ;;
        *) echo "不支持的架构: $ARCH"; exit 1 ;;
    esac
    
    echo "下载sing-box..."
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/$LATEST_VERSION/sing-box-$LATEST_VERSION-linux-$ARCH.tar.gz"
    curl -Lo sing-box.tar.gz "$DOWNLOAD_URL"
    tar -xzf sing-box.tar.gz
    cp "sing-box-$LATEST_VERSION-linux-$ARCH/sing-box" /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    # 创建配置目录
    mkdir -p /etc/sing-box
    
    # 创建systemd服务
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    rm -rf "sing-box-$LATEST_VERSION-linux-$ARCH" sing-box.tar.gz
}

# 生成自签证书
generate_cert() {
    echo "为www.bing.com生成自签证书..."
    mkdir -p /etc/sing-box/certs
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/sing-box/certs/key.pem \
        -out /etc/sing-box/certs/cert.pem \
        -subj "/CN=www.bing.com" \
        -days 3650
    
    chmod 600 /etc/sing-box/certs/*.pem
}

# 生成UUID
generate_uuid() {
    sing-box generate uuid
}

# 生成密码
generate_password() {
    openssl rand -hex 8
}

# 生成配置
generate_config() {
    echo "生成sing-box配置..."
    
    read -p "输入tuic监听端口 (默认: 11443): " TUIC_PORT
    TUIC_PORT=${TUIC_PORT:-11443}
    
    read -p "输入hysteria2监听端口 (默认: 11543): " HYSTERIA_PORT
    HYSTERIA_PORT=${HYSTERIA_PORT:-11543}
    
    TUIC_UUID=$(generate_uuid)
    TUIC_PASSWORD=$(generate_password)
    HYSTERIA_PASSWORD=$(generate_password)
    
    cat > /etc/sing-box/config.json <<EOF
{
    "log": {
        "level": "info",
        "timestamp": true
    },
    "inbounds": [
        {
            "type": "tuic",
            "tag": "tuic-in",
            "listen": "::",
            "listen_port": $TUIC_PORT,
            "tcp_fast_open": true,
            "sniff": true,
            "sniff_override_destination": true,
            "users": [
                {
                    "uuid": "$TUIC_UUID",
                    "password": "$TUIC_PASSWORD"
                }
            ],
            "congestion_control": "bbr",
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "certificate_path": "/etc/sing-box/certs/cert.pem",
                "key_path": "/etc/sing-box/certs/key.pem"
            }
        },
        {
            "type": "hysteria2",
            "tag": "hysteria2-in",
            "listen": "::",
            "listen_port": $HYSTERIA_PORT,
            "tcp_fast_open": true,
            "sniff": true,
            "sniff_override_destination": true,
            "users": [
                {
                    "password": "$HYSTERIA_PASSWORD"
                }
            ],
            "tls": {
                "enabled": true,
                "server_name": "www.bing.com",
                "certificate_path": "/etc/sing-box/certs/cert.pem",
                "key_path": "/etc/sing-box/certs/key.pem"
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
}
EOF
    
    # 显示配置信息
    echo "================================"
    echo "配置信息:"
    echo "TUIC 配置:"
    echo "端口: $TUIC_PORT"
    echo "UUID: $TUIC_UUID"
    echo "密码: $TUIC_PASSWORD"
    echo "SNI: www.bing.com"
    echo "------------------------"
    echo "Hysteria2 配置:"
    echo "端口: $HYSTERIA_PORT"
    echo "密码: $HYSTERIA_PASSWORD"
    echo "SNI: www.bing.com"
    echo "================================"
}

# 创建控制脚本
create_control_script() {
    cat > /usr/local/bin/sb <<EOF
#!/bin/bash

case "\$1" in
    "start")
        systemctl start sing-box
        echo "sing-box 已启动"
        ;;
    "stop")
        systemctl stop sing-box
        echo "sing-box 已停止"
        ;;
    "restart")
        systemctl restart sing-box
        echo "sing-box 已重启"
        ;;
    "status")
        systemctl status sing-box
        ;;
    "log")
        journalctl -u sing-box -f
        ;;
    "reconfig")
        generate_config
        systemctl restart sing-box
        echo "配置已重新生成并重启服务"
        ;;
    *)
        echo "用法: sb {start|stop|restart|status|log|reconfig}"
        ;;
esac
EOF
    
    chmod +x /usr/local/bin/sb
}

# 主安装过程
main_install() {
    install_deps
    install_singbox
    generate_cert
    generate_config
    create_control_script
    
    # 启动服务
    systemctl enable --now sing-box
    
    echo "安装完成！"
    echo "使用 'sb' 命令控制sing-box:"
    echo "  sb start     - 启动服务"
    echo "  sb stop      - 停止服务"
    echo "  sb restart   - 重启服务"
    echo "  sb status    - 查看状态"
    echo "  sb log       - 查看日志"
    echo "  sb reconfig  - 重新生成配置"
}

# 卸载
uninstall() {
    systemctl stop sing-box
    systemctl disable sing-box
    rm -f /etc/systemd/system/sing-box.service
    rm -f /usr/local/bin/sing-box
    rm -f /usr/local/bin/sb
    rm -rf /etc/sing-box
    systemctl daemon-reload
    
    echo "sing-box 已卸载"
}

# 显示菜单
show_menu() {
    echo "================================"
    echo " sing-box 安装脚本"
    echo "================================"
    echo "1. 安装 sing-box (包含tuic和hysteria2)"
    echo "2. 卸载 sing-box"
    echo "3. 退出"
    echo "================================"
    read -p "请输入选项 (1-3): " OPTION
    
    case "$OPTION" in
        1) main_install ;;
        2) uninstall ;;
        3) exit 0 ;;
        *) echo "无效选项"; exit 1 ;;
    esac
}

show_menu
