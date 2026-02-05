#!/bin/bash

# ==================================================
# Node.js Tunnel 一键部署脚本
# GitHub: vyvyoldman/study
# ==================================================

# 1. 环境检查与安装
echo "Checking Node.js..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs || sudo yum install -y nodejs
fi

if ! command -v pm2 &> /dev/null; then
    npm install -g pm2
fi

# 2. 设置工作目录 (使用用户主目录，避免权限问题)
PROJECT_DIR="$HOME/node_tunnel"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# 3. 生成 package.json
cat > package.json <<EOF
{
  "name": "node-vless-tunnel",
  "version": "1.0.0",
  "main": "app.js",
  "dependencies": {
    "axios": "^1.7.0",
    "express": "^4.19.0"
  }
}
EOF

# 4. 生成核心代码 app.js
cat > app.js << 'EOF'
const express = require("express");
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");
const app = express();
const PORT = process.env.PORT || 3000;
const UUID = process.env.UUID || '9afd1229-b893-40c1-84dd-51e7ce204913'; 
const WS_PATH = process.env.WS_PATH || '/vless';
const ARGO_TOKEN = process.env.ARGO_TOKEN || ''; 
const WORK_DIR = path.join(__dirname, 'bin');
const SB_PATH = path.join(WORK_DIR, 'sing-box');
const CF_PATH = path.join(WORK_DIR, 'cloudflared');
const CONFIG_PATH = path.join(WORK_DIR, 'config.json');
const LOCAL_PORT = 10000 + Math.floor(Math.random() * 5000);
if (!fs.existsSync(WORK_DIR)) fs.mkdirSync(WORK_DIR, { recursive: true });
async function downloadBinaries() {
    const arch = os.arch();
    let sbUrl = "", cfUrl = "";
    if (arch === 'x64') {
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-amd64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";
    } else if (arch === 'arm64') {
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-arm64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";
    } else {
        console.error("Unsupported architecture"); process.exit(1);
    }
    if (!fs.existsSync(SB_PATH)) {
        execSync(`curl -L "${sbUrl}" | tar -xz -C "${WORK_DIR}" --strip-components=1`);
        const files = fs.readdirSync(WORK_DIR);
        files.forEach(file => { if(file.includes('sing-box') && !file.endsWith('.tar.gz') && fs.statSync(path.join(WORK_DIR, file)).isFile()) { if (path.join(WORK_DIR, file) !== SB_PATH) fs.renameSync(path.join(WORK_DIR, file), SB_PATH); }});
    }
    if (!fs.existsSync(CF_PATH)) execSync(`curl -L -o "${CF_PATH}" "${cfUrl}"`);
    if (fs.existsSync(SB_PATH)) fs.chmodSync(SB_PATH, 0o755);
    if (fs.existsSync(CF_PATH)) fs.chmodSync(CF_PATH, 0o755);
}
function generateConfig() {
    const config = { "log": { "level": "error", "timestamp": true }, "inbounds": [{ "type": "vless", "tag": "vless-in", "listen": "127.0.0.1", "listen_port": LOCAL_PORT, "users": [{ "uuid": UUID, "flow": "" }], "transport": { "type": "ws", "path": WS_PATH } }], "outbounds": [{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }] };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}
let sharedUrl = "";
async function startServices() {
    await downloadBinaries(); generateConfig();
    const sb = spawn(SB_PATH, ['run', '-c', CONFIG_PATH]);
    sb.stderr.on('data', d => console.log(`[SB] ${d.toString().trim()}`));
    let cfArgs = ARGO_TOKEN ? ['tunnel', 'run', '--token', ARGO_TOKEN] : ['tunnel', '--url', `http://localhost:${LOCAL_PORT}`, '--no-autoupdate', '--protocol', 'http2'];
    const cf = spawn(CF_PATH, cfArgs);
    if (ARGO_TOKEN) { sharedUrl = "Fixed Tunnel Active."; } else {
        cf.stderr.on('data', (data) => { const match = data.toString().match(/https:\/\/([a-zA-Z0-9-]+\.trycloudflare\.com)/); if (match) { sharedUrl = `vless://${UUID}@${match[1]}:443?encryption=none&security=tls&type=ws&host=${match[1]}&path=${encodeURIComponent(WS_PATH)}#Node-Tunnel`; console.log(`\n>>> SUCCESS: ${sharedUrl}\n`); fs.writeFileSync(path.join(__dirname, 'url.txt'), sharedUrl); }});
    }
}
app.get("/", (req, res) => res.send(sharedUrl || "Initializing..."));
app.get("/sub", (req, res) => res.send(Buffer.from(sharedUrl).toString('base64')));
app.listen(PORT, async () => { console.log(`App running on ${PORT}`); await startServices(); });
EOF

# 5. 安装与运行
echo "Installing dependencies..."
npm install
pm2 stop node_tunnel &> /dev/null
pm2 delete node_tunnel &> /dev/null
pm2 start app.js --name node_tunnel

echo "======================================"
echo " 部署成功！"
echo " 节点链接将在几秒后生成，请运行以下命令查看日志："
echo " pm2 logs node_tunnel"
echo "======================================"
