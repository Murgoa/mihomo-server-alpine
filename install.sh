#!/usr/bin/env bash
set -e

# 检查端口是否被占用
is_port_used() {
    local port=$1
    grep -q ":$(printf '%04X' $port)" /proc/net/tcp /proc/net/udp 2>/dev/null
}

# 获取有效端口（检查占用 + 与其他端口不冲突）
get_valid_port() {
    local prompt=$1
    local forbidden_ports=($2)  # 数组传入已占用端口
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
# Mihomo 一键安装脚本（Alpine Linux 专用版，Hysteria2 + AnyTLS + Shadowsocks-2022，支持自定义端口）
# ==========

# 检查并安装依赖
install_dependencies() {
    echo "🔧 检查并安装依赖..."
    apk update
    apk add --no-cache curl openssl wget gzip util-linux  # util-linux 提供 uuidgen
    echo "✅ 依赖安装完成"
}

for cmd in curl wget gzip openssl uuidgen; do
    if ! command -v "$cmd" &>/dev/null; then
        install_dependencies
        break
    fi
done

# ==========
# 检测系统架构
# ==========
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        BIN_ARCH="amd64"
        ;;
    aarch64)
        BIN_ARCH="arm64"
        ;;
    armv7l)
        BIN_ARCH="armv7"
        ;;
    armv6l)
        BIN_ARCH="armv6"
        ;;
    *)
        echo "❌ 不支持的架构: $ARCH"
        exit 1
        ;;
esac

# ==========
# 检测 CPU 指令集 (仅 amd64 使用 v1/v2/v3)
# ==========
CPU_FLAGS=$(grep flags /proc/cpuinfo | head -n1 || echo "")
if [[ $BIN_ARCH == "amd64" && $CPU_FLAGS =~ avx2 ]]; then
    LEVEL="v3"
elif [[ $BIN_ARCH == "amd64" && $CPU_FLAGS =~ avx ]]; then
    LEVEL="v2"
else
    LEVEL="v1"
fi
echo "🧠 检测到 CPU 架构: $ARCH, 指令集等级: $LEVEL"

# ==========
# 下载并安装 Mihomo
# ==========
if ! command -v mihomo &>/dev/null; then
    echo "⬇️  正在安装 mihomo ..."

    LATEST_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$LATEST_VERSION" ]; then
        echo "❌ 获取版本号失败"
        exit 1
    fi

    # 优先使用 compatible 版本（更适合 Alpine 的 musl）
    if [ "$BIN_ARCH" = "amd64" ]; then
        FILE_NAME="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
    else
        FILE_NAME="mihomo-linux-${BIN_ARCH}-compatible-${LATEST_VERSION}.gz"
        if ! curl -sLI "https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}" | grep -q "200 OK"; then
            FILE_NAME="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
        fi
    fi

    DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"
    if ! wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" 2>/dev/null; then
        echo "⚠️ compatible 版本下载失败，尝试其他版本..."
        if [ "$BIN_ARCH" = "amd64" ]; then
            FILE_NAME="mihomo-linux-${BIN_ARCH}-${LEVEL}-${LATEST_VERSION}.gz"
        else
            FILE_NAME="mihomo-linux-${BIN_ARCH}-${LATEST_VERSION}.gz"
        fi
        DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${LATEST_VERSION}/${FILE_NAME}"
        wget -O /tmp/mihomo.gz "$DOWNLOAD_URL" || {
            echo "❌ 所有下载方式失败，请检查网络或 GitHub 访问。"
            exit 1
        }
    fi

    echo "📦 下载 ${FILE_NAME} ..."
    gzip -d /tmp/mihomo.gz
    chmod +x /tmp/mihomo
    mv /tmp/mihomo /usr/local/bin/mihomo
    echo "✅ mihomo 安装完成"
else
    echo "✅ 已检测到 mihomo，跳过安装步骤"
fi

# ==========
# 生成配置与证书
# ==========
mkdir -p $HOME/.config/mihomo/
echo "🔐 生成新的 SSL 证书（供 Hysteria2 和 AnyTLS 使用）..."
openssl req -newkey rsa:2048 -nodes \
  -keyout $HOME/.config/mihomo/server.key \
  -x509 -days 365 \
  -out $HOME/.config/mihomo/server.crt \
  -subj "/C=US/ST=CA/L=SF/O=$(openssl rand -hex 8)/CN=$(openssl rand -hex 12)"

HY2_PASSWORD=$(uuidgen)
ANYTLS_PASSWORD=$(uuidgen)

# 生成 Shadowsocks-2022 server key（24 字节 base64）
SS2022_SERVER_KEY=$(openssl rand -base64 24)

