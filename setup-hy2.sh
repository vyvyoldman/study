#!/bin/bash

# ==================================================
# Hysteria2 (hy2) 一键部署脚本
# GitHub: vyvyoldman/study
# Feature: 自动安装 sing-box + 生成自签证书 + systemd 守护
# ==================================================

set -euo pipefail

WORK_DIR="/etc/sing-box-hy2"
SB_PATH="/usr/local/bin/sing-box"
CONFIG_PATH="$WORK_DIR/config.json"
CERT_PATH="$WORK_DIR/cert.pem"
KEY_PATH="$WORK_DIR/key.pem"
SERVICE_PATH="/etc/systemd/system/sing-box-hy2.service"

PORT="1234"
PASSWORD="${PASSWORD:-}"
CERT_CN="${CERT_CN:-}"

if [ -z "$PASSWORD" ]; then
    PASSWORD="$(openssl rand -hex 16)"
fi

if [ -z "$CERT_CN" ]; then
    CERT_CN="$(curl -fsSL https://api.ipify.org || hostname -I | awk '{print $1}')"
fi

install_deps() {
    if command -v apt-get &>/dev/null; then
        apt-get update -y
        apt-get install -y curl tar openssl
    elif command -v yum &>/dev/null; then
        yum install -y curl tar openssl
    fi
}

download_sing_box() {
    if [ -x "$SB_PATH" ]; then
        return
    fi

    arch=$(uname -m)
    if [ "$arch" = "x86_64" ]; then
        sb_url="https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-amd64.tar.gz"
    elif [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
        sb_url="https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-arm64.tar.gz"
    else
        echo "Unsupported architecture: $arch"
        exit 1
    fi

    tmp_dir=$(mktemp -d)
    curl -L "$sb_url" | tar -xz -C "$tmp_dir" --strip-components=1
    install -m 755 "$tmp_dir/sing-box" "$SB_PATH"
    rm -rf "$tmp_dir"
}

generate_cert() {
    if [ -f "$CERT_PATH" ] && [ -f "$KEY_PATH" ]; then
        return
    fi

    mkdir -p "$WORK_DIR"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=${CERT_CN}"
}

generate_config() {
    mkdir -p "$WORK_DIR"
    cat > "$CONFIG_PATH" <<'CONFIG'
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [
        {
          "password": "${PASSWORD}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${CERT_PATH}",
        "key_path": "${KEY_PATH}"
      },
      "masquerade": {
        "type": "proxy",
        "proxy": {
          "url": "https://www.cloudflare.com",
          "rewrite_host": true
        }
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
CONFIG

    sed -i \
        -e "s|${PORT}|$PORT|g" \
        -e "s|${PASSWORD}|$PASSWORD|g" \
        -e "s|${CERT_PATH}|$CERT_PATH|g" \
        -e "s|${KEY_PATH}|$KEY_PATH|g" \
        "$CONFIG_PATH"
}

create_service() {
    cat > "$SERVICE_PATH" <<'SERVICE'
[Unit]
Description=Sing-box Hysteria2 Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box-hy2/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable sing-box-hy2
    systemctl restart sing-box-hy2
}

install_deps

download_sing_box

generate_cert

generate_config

create_service

echo "======================================"
echo "Hysteria2 部署完成！"
echo "端口: ${PORT}"
echo "密码: ${PASSWORD}"
echo "证书 CN: ${CERT_CN}"
echo ""
echo "连接链接 (自签证书, insecure=1):"
echo "hysteria2://${PASSWORD}@${CERT_CN}:${PORT}?insecure=1&sni=${CERT_CN}#HY2"
echo "======================================"
