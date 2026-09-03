// Node 22 的 `node --test <目录>` 不会自己展开目录,所以留一个入口把用例都收进来,
// 让 `node --test relay/test agent/test` 这条命令能直接跑。
import './crypto.test.mjs'
import './rpc.test.mjs'
import './mcp.test.mjs'
import './license.test.mjs'
import './e2e.test.mjs'
