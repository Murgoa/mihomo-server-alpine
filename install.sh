#!/usr/bin/env bash
set -e

# 检查端口是否被占用
is_port_used() {
    local port=$1
    grep -q ":$(printf '%04X' $port)" /proc/net/tcp /proc/net/udp 2>/dev/null
}

# 获取有效端口
get_valid_port() {
    local prompt=$1
    local forbidden_ports=($2)
    local port

    while true; do
        read -p "$prompt（直接回车使用随机端口）: " input
        if [ -z "$input" ]; then
            while true; do
                port=$((RANDOM % 40001 + 20000))
                if ! is_port_used $port; then
                    local conflict=0
                    for fp in "${forbidden_ports[@]}"; do
                        [ "$port" -eq "$fp" ] && conflict=1 && break
                    done
                    [ $conflict -eq 0 ] && echo "$port" && return
                fi
            done
        else
            if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -lt 1 ] || [ "$input" -gt 65535 ]; then
                echo "❌ 请输入有效的端口号（1-65535）"
                continue
            fi
            port="$input"
            if is_port_used $port; then
                echo "❌ 端口 $port 已被占用，请换一个"
                continue
            fi
            local conflict=0
            for fp in "${forbidden_ports[@]}"; do
                [ "$port" -eq "$fp" ] && conflict=1 && break
            done
            if [ $conflict -eq 1 ]; then
                echo "❌ 端口不能与其他协议端口重复，请换一个"
                continue
            fi
            echo "$port"
            return
        fi
    done
}

# ==========
# 通用一键安装脚本（兼容 Alpine、Debian、Ubuntu）
# 支持 Hysteria2 + AnyTLS + Shadowsocks-2022 + TUIC v5
# 配置文件统一放在 /etc/mihomo/
# ==========

# 检测系统类型
if command -v apk &>/dev/null; then
    OS="alpine"
    PKG_MANAGER="apk"
    INIT_SYSTEM="openrc"
elif command -v apt &>/dev/null; then
    OS="debian"
    PKG_MANAGER="apt"
    INIT_SYSTEM="systemd"
else
    echo "❌ 不支持的系统，仅支持 Alpine、Debian、Ubuntu"
    exit 1
fi

echo "🖥️  检测到系统: $OS ($INIT_SYSTEM)"

# 安装依赖
install_dependencies() {
    echo "🔧 安装必要依赖..."
    if [ "$PKG_MANAGER" = "apk" ]; then
        apk update
        apk add --no-cache curl openssl wget gzip util-linux
    elif [ "$PKG_MANAGER" = "apt" ]; then
        apt update -y
        apt install -y curl openssl wget gzip uuid-runtime ca-certificates
    fi
}

for cmd in curl wget gzip openssl uuidgen; do
    if ! command -v "$cmd" &>/dev/null; then
        install_dependencies
        break
    fi
done

# 检测架构
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  BIN_ARCH="amd64" ;;
    aarch64) BIN_ARCH="arm64" ;;
    armv7l)  BIN_ARCH="armv7" ;;
    armv6l)  BIN_ARCH="armv6" ;;
    *)       echo "❌ 不支持的架构: $ARCH" && exit 1 ;;
esac

# CPU 指令集（仅 amd64）
CPU_FLAGS=$(grep flags /proc/cpuinfo | head -n1 || echo "")
if [[ $BIN_ARCH == "amd64" && $CPU_FLAGS =~ avx2 ]]; then
    LEVEL="v3"
elif [[ $BIN_ARCH == "amd64" && $CPU_FLAGS =~ avx ]]; then
    LEVEL="v2"
else
    LEVEL="v1"
fi
echo "🧠 CPU 架构: $ARCH, 指令集等级: $LEVEL"

# 下载并安装 Mihomo
if ! command -v mihomo &>/dev/null; then
    echo "⬇️  正在安装 mihomo ..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$LATEST_VERSION" ] && echo "❌ 获取版本失败" && exit 1

    if [ "$OS" = "alpine" ]; then
        PRI_FILE="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
        FALLBACK_FILE="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
    else
        if [ "$BIN_ARCH" = "amd64" ]; then
            PRI_FILE="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
        else
            PRI_FILE="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
        fi
        FALLBACK_FILE="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
    fi

    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${PRI_FILE}"
    if ! wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" 2>/dev/null; then
        echo "⚠️ 主版本下载失败，尝试备用版本..."
        DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FALLBACK_FILE}"
        wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || { echo "❌ 下载失败" && exit 1; }
    fi

    gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo
    echo "✅ mihomo 安装完成"
else
    echo "✅ 已检测到 mihomo，跳过安装"
fi

# 统一使用 /etc/mihomo 作为配置目录
CONFIG_DIR="/etc/mihomo"
mkdir -p "$CONFIG_DIR"
echo "🔐 生成自签名证书到 $CONFIG_DIR ..."
openssl req -newkey rsa:2048 -nodes -keyout "$CONFIG_DIR/server.key" -x509 -days 365 -out "$CONFIG_DIR/server.crt" -subj "/C=US/ST=CA/L=SF/O=$(openssl rand -hex 8)/CN=$(openssl rand -hex 12)"

HY2_PASSWORD=$(uuidgen)
ANYTLS_PASSWORD=$(uuidgen)
SS2022_SERVER_KEY=$(openssl rand -base64 24)
TUIC_UUID=$(uuidgen)
TUIC_PASSWORD=$(uuidgen)

echo ""
echo "🌟 请为四个协议设置监听端口（NAT VPS 请使用放行端口，如 443）"
HY2_PORT=$(get_valid_port "请输入 Hysteria2 端口" "")
ANYTLS_PORT=$(get_valid_port "请输入 AnyTLS 端口" "$HY2_PORT")
SS2022_PORT=$(get_valid_port "请输入 Shadowsocks-2022 端口" "$HY2_PORT $ANYTLS_PORT")
TUIC_PORT=$(get_valid_port "请输入 TUIC v5 端口" "$HY2_PORT $ANYTLS_PORT $SS2022_PORT")