echo ""
echo "🌟 请为三个协议设置监听端口（建议使用 NAT 提供商放行的端口）"

# 先设置 HY2 端口
HY2_PORT=$(get_valid_port "请输入 Hysteria2 端口" "")

# 再设置 AnyTLS 端口
ANYTLS_PORT=$(get_valid_port "请输入 AnyTLS 端口" "$HY2_PORT")

# 最后设置 SS2022 端口
SS2022_PORT=$(get_valid_port "请输入 Shadowsocks-2022 端口" "$HY2_PORT $ANYTLS_PORT")

echo "✅ 已设置端口：Hysteria2 $HY2_PORT，AnyTLS $ANYTLS_PORT，Shadowsocks-2022 $SS2022_PORT"

cat > $HOME/.config/mihomo/config.yaml <<EOF
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
EOF

# ==========
# 创建 OpenRC 服务
# ==========
cat > /etc/init.d/mihomo <<'EOF'
#!/sbin/openrc-run

description="Mihomo Service"
command="/usr/local/bin/mihomo"
command_args="-d $HOME/.config/mihomo"
pidfile="/run/mihomo.pid"
command_background="yes"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p $(dirname $pidfile)
}
EOF

chmod +x /etc/init.d/mihomo
rc-update add mihomo default
rc-service mihomo start || {
    echo "⚠️ 服务启动失败，请查看日志: rc-service mihomo status"
}

PUBLIC_IP=$(curl -4 -s ifconfig.me || echo "你的公网IP")

# 输出客户端配置
echo -e "\n\n新的客户端配置信息："
echo "=============================================="
echo "1. Hysteria2 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜hy2"
echo "  type: hysteria2"
echo "  server: $PUBLIC_IP"
echo "  port: $HY2_PORT"
echo "  password: '$HY2_PASSWORD'"
echo "  udp: true"
echo "  sni: bing.com"
echo "  skip-cert-verify: true"

echo -e "\n2. AnyTLS 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜anytls"
echo "  server: $PUBLIC_IP"
echo "  type: anytls"
echo "  port: $ANYTLS_PORT"
echo "  password: $ANYTLS_PASSWORD"
echo "  skip-cert-verify: true"
echo "  sni: www.usavps.com"
echo "  udp: true"
echo "  tfo: true"
echo "  tls: true"
echo "  client-fingerprint: chrome"

echo -e "\n3. Shadowsocks-2022 客户端配置:"
echo -e "\n- name: $PUBLIC_IP｜Direct｜ss2022"
echo "  type: ss"
echo "  server: $PUBLIC_IP"
echo "  port: $SS2022_PORT"
echo "  cipher: 2022-blake3-aes-256-gcm"
echo "  password: $SS2022_SERVER_KEY"
echo "  udp: true"
echo "=============================================="

echo -e "\nCompact 格式配置（可直接粘贴到 Mihomo proxies 列表中）:"
echo "----------------------------------------------"
echo "- {name: \"$PUBLIC_IP｜Direct｜anytls\", type: anytls, server: $PUBLIC_IP, port: $ANYTLS_PORT, password: \"$ANYTLS_PASSWORD\", skip-cert-verify: true, sni: www.usavps.com, udp: true, tfo: true, tls: true, client-fingerprint: chrome}"
echo "- {name: \"$PUBLIC_IP｜Direct｜hy2\", type: hysteria2, server: $PUBLIC_IP, port: $HY2_PORT, password: \"$HY2_PASSWORD\", udp: true, sni: bing.com, skip-cert-verify: true}"
echo "- {name: \"$PUBLIC_IP｜Direct｜ss2022\", type: ss, server: $PUBLIC_IP, port: $SS2022_PORT, cipher: 2022-blake3-aes-256-gcm, password: \"$SS2022_SERVER_KEY\", udp: true}"
echo "----------------------------------------------"

echo "hysteria2://$HY2_PASSWORD@$PUBLIC_IP:$HY2_PORT?peer=bing.com&insecure=1#$PUBLIC_IP｜Direct｜hy2"
echo "anytls://$ANYTLS_PASSWORD@$PUBLIC_IP:$ANYTLS_PORT?peer=www.usavps.com&insecure=1&fastopen=1&udp=1#$PUBLIC_IP｜Direct｜anytls"
echo "ss://$(echo -n "2022-blake3-aes-256-gcm:$SS2022_SERVER_KEY" | base64 -w 0)@$PUBLIC_IP:$SS2022_PORT?#$PUBLIC_IP｜Direct｜ss2022"

rc-service mihomo restart

echo -e "\n服务状态:"
rc-service mihomo status
