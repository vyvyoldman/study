const express = require("express");
const { spawn, execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const app = express();

// ================= 环境变量配置 =================
// 核心参数
const PORT = process.env.PORT || 3000;
const UUID = process.env.UUID || '9afd1229-b893-40c1-84dd-51e7ce204913'; // 请修改为您的 UUID
const WS_PATH = process.env.WS_PATH || '/vless';
// 隧道参数
const ARGO_TOKEN = process.env.ARGO_TOKEN || ""; // 填入 Token 即启用固定隧道，留空则为临时隧道
const ARGO_DOMAIN = process.env.ARGO_DOMAIN || ""; // 固定隧道绑定的域名 (填入后生成固定节点链接)

// ================= 运行时配置 =================
const WORK_DIR = path.join(__dirname, 'bin');
const SB_PATH = path.join(WORK_DIR, 'sing-box');
const CF_PATH = path.join(WORK_DIR, 'cloudflared');
const CONFIG_PATH = path.join(WORK_DIR, 'config.json');
const LOCAL_PORT = 10000 + Math.floor(Math.random() * 5000); // 随机本地端口

// 确保运行目录存在
if (!fs.existsSync(WORK_DIR)) fs.mkdirSync(WORK_DIR, { recursive: true });

// ================= 核心工具函数 =================

/**
 * 1. 下载依赖
 * 自动识别 AMD64/ARM64 架构并从官方 GitHub 下载
 */
async function downloadBinaries() {
    const arch = os.arch();
    let sbUrl = "", cfUrl = "";

    console.log(`[System] Detected architecture: ${arch}`);

    if (arch === 'x64') {
        // 引用 sing-box.sh 中的版本逻辑
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-amd64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";
    } else if (arch === 'arm64') {
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-arm64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";
    } else {
        console.error("[Error] Unsupported architecture");
        process.exit(1);
    }

    // 下载 Sing-box
    if (!fs.existsSync(SB_PATH)) {
        console.log(`[Download] Sing-box from: ${sbUrl}`);
        // 使用 curl 管道解压，避免产生临时文件
        execSync(`curl -L "${sbUrl}" | tar -xz -C "${WORK_DIR}" --strip-components=1`);
        // 清理可能解压出的多余文件，确保 sing-box 二进制在正确位置
        const files = fs.readdirSync(WORK_DIR);
        files.forEach(file => {
             if(file.includes('sing-box') && !file.endsWith('.tar.gz') && fs.statSync(path.join(WORK_DIR, file)).isFile()) {
                 if (path.join(WORK_DIR, file) !== SB_PATH) {
                    fs.renameSync(path.join(WORK_DIR, file), SB_PATH);
                 }
             }
        });
    }

    // 下载 Cloudflared
    if (!fs.existsSync(CF_PATH)) {
        console.log(`[Download] Cloudflared from: ${cfUrl}`);
        execSync(`curl -L -o "${CF_PATH}" "${cfUrl}"`);
    }

    // 授权
    if (fs.existsSync(SB_PATH)) fs.chmodSync(SB_PATH, 0o755);
    if (fs.existsSync(CF_PATH)) fs.chmodSync(CF_PATH, 0o755);
}

/**
 * 2. 生成 Sing-box 配置文件
 * 仅监听本地回环地址，通过 WebSocket 接收流量
 */
function generateConfig() {
    const config = {
        "log": { "level": "info", "timestamp": true },
        "inbounds": [
            {
                "type": "vless",
                "tag": "vless-in",
                "listen": "127.0.0.1",
                "listen_port": LOCAL_PORT,
                "users": [{ "uuid": UUID, "flow": "" }],
                "transport": {
                    "type": "ws",
                    "path": WS_PATH
                }
            }
        ],
        "outbounds": [
            { "type": "direct", "tag": "direct" },
            { "type": "block", "tag": "block" }
        ]
    };
    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}

/**
 * 3. 启动后台进程
 * 使用 spawn 替代 exec 以便实时处理日志
 */
let sharedUrl = ""; // 用于存储生成的节点链接

async function startServices() {
    await downloadBinaries();
    generateConfig();

    // --- 启动 Sing-box ---
    console.log("[Service] Starting sing-box...");
    const sb = spawn(SB_PATH, ['run', '-c', CONFIG_PATH]);
    sb.stderr.on('data', d => console.log(`[SB] ${d.toString().trim()}`));

    // --- 启动 Cloudflare Tunnel ---
    console.log("[Service] Starting Cloudflare Tunnel...");
    let cfArgs = [];
    
    if (ARGO_TOKEN) {
        // [固定隧道模式]
        console.log("[Mode] Fixed Tunnel (Token Detected)");
        cfArgs = ['tunnel', 'run', '--token', ARGO_TOKEN];
        
        // 固定隧道直接生成链接
        if (ARGO_DOMAIN) {
            const domain = ARGO_DOMAIN;
            sharedUrl = `vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&path=${encodeURIComponent(WS_PATH)}#Fixed-Tunnel`;
            console.log(`\n>>> 固定节点链接:\n${sharedUrl}\n`);
        } else {
            console.log("[Warn] ARGO_TOKEN 已设置，但 ARGO_DOMAIN 为空。请设置域名以生成固定节点链接。");
        }
    } else {
        // [临时隧道模式]
        console.log("[Mode] Temporary Tunnel (Quick Tunnel)");
        cfArgs = ['tunnel', '--url', `http://localhost:${LOCAL_PORT}`, '--no-autoupdate', '--protocol', 'http2'];
    }

    const cf = spawn(CF_PATH, cfArgs);

    // 监听输出获取临时域名 (TryCloudflare)
    cf.stderr.on('data', (data) => {
        const log = data.toString();
        // 匹配 *.trycloudflare.com
        const match = log.match(/https:\/\/([a-zA-Z0-9-]+\.trycloudflare\.com)/);
        if (match && !ARGO_TOKEN) {
            const domain = match[1];
            console.log(`[Success] Domain allocated: ${domain}`);
            sharedUrl = `vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&sni=${domain}&path=${encodeURIComponent(WS_PATH)}#Temp-Tunnel`;
            console.log(`\n>>> 临时节点链接:\n${sharedUrl}\n`);
        }
    });
}

// ================= Web 服务 (保活与订阅) =================
app.get("/", (req, res) => {
    res.send(`
    <html>
    <head><title>NodeJS VLESS Tunnel</title></head>
    <body>
        <h1>Running</h1>
        <p>Status: <span style="color:green">Active</span></p>
        <p>UUID: ${UUID}</p>
        <textarea style="width:100%; height:150px;">${sharedUrl || "Initializing..."}</textarea>
    </body>
    </html>`);
});

app.get("/sub", (req, res) => {
    if (sharedUrl) {
        res.send(Buffer.from(sharedUrl).toString('base64'));
    } else {
        res.status(503).send("Initializing...");
    }
});

// 启动
app.listen(PORT, async () => {
    console.log(`[Web] Listening on port ${PORT}`);
    await startServices();
});