echo "✅ 端口设置完成：Hy2 $HY2_PORT | AnyTLS $ANYTLS_PORT | SS2022 $SS2022_PORT | TUIC $TUIC_PORT"

# 生成 config.yaml
cat > "$CONFIG_DIR/config.yaml" <<EOF
listeners:
- name: anytls-in-1
  type: anytls
  port: $ANYTLS_PORT
  listen: 0.0.0.0
  users:
    username1: '$ANYTLS_PASSWORD'
  certificate: ./server.crt
  private-key: ./server.key
- name: hy2
  type: hysteria2
  port: $HY2_PORT
  listen: 0.0.0.0
  users:
    user1: $HY2_PASSWORD
  certificate: ./server.crt
  private-key: ./server.key
- name: ss2022
  type: shadowsocks
  port: $SS2022_PORT
  listen: 0.0.0.0
  cipher: 2022-blake3-aes-256-gcm
  password: $SS2022_SERVER_KEY
  udp: true
- name: tuic
  type: tuic
  port: $TUIC_PORT
  listen: 0.0.0.0
  certificate: ./server.crt
  private-key: ./server.key
  users:
    "$TUIC_UUID": "$TUIC_PASSWORD"
  congestion-controller: bbr
  udp: true
  alpn:
    - h3
EOF

# 创建服务（统一使用 /etc/mihomo）
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=3
User=root
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now mihomo.service
else  # openrc
    cat > /etc/init.d/mihomo <<'EOF'
#!/sbin/openrc-run
description="Mihomo Service"
command="/usr/local/bin/mihomo"
command_args="-d /etc/mihomo"
pidfile="/run/mihomo.pid"
command_background="yes"
depend() { need net; after firewall; }
start_pre() { mkdir -p $(dirname $pidfile); }
EOF
    chmod +x /etc/init.d/mihomo
    rc-update add mihomo default
    rc-service mihomo start
fi

PUBLIC_IP=$(curl -4 -s ifconfig.me || echo "你的公网IP")

# 输出客户端配置（保持不变）
echo -e "\n\n新的客户端配置信息："
echo "=============================================="
echo "1. Hysteria2: server $PUBLIC_IP:$HY2_PORT  password: $HY2_PASSWORD  sni: bing.com"
echo "2. AnyTLS:    server $PUBLIC_IP:$ANYTLS_PORT  password: $ANYTLS_PASSWORD  sni: www.usavps.com"
echo "3. SS2022:    server $PUBLIC_IP:$SS2022_PORT  cipher: 2022-blake3-aes-256-gcm  password: $SS2022_SERVER_KEY"
echo "4. TUIC v5:   server $PUBLIC_IP:$TUIC_PORT  uuid: $TUIC_UUID  password: $TUIC_PASSWORD  sni: www.usavps.com"
echo "=============================================="

echo -e "\nCompact 配置（直接粘贴到 proxies）:"
echo "----------------------------------------------"
echo "- {name: \"$PUBLIC_IP｜Direct｜anytls\", type: anytls, server: $PUBLIC_IP, port: $ANYTLS_PORT, password: \"$ANYTLS_PASSWORD\", skip-cert-verify: true, sni: www.usavps.com, udp: true, tfo: true, tls: true, client-fingerprint: chrome}"
echo "- {name: \"$PUBLIC_IP｜Direct｜hy2\", type: hysteria2, server: $PUBLIC_IP, port: $HY2_PORT, password: \"$HY2_PASSWORD\", udp: true, sni: bing.com, skip-cert-verify: true}"
echo "- {name: \"$PUBLIC_IP｜Direct｜ss2022\", type: ss, server: $PUBLIC_IP, port: $SS2022_PORT, cipher: 2022-blake3-aes-256-gcm, password: \"$SS2022_SERVER_KEY\", udp: true}"
echo "- {name: \"$PUBLIC_IP｜Direct｜tuic\", type: tuic, server: $PUBLIC_IP, port: $TUIC_PORT, uuid: \"$TUIC_UUID\", password: \"$TUIC_PASSWORD\", sni: www.usavps.com, alpn: [\"h3\"], udp: true, skip-cert-verify: true, congestion-controller: bbr, reduce-rtt: true}"
echo "----------------------------------------------"

echo "hysteria2://$HY2_PASSWORD@$PUBLIC_IP:$HY2_PORT?peer=bing.com&insecure=1#$PUBLIC_IP｜Direct｜hy2"
echo "anytls://$ANYTLS_PASSWORD@$PUBLIC_IP:$ANYTLS_PORT?peer=www.usavps.com&insecure=1&fastopen=1&udp=1#$PUBLIC_IP｜Direct｜anytls"
echo "ss://$(echo -n "2022-blake3-aes-256-gcm:$SS2022_SERVER_KEY" | base64 -w 0)@$PUBLIC_IP:$SS2022_PORT?#$PUBLIC_IP｜Direct｜ss2022"
echo "tuic://$TUIC_UUID:$TUIC_PASSWORD@$PUBLIC_IP:$TUIC_PORT?alpn=h3&sni=www.usavps.com&congestion_control=bbr#$PUBLIC_IP｜Direct｜tuic"

# 重启并显示状态
if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl restart mihomo.service
    echo -e "\n服务状态:"
    systemctl status mihomo --no-pager -l
else
    rc-service mihomo restart
    echo -e "\n服务状态:"
    rc-service mihomo status
fi

echo "✅ 安装完成！配置文件位于 /etc/mihomo/"
