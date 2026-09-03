# MacHands 中继

中继只干一件事:**在 Mac 和 agent 之间转发密文**。它看不见命令,也看不见文件内容——
每一帧都是两端用 X25519 + ChaCha20-Poly1305 端到端加密的,中继没有密钥。

它记的东西只有两个 JSON 文件:

- `data/ids.json` — 每个 id 的签名公钥、名字、最后一次在线时间(id 和公钥一旦绑定就不许换)
- `data/pairs.json` — 谁和谁配过对(`{macId: [agentId, …]}`)

外加 `data/relay.key`(它自己的 Ed25519 身份,第一次启动自动生成,权限 0600)。
配对码里带着中继公钥,App 和 CLI 首次连接就把它 pin 住,对不上直接断开。

## 自建,五条命令

```bash
git clone <仓库> machands && cd machands/relay
npm install                       # 只有一个依赖:ws
cp config.example.json config.json && $EDITOR config.json   # 改端口就行
sudo sh install.sh                # 建系统用户、装到 /opt/machands、写 systemd、开机自启
curl -s http://127.0.0.1:8443/health
```

最后一条应当回一段 JSON,里面的 `relayId` 就是这台中继的公钥。
`install.sh` 可以重复跑,已经存在的用户、配置文件都不会被覆盖。

不想装成服务,直接跑也行:

```bash
node server.mjs config.json
```

## 配置

```json
{
  "host": "0.0.0.0",
  "port": 8443,
  "dataDir": "./data",
  "tls": null
}
```

- 有域名和证书就填 `"tls": {"cert": "/etc/…/fullchain.pem", "key": "/etc/…/privkey.pem"}`,端口改 443,客户端自然用 `wss`。
- 不填 TLS 也不影响保密性(内容本来就是端到端加密的),TLS 只是让链路更干净。
- 环境变量 `MACHANDS_RELAY_CONFIG` 也能指定配置文件。

## 端点

| 端点 | 谁用 |
|---|---|
| `ws://<host>:<port>/v1/mac` | MacHands.app |
| `ws://<host>:<port>/v1/agent` | machands CLI |
| `GET /health` | 监控:在线数、已知 id 数、配对数、relayId |
| `GET /install` | agent 侧的安装脚本(v1 是占位版,只打印步骤) |

## 规矩(SPEC §4)

- 握手:中继先发 `hello`(带 32 字节随机 nonce 和自己的签名),客户端签 `{id, nonce, ts}` 回 `auth`,验过给 `ok`。
  同一个 id 换了签名公钥 → `BAD_SIG`;时间戳偏差超过 5 分钟 → `BAD_SIG`。
- 配对:Mac 发 `pair.open` 登记 token(TTL 最多 600 秒,只能用一次);agent 发 `pair.claim`;
  中继转 `pair.request` 给 Mac,Mac 回 `pair.decide`,中继把 `pair.result` 给 agent。
  过期 `EXPIRED`、用过 `USED`、拒绝 `DENIED`、Mac 不在线 `OFFLINE`。
- 转发:只在双方已配对时转发 `send` → `recv`;否则 `NOT_PAIRED`;对端不在线 `OFFLINE`。
- 在线状态:配对双方上下线互相收到 `presence`。
- 心跳:每 25 秒 `ping`,60 秒收不到 `pong` 断开。
- 限制:单帧 ≤ 1 MiB;每连接 10 MB/s 软限,超了回 `{t:"err", code:"RATE"}`。

## 运维

```bash
systemctl status machands-relay
journalctl -u machands-relay -f
```

数据都在 `/opt/machands/relay/data`。备份这三个文件就等于备份了全部状态。
`relay.key` 换掉等于换了身份,所有已配对的 App 和 CLI 都会因为 pin 不上而拒连——不要随手删。

## 测试

```bash
cd .. && node --test relay/test agent/test
```

---

## English

The relay forwards ciphertext between a Mac and an agent and nothing else. All state is two
JSON files (`data/ids.json`, `data/pairs.json`) plus its own Ed25519 key (`data/relay.key`,
generated on first start, mode 0600). Self-host in five commands:

```bash
git clone <repo> machands && cd machands/relay
npm install
cp config.example.json config.json && $EDITOR config.json
sudo sh install.sh
curl -s http://127.0.0.1:8443/health
```

Endpoints: `/v1/mac`, `/v1/agent` (WebSocket), `GET /health`, `GET /install`.
Set `tls` in the config to serve `wss` on 443. `install.sh` is idempotent.
