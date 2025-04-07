#!/bin/bash

# 检测系统类型
OS=$(uname -s)
DISTRO=$(cat /etc/*release | grep ^ID= | cut -d= -f2 | tr -d '"')

if [[ "$DISTRO" == "debian" || "$DISTRO" == "ubuntu" ]]; then
    PACKAGE_MANAGER="apt"
    SYSTEM_TYPE="debian"
elif [[ "$DISTRO" == "alpine" ]]; then
    PACKAGE_MANAGER="apk"
    SYSTEM_TYPE="alpine"
else
    echo "不支持此操作系统！请使用 Debian 或 Alpine。"
    exit 1
fi

# 更新包管理器
echo "更新包管理器..."
sudo $PACKAGE_MANAGER update -y

# 安装依赖
echo "安装依赖..."
if [[ "$SYSTEM_TYPE" == "debian" ]]; then
    sudo apt install -y curl git make gcc
elif [[ "$SYSTEM_TYPE" == "alpine" ]]; then
    sudo apk add --no-cache curl git make gcc
fi

# 安装 sing-box
echo "安装 sing-box..."
SING_BOX_VERSION="latest"  # 可以根据需求更改版本
curl -L "https://github.com/SagerNet/sing-box/releases/download/v$SING_BOX_VERSION/sing-box-linux-amd64.tar.gz" -o sing-box.tar.gz
tar -zxvf sing-box.tar.gz
sudo mv sing-box /usr/local/bin/

# 配置 sing-box
echo "配置 sing-box..."

# 获取输入：端口
read -p "请输入要配置的端口 [默认 8080]: " PORT
PORT=${PORT:-8080}

# 获取输入：选择协议 (tuic 或 hysteria2)
echo "请选择协议（1: TUIC, 2: Hysteria2）"
read -p "请输入协议选择 [默认 1]: " PROTOCOL
PROTOCOL=${PROTOCOL:-1}

if [[ "$PROTOCOL" == "1" ]]; then
    PROTOCOL="tuic"
else
    PROTOCOL="hysteria2"
fi

# 获取证书设置
echo "正在生成证书..."
mkdir -p /etc/ssl/sing-box
openssl req -x509 -newkey rsa:4096 -keyout /etc/ssl/sing-box/private.key -out /etc/ssl/sing-box/certificate.crt -days 365 -nodes -subj "/CN=www.bing.com"

# 配置 sing-box 配置文件
CONFIG_DIR="/etc/sing-box"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/config.json" << EOF
{
    "log": {
        "level": "info",
        "output": "file",
        "path": "/var/log/sing-box.log"
    },
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "$PROTOCOL",
            "settings": {
                "certificates": [
                    {
                        "certificate": "/etc/ssl/sing-box/certificate.crt",
                        "key": "/etc/ssl/sing-box/private.key"
                    }
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {}
        }
    ]
}
EOF

# 创建启动脚本
echo "创建启动脚本..."
cat > /usr/local/bin/sb << EOF
#!/bin/bash
sing-box -c /etc/sing-box/config.json
EOF

chmod +x /usr/local/bin/sb

# 启动 sing-box
echo "启动 sing-box..."
sb

# 提示用户
echo "安装和配置完成！现在你可以使用 'sb' 命令来启动 sing-box。"
