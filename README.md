bash <(curl -Ls https://raw.githubusercontent.com/vyvyoldman/study/main/setup.sh)

## Hysteria2 (hy2) 一键部署

```bash
bash <(curl -Ls https://raw.githubusercontent.com/vyvyoldman/study/main/setup-hy2.sh)
```

### hy2 环境变量

- `PORT`：Hysteria2 监听端口（默认 `443`）
- `PASSWORD`：客户端密码（默认脚本自动生成）
- `CERT_CN`：证书 CN/连接地址（默认自动获取公网 IP）

示例：


bash <(curl -Ls https://raw.githubusercontent.com/vyvyoldman/study/main/setup-hy2.sh)
```

## Node.js 脚本运行方式

```bash
npm install
npm start
```

### 环境变量

- `UUID`：VLESS UUID（默认内置示例值）
- `WS_PATH`：WebSocket 路径（默认 `/vless`）
- `ARGO_TOKEN`：Cloudflare Tunnel Token（留空 = 临时隧道）
- `ARGO_DOMAIN`：固定隧道域名（填写后生成固定节点链接）

示例（固定隧道）：

```bash
export UUID="your-uuid"
export WS_PATH="/vless"
export ARGO_TOKEN="your-tunnel-token"
export ARGO_DOMAIN="tunnel.example.com"
npm start
```

示例（临时隧道）：

```bash
export UUID="your-uuid"
npm start
```
