#!/usr/bin/env bash
set -e

echo "🚀 开始卸载 Mihomo（Hysteria2 + AnyTLS + Shadowsocks-2022）"

# 停止服务
if rc-service mihomo status &>/dev/null; then
    echo "⏹️  停止 mihomo 服务..."
    rc-service mihomo stop
else
    echo "ℹ️  mihomo 服务未在运行，跳过停止步骤"
fi

# 删除开机自启
if rc-update show default | grep -q mihomo; then
    echo "🔕 移除开机自启..."
    rc-update del mihomo default
else
    echo "ℹ️  开机自启已不存在，跳过"
fi

# 删除服务脚本
if [ -f /etc/init.d/mihomo ]; then
    echo "🗑️  删除服务脚本 /etc/init.d/mihomo"
    rm -f /etc/init.d/mihomo
else
    echo "ℹ️  服务脚本已不存在，跳过"
fi

# 删除 Mihomo 二进制
if command -v mihomo &>/dev/null || [ -f /usr/local/bin/mihomo ]; then
    echo "🗑️  删除 mihomo 二进制 /usr/local/bin/mihomo"
    rm -f /usr/local/bin/mihomo
else
    echo "ℹ️  mihomo 二进制已不存在，跳过"
fi

# 删除配置文件目录（谨慎操作，确认用户意图）
echo ""
echo "⚠️  即将删除用户配置文件目录：/etc/mihomo/"
echo "    该目录包含 config.yaml、证书（server.crt/server.key）等文件"
read -p "是否确认删除？（输入 y 或 Y 确认，其余取消）: " confirm

if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
    if [ -d "/etc/mihomo" ]; then
        echo "🗑️  删除配置文件目录 /etc/mihomo"
        rm -rf "/etc/mihomo"
    else
        echo "ℹ️  配置文件目录已不存在，跳过"
    fi
else
    echo "ℹ️  用户取消，保留配置文件目录（可手动删除）"
fi

# 清理可能的 pid 文件
if [ -f /run/mihomo.pid ]; then
    echo "🗑️  删除残留 pid 文件"
    rm -f /run/mihomo.pid
fi

echo ""
echo "✅ Mihomo 卸载完成！"
echo "    如需彻底清理，可手动检查以下路径："
echo "    - /usr/local/bin/mihomo"
echo "    - /etc/init.d/mihomo"
echo "    - /etc/mihomo"
echo "    - /run/mihomo.pid"
