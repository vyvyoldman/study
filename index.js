/**
 * Node.js VLESS + WS + TLS + Cloudflare Tunnel 穿透脚本
 * * 功能：
 * 1. 自动下载 sing-box 和 cloudflared
 * 2. 动态生成 sing-box 配置文件 (VLESS+WS)
 * 3. 启动 Cloudflare Tunnel (支持临时/固定隧道)
 * 4. 输出 VLESS 订阅链接
 */

const express = require("express");
const { spawn, execSync } = require("child_process");
const axios = require("axios");
const fs = require("fs");
const path = require("path");
const os = require("os");
const app = express();

// ================= 配置区域 =================
// web服务端口
const PORT = process.env.PORT || 3000;
// 代理服务的 UUID (默认随机生成，建议固定)
const UUID = process.env.UUID || '9afd1229-b893-40c1-84dd-51e7ce204913';
// WebSocket 路径
const WS_PATH = process.env.WS_PATH || '/vless-ws';
// Cloudflare Tunnel Token (固定隧道必填，留空则使用临时隧道)
const ARGO_TOKEN = process.env.ARGO_TOKEN || ''; 
// 节点名称
const NODE_NAME = process.env.NODE_NAME || 'NodeJS-Tunnel';

// ================= 运行时常量 =================
const WORK_DIR = path.join(__dirname, 'bin_cache');
const SB_PATH = path.join(WORK_DIR, 'sing-box');
const CF_PATH = path.join(WORK_DIR, 'cloudflared');
const CONFIG_PATH = path.join(WORK_DIR, 'config.json');
const LOCAL_PORT = 10000 + Math.floor(Math.random() * 5000); // sing-box 监听的本地端口

// 确保工作目录存在
if (!fs.existsSync(WORK_DIR)) fs.mkdirSync(WORK_DIR, { recursive: true });

// ================= 核心逻辑 =================

// 1. 获取系统架构并下载对应二进制文件
async function checkAndDownloadBinaries() {
    const arch = os.arch();
    let sbUrl = "";
    let cfUrl = "";

    console.log(`[Init] Detected architecture: ${arch}`);

    if (arch === 'x64') {
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-amd64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64";
    } else if (arch === 'arm64') {
        sbUrl = "https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-arm64.tar.gz";
        cfUrl = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64";
    } else {
        throw new Error(`Unsupported architecture: ${arch}`);
    }

    // 下载 sing-box
    if (!fs.existsSync(SB_PATH)) {
        console.log(`[Download] Downloading sing-box from ${sbUrl}...`);
        try {
            // 使用 curl 下载并解压，比 nodejs stream 更稳定
            execSync(`curl -L "${sbUrl}" | tar -xz -C "${WORK_DIR}" --strip-components=1`);
            // 重命名(因为解压出来可能是文件夹里的文件，这里简化处理，假设 strip-components=1 后在根目录或者通配符匹配)
            // 重新查找解压出的 sing-box 文件
            const files = fs.readdirSync(WORK_DIR);
            const sbFile = files.find(f => f.includes('sing-box') && !f.endsWith('.tar.gz'));
            if(sbFile && sbFile !== 'sing-box') {
                 execSync(`mv "${path.join(WORK_DIR, sbFile)}" "${SB_PATH}"`);
            }
        } catch (e) {
            console.error("[Error] Failed to download sing-box:", e.message);
        }
    }

    // 下载 cloudflared
    if (!fs.existsSync(CF_PATH)) {
        console.log(`[Download] Downloading cloudflared from ${cfUrl}...`);
        execSync(`curl -L -o "${CF_PATH}" "${cfUrl}"`);
    }

    // 赋予执行权限
    if (fs.existsSync(SB_PATH)) fs.chmodSync(SB_PATH, 0o755);
    if (fs.existsSync(CF_PATH)) fs.chmodSync(CF_PATH, 0o755);
    
    console.log("[Init] Binaries ready.");
}

