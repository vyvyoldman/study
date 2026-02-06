bash <(curl -Ls https://raw.githubusercontent.com/vyvyoldman/study/main/setup.sh)

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
