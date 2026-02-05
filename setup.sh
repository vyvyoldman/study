#!/bin/bash

# ==================================================
# Node.js Tunnel 一键部署脚本
# GitHub: vyvyoldman/study
# Feature: 自动生成节点 + 'sub' 指令 + CF优选IP支持
# ==================================================

# 定义路径
PROJECT_DIR="$HOME/node_tunnel"

# 1. 环境检查与安装 (Node.js 20 LTS)
echo "Checking Node.js..."
if ! command -v node &> /dev/null; then
    echo "Installing Node.js 20 LTS..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y nodejs || sudo yum install -y nodejs
fi

if ! command -v pm2 &> /dev/null; then
    npm install -g pm2
fi

# 2. 设置工作目录
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

# 4. 生成核心代码 app.js (集成优选IP逻辑)
cat > app.js << 'EOF'
const express = require("express");
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");
const app = express();

// --- 配置 ---
const PORT = process.env.PORT || 3000;
const UUID = process.env.UUID || '9afd1229-b893-40c1-84dd-51e7ce204913'; 
const WS_PATH = process.env.WS_PATH || '/vless';
const ARGO_TOKEN = process.env.ARGO_TOKEN || ''; 
// 这里设置您的优选 IP
const CF_IP = process.env.CF_IP || '104.16.153.250'; 

const WORK_DIR = path.join(__dirname, 'bin');
const SB_PATH = path.join(WORK_DIR, 'sing-box');
const CF_PATH = path.join(WORK_DIR, 'cloudflared');
const CONFIG_PATH = path.join(WORK_DIR, 'config.json');
const URL_FILE = path.join(__dirname, 'url.txt');
const LOCAL_PORT = 10000 + Math.floor(Math.random() * 5000);

// --- 初始化 ---
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
    
    let cfArgs = ARGO_TOKEN ? ['tunnel', 'run', '--token', ARGO_TOKEN] : ['tunnel', '--url', `http://localhost:${LOCAL_PORT}`, '--no-autoupdate', '--protocol', 'http2'];
    const cf = spawn(CF_PATH, cfArgs);
    
    if (ARGO_TOKEN) { 
        // 固定隧道情况 (需用户手动替换域名)
        sharedUrl = `vless://${UUID}@${CF_IP}:443?encryption=none&security=tls&type=ws&host=<YOUR_DOMAIN>&sni=<YOUR_DOMAIN>&path=${encodeURIComponent(WS_PATH)}#Fixed-CF-IP`;
        fs.writeFileSync(URL_FILE, sharedUrl);
    } else {
        cf.stderr.on('data', (data) => { 
            const match = data.toString().match(/https:\/\/([a-zA-Z0-9-]+\.trycloudflare\.com)/); 
            if (match) { 
                const domain = match[1];
                // === 关键修改 ===
                // 地址填 CF_IP，host 和 sni 填隧道域名
                sharedUrl = `vless://${UUID}@${CF_IP}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&path=${encodeURIComponent(WS_PATH)}#Node-CF-BestIP`;
                
                console.log(`\n>>> SUCCESS: ${sharedUrl}\n`); 
                fs.writeFileSync(URL_FILE, sharedUrl); 
            }
        });
    }
}

app.get("/", (req, res) => res.send(sharedUrl || "Initializing..."));
app.get("/sub", (req, res) => res.send(Buffer.from(sharedUrl).toString('base64')));
app.listen(PORT, async () => { console.log(`App running on ${PORT}`); await startServices(); });
EOF

# 5. 安装依赖并启动
echo "Installing dependencies..."
npm install
pm2 stop node_tunnel &> /dev/null
pm2 delete node_tunnel &> /dev/null
pm2 start app.js --name node_tunnel

# 6. 创建 'sub' 指令
echo "Creating 'sub' command..."
sudo cat > /usr/local/bin/sub <<EOF
#!/bin/bash
URL_FILE="$PROJECT_DIR/url.txt"
echo "========================================"
echo -e "\033[32m正在查询节点链接 (优选IP版)...\033[0m"
if [ -f "\$URL_FILE" ]; then
    LINK=\$(cat "\$URL_FILE")
    echo ""
    echo -e "\033[33mVLESS 链接:\033[0m"
    echo "\$LINK"
    echo ""
    echo "========================================"
else
    echo -e "\033[31m节点尚未准备好，请稍等 10-20 秒。\033[0m"
    pm2 logs node_tunnel --lines 5 --nostream
fi
EOF
sudo chmod +x /usr/local/bin/sub

echo "======================================"
echo " 部署完成！"
echo " 当前优选IP: 104.16.153.250"
echo " 输入 [ sub ] 查看节点"
echo "======================================"