// 2. 生成 sing-box 配置文件
function generateConfig() {
    const config = {
        "log": {
            "level": "info",
            "timestamp": true
        },
        "inbounds": [
            {
                "type": "vless",
                "tag": "vless-in",
                "listen": "127.0.0.1",
                "listen_port": LOCAL_PORT,
                "users": [
                    {
                        "uuid": UUID,
                        "flow": "" 
                    }
                ],
                "transport": {
                    "type": "ws",
                    "path": WS_PATH,
                    "early_data_header_name": "Sec-WebSocket-Protocol"
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
    };

    fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
    console.log(`[Config] Generated config at port ${LOCAL_PORT}, WS path: ${WS_PATH}`);
}

// 3. 启动 sing-box
function startSingBox() {
    console.log("[Process] Starting sing-box...");
    const sb = spawn(SB_PATH, ['run', '-c', CONFIG_PATH]);

    sb.stdout.on('data', (data) => console.log(`[SingBox] ${data.toString().trim()}`));
    sb.stderr.on('data', (data) => console.error(`[SingBox Error] ${data.toString().trim()}`));
    
    sb.on('close', (code) => {
        console.log(`[SingBox] Exited with code ${code}, restarting...`);
        setTimeout(startSingBox, 3000);
    });
}

// 4. 启动 Cloudflare Tunnel
function startArgo() {
    console.log("[Process] Starting Cloudflare Tunnel...");
    let args = [];

    if (ARGO_TOKEN) {
        // 固定隧道模式
        console.log("[Mode] Using Fixed Tunnel (Token provided)");
        args = ['tunnel', 'run', '--token', ARGO_TOKEN];
        
        // 固定隧道无法直接获取域名，通常由用户自己知道
        console.log(`[Info] Fixed Tunnel started. Please assume your configured domain points to this tunnel.`);
        const vlessLink = `vless://${UUID}@<YOUR_CUSTOM_DOMAIN>:443?encryption=none&security=tls&type=ws&host=<YOUR_CUSTOM_DOMAIN>&path=${encodeURIComponent(WS_PATH)}#${encodeURIComponent(NODE_NAME)}`;
        console.log(`\n=== VLESS Link (Replace domain) ===\n${vlessLink}\n`);
        
    } else {
        // 临时隧道模式 (Quick Tunnel)
        console.log("[Mode] Using Temporary Tunnel (TryCloudflare)");
        args = ['tunnel', '--url', `http://localhost:${LOCAL_PORT}`, '--no-autoupdate', '--protocol', 'http2'];
    }

    const argo = spawn(CF_PATH, args);
    
    // 捕获输出以获取临时域名
    argo.stderr.on('data', (data) => {
        const log = data.toString();
        // console.log(`[Argo] ${log.trim()}`); // 调试时可开启
        
        // 提取 trycloudflare.com 域名
        const regex = /https:\/\/([a-zA-Z0-9-]+\.trycloudflare\.com)/;
        const match = log.match(regex);
        if (match && !ARGO_TOKEN) {
            const domain = match[1];
            console.log(`\n[Success] Tunnel Domain: ${domain}`);
            
            // 生成 VLESS 链接
            const vlessLink = `vless://${UUID}@${domain}:443?encryption=none&security=tls&type=ws&host=${domain}&path=${encodeURIComponent(WS_PATH)}#${encodeURIComponent(NODE_NAME)}`;
            
            console.log(`\n=== 🚀 VLESS Subscription Link ===\n`);
            console.log(vlessLink);
            console.log(`\n==================================\n`);
            
            // 写入文件供 Web 访问
            fs.writeFileSync(path.join(WORK_DIR, 'url.txt'), vlessLink);
        }
    });

    argo.on('close', (code) => {
        console.log(`[Argo] Exited with code ${code}, restarting...`);
        setTimeout(startArgo, 5000);
    });
}

// ================= Web 服务 =================
// 简单的 Web 界面，用于保活或查看状态
app.get("/", (req, res) => {
    let link = "Waiting for tunnel...";
    if (fs.existsSync(path.join(WORK_DIR, 'url.txt'))) {
        link = fs.readFileSync(path.join(WORK_DIR, 'url.txt'), 'utf-8');
    } else if (ARGO_TOKEN) {
        link = "Fixed Tunnel Active. Please check your Cloudflare Dashboard for status.";
    }
    
    res.send(`
        <html>
        <head><title>NodeJS Tunnel</title></head>
        <body>
            <h1>Run Status: Active</h1>
            <p>UUID: ${UUID}</p>
            <p>Protocol: VLESS + WS + TLS</p>
            <hr/>
            <h3>VLESS Link:</h3>
            <textarea style="width:100%; height:100px;">${link}</textarea>
        </body>
        </html>
    `);
});

app.get("/sub", (req, res) => {
    if (fs.existsSync(path.join(WORK_DIR, 'url.txt'))) {
        const link = fs.readFileSync(path.join(WORK_DIR, 'url.txt'), 'utf-8');
        res.send(Buffer.from(link).toString('base64')); // Base64 订阅格式
    } else {
        res.status(404).send("Sub not ready");
    }
});

// ================= 启动流程 =================
(async () => {
    try {
        await checkAndDownloadBinaries();
        generateConfig();
        startSingBox();
        startArgo();
        
        app.listen(PORT, () => {
            console.log(`[Web] Server running on port ${PORT}`);
        });
    } catch (err) {
        console.error("[Fatal Error]", err);
        process.exit(1);
    }
})();
