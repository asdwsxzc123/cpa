# 仅保留 Claude + Codex 的瘦身计划

> 状态：**草稿**（尚未执行）。本文件为重构方案存档，供后续按需推进。

## 背景

CLIProxyAPI 当前同时支持 OpenAI/Gemini/Claude/Codex 多种生态。本计划目标是把项目大幅缩减，仅保留 Claude + Codex 两条线，移除其余所有 provider 及衍生模块，且**不保留任何向后兼容、不保留 legacy migration 逻辑**。

### 保留范围

- **Provider（后端凭证）**：
  - Claude（`--claude-login`）
  - Codex（`--codex-login`、`--codex-device-login`）
- **输入协议路由**：
  - OpenAI：`/v1/chat/completions`、`/v1/completions`、`/v1/models`
  - Anthropic：`/v1/messages`、`/v1/messages/count_tokens`
  - Codex Responses：`/v1/responses`（保留 Codex 原生协议入口）

### 删除范围

- **Provider**：Gemini（OAuth + AI Studio + Gemini CLI 风味）、Vertex AI 兼容、Antigravity、xAI、Kimi、openai-compatibility（第三方 OpenAI 兼容端点）
- **模块**：`internal/api/modules/amp/`（Sourcegraph Amp 集成）整块
- **路由**：`/v1beta/*`、`/v1internal:*`、`/v1/images/*`、`/v1/videos/*`、`/ampcode/*`、`/openai-compatibility`、`/google/callback`、`/antigravity/callback`、`/xai/callback`、`/kimi-auth-url`、`/xai-auth-url`
- 上述 provider 在 translator、config、TUI、registry、watcher、cache、tests 中的全部痕迹

预计修改文件数 ≥ 250。

---

## 删除清单（按子系统）

### A. CLI / 主入口

**`cmd/server/main.go`** — 删除以下 flag 及对应 case：

- `login`（L200）+ `cmd.DoLogin` 分支（L712–714）
- `antigravityLogin`（L206）+ `cmd.DoAntigravityLogin` 分支（L715–717）
- `vertexImport`、`vertexImportPrefix`（L211–212）+ `cmd.DoVertexImport` 分支（L709–711）
- `kimiLogin`（L184, L207）+ 对应分支（L727）
- `xaiLogin`（L185, L208）+ 对应分支（L729）
- `projectID`（L209，Gemini 专用）
- `misc.StartAntigravityVersionUpdater(...)`（L745, L823）

**`internal/cmd/` 删除：**`login.go`（Gemini）、`antigravity_login.go`、`vertex_import.go`、`kimi_login.go`、`xai_login.go`。保留 `claude_login.go`、`codex_login.go`、`codex_device_login.go`。

**`sdk/auth/interfaces.go`：**删除 `LoginOptions.ProjectID` 字段（若仅 Gemini 用）。

### B. API 路由（`internal/api/server.go`）

**删除路由：**

- `/v1beta` 路由组（L412–418）
- `/v1internal:method`（L431）
- `/v1/images/generations`、`/v1/images/edits`（L388–389）
- `/v1/videos`、`/v1/videos/generations`、`/v1/videos/edits`、`/v1/videos/extensions`、`/v1/videos/:request_id`（L390–394）
- `/v1/responses/compact`（L399；主接口 `/v1/responses` 保留）
- `/backend-api/codex/...` alias 组（L403–409）— 保留若为 Codex 后端必需路径；删除若仅作外部别名（实操确认）
- `/google/callback`（L464–476）、`/antigravity/callback`（L478–490）、`/xai/callback`（L492–504）
- 管理 API：`/v0/management/openai-compatibility`（L672–675 四个 verbs）、所有 `/v0/management/ampcode/*`（L623–645 共 23 条）、`/v0/management/kimi-auth-url`（L706）、`/v0/management/xai-auth-url`（L707）、`/v0/management/gemini-api-key`、`/v0/management/vertex-api-key`、`/v0/management/antigravity-*`

**保留路由：**

- `/v1/models`（L385）、`/v1/chat/completions`（L386）、`/v1/completions`（L387）
- `/v1/messages`（L395）、`/v1/messages/count_tokens`（L396）
- `/v1/responses` GET/POST（L397–398）
- `/anthropic/callback`、`/openai/callback`、Codex 设备码 polling 端点

删除 `geminiHandlers`、`geminiCLIHandlers`、`ampModule` 变量与构造调用（含 L30 import、L176–177、L300、L307、L1464–1472）。

### C. AMP 模块（整块删除）

- 删除整个目录 `internal/api/modules/amp/`（16 个文件）
- 删除 `test/amp_management_test.go`
- 删除 `test/usage_logging_test.go` 中 Amp 相关用例（或整个文件视耦合度）

### D. Provider Executor

**删除文件：**

- `internal/runtime/executor/gemini_executor.go` + `_test.go`
- `internal/runtime/executor/gemini_cli_executor.go`
- `internal/runtime/executor/gemini_vertex_executor.go`
- `internal/runtime/executor/aistudio_executor.go`
- `internal/runtime/executor/antigravity_executor.go` + 3 个 `antigravity_executor_*_test.go`
- `internal/runtime/executor/xai_executor.go` + `_test.go`
- `internal/runtime/executor/kimi_executor.go`
- `internal/runtime/executor/openai_compat_executor.go` + `_compact_test.go`
- `internal/runtime/executor/helps/vertex_payload_helpers.go`（确认仅被 vertex executor 引用）

**保留：**`claude_executor.go`、`codex_executor.go`、`codex_websockets_executor.go`、`empty_executor.go`、`helps/` 中通用 helper（含 `thinking_providers.go`，但需要删除其中 kimi/xai 注册项）。

**`sdk/cliproxy/service.go`：**

- `ensureExecutorsForAuthWithMode()` switch case 删除 `gemini`/`gemini-cli`/`vertex`/`aistudio`/`antigravity`/`xai`/`kimi`/`openai-compatibility`（L419–445）
- `wsOnConnected`/`wsOnDisconnected` 删除 aistudio 处理（L231–282）
- `RegisterExecutor("openai-compatibility", ...)` 删除（L595）
- 模型 provider 路由相关 mapping（L376–377, L414, L442, L1078, L1180–1215, L1573, L1162, L1159）按 provider 分支精简
- 删除 `service_xai_executor_binding_test.go`

### E. Auth 包

**删除目录/文件：**

- `internal/auth/gemini/`、`internal/auth/vertex/`、`internal/auth/antigravity/`
- `internal/auth/xai/`、`internal/auth/kimi/`
- `sdk/auth/gemini.go`、`sdk/auth/antigravity.go`、`sdk/auth/xai.go` + `_test.go`、`sdk/auth/kimi.go`

**保留：**`internal/auth/claude/`、`internal/auth/codex/`；`sdk/auth/claude.go`、`sdk/auth/codex.go`、`sdk/auth/codex_device.go`。

**`sdk/auth/manager.go`：**`newDefaultAuthManager()` 仅保留 Claude、Codex（含 device）的注册（L113–120 精简）。

**`sdk/auth/filestore.go`/`filestore_test.go`：**移除 GeminiKey/VertexCompat 等的 fixture。

### F. Translator 矩阵

**保留：**

- `internal/translator/openai/claude/` — OpenAI 输入 → Claude 后端
- `internal/translator/openai/responses/` 或 `internal/translator/openai/codex/` — OpenAI 输入 → Codex 后端（看现有目录名）
- `internal/translator/claude/codex/` — Anthropic 输入 → Codex 后端
- `internal/translator/claude/claude/`（若存在；passthrough/规范化）
- `internal/translator/codex/openai/` 或 `codex/claude/` — Codex 输入 → 后端（保留与 `/v1/responses` 入口对应的链路）
- `internal/translator/common/` — 通用工具（清理其中只服务于 gemini 的 helper）
- `internal/translator/init.go` — 仅保留上述包的 `import _`

**删除：**

- `internal/translator/gemini/`、`gemini-cli/`、`antigravity/`（整树）
- 所有 `*/gemini/`、`*/gemini-cli/` 子目录（`claude/gemini/`、`claude/gemini-cli/`、`codex/gemini/`、`codex/gemini-cli/`、`openai/gemini/`、`openai/gemini-cli/`）
- `internal/translator/openai/openai/`（如果仅是给 openai-compat 用）
- `internal/translator/claude/openai/`（claude→openai 没有保留后端可消费，确认无引用后删）
- `internal/translator/codex/gemini/`、`codex/gemini-cli/`
- `internal/translator/init.go` 对应 import 行（L4–35 大部分）
- 共享 `safety.go` 中 Gemini 安全设置

### G. Config 结构

**`internal/config/config.go`：**

- 删除字段：`GeminiKey`（L109）、`VertexCompatAPIKey`（L130）、`OpenAICompatibility`（L125–126）、`AmpCode`（L132–133）、`QuotaExceeded.AntigravityCredits`（L218–221）、`AntigravitySignatureCacheEnabled/Bypass*`（L101–106）
- 删除类型：`GeminiKey`/`GeminiModel`（L491–536）、`OpenAICompatibility`/`OpenAICompatibilityAPIKey`/`OpenAICompatibilityModel`（L538–598）、`AmpCode`/`AmpUpstreamAPIKeyEntry`/`AmpModelMapping`（L256–308）
- 删除方法：`SanitizeGeminiKeys`（L939–967）、`SanitizeOpenAICompatibility`（L885–903）、默认 Amp 初始化（L647）
- 删除 legacy migration：`LegacyGeminiKeys`、`AmpUpstreamURL/APIKey/RestrictManagement/ModelMappings` 等 `legacyConfigData` 字段（L1781–1789）、`migrateLegacyGeminiKeys`（L1795–1821）、`migrateLegacyAmpConfig`（L1899–1925）、`removeLegacyGenerativeLanguageKeys`（L1956–1961）、`removeLegacyAmpKeys`（L1946–1954）
- 更新注释（L140–143、L143 等）去除已删除 channel 的提及

**删除文件：**`internal/config/vertex_compat.go`

**`internal/config/parse.go` L77–78：**删除 `SanitizeGeminiKeys`、`SanitizeVertexCompatKeys`、`SanitizeOpenAICompatibility` 调用。

**`sdk/config/config.go`：**删除 `GeminiKey`、`VertexCompatKey`、`VertexCompatModel`、`OpenAICompatibilityAPIKey` 别名（L23、L26、L27、L29）。

### H. 管理 API

**`internal/api/handlers/management/api_tools.go`：**

- 删除 `geminicli` import（L15）
- 删除 gemini/antigravity/xai/kimi OAuth scopes 与 constants（L26–41）
- 删除 RefreshToken 中对应分支（L243、L257–281、L349–494）

**`internal/api/handlers/management/config_auth_index.go`：**删除 `geminiKeyWithAuthIndex`、`vertexCompatKeyWithAuthIndex`、`openAICompatWithAuthIndex` 等类型与生成器（L11–40、L80–101、L167–190）。

**`internal/api/handlers/management/oauth_sessions.go`：**删除 case `"gemini"/"google"`、`"antigravity"`、`"xai"`、`"kimi"` 映射（L241–242 等）。

**`internal/api/handlers/management/auth_files.go`：**移除 xai/kimi/antigravity 引用。

**`internal/api/handlers/management/config_lists.go`：**移除 openai-compat 列表分支。

**`internal/api/handlers/management/api_tools_test.go`：**同步删除测试。

### I. Registry / 模型定义

**`internal/registry/model_definitions.go`：**

- 删除 JSON 字段：`Gemini`/`GeminiCLI`/`Antigravity`/`XAI`/`Kimi`/`OpenAICompat`（L19–28 区域）
- 删除：`GetGeminiModels`、`GetGeminiVertexModels`、`GetGeminiCLIModels` 等（L38–49）、xai/kimi 等 getter
- `ModelsByProvider` 移除对应 case（L232–244）

**`internal/registry/model_updater.go`：**删除上述 provider 的 diff/publish 分支（L208–217、L329–338 及 xai/kimi 区段）。

**`internal/registry/model_registry.go`：**删除 openai-compatibility 注册分支。

### J. TUI

**`internal/tui/oauth_tab.go`：**OAuth tab 列表仅保留 Claude + Codex（device login 入口）；删除 Gemini CLI（L22）、Antigravity（L25）、xai、kimi 入口；移除对应 case 分支（L274–281 等）。

**`internal/tui/keys_tab.go`：**删除 `gemini`、`vertex`、`openaiCompat` 字段（L19–22）、`LoadKeysMsg` 填充（L77–80）、View 合并（L96–99）、渲染段落（L342–345）。

**`internal/tui/client.go`：**删除 `GetGeminiKeys`（L288–290）、`GetVertexKeys`（L305）、`GetOpenAICompatibility`、`GetKimiToken`、`GetXAIToken` 等方法。

### K. Watcher / Diff

- 删除 `internal/watcher/diff/openai_compat.go` + `_test.go`、`oauth_excluded.go`（保留若仍需，否则删）的 gemini-cli/vertex/aistudio/antigravity 项
- `internal/watcher/diff/config_diff.go`：删除 antigravity credits（L90）、gemini key diff（L106–130）、amp 相关、openai-compat 相关分支
- `internal/watcher/diff/model_hash.go`：删除 `ComputeGeminiModelsHash`（L76）等
- `internal/watcher/diff/oauth_model_alias.go` + `_test.go`：精简到只剩 claude/codex channel
- `internal/watcher/synthesizer/config.go` + `file.go` + `helpers.go` + 对应测试：删除 amp、openai-compat、gemini/vertex 段
- `internal/watcher/watcher_test.go`：删除 openai-compat 相关用例

### L. 杂项 / 辅助

- 删除 `internal/misc/antigravity_version.go`
- 删除整个目录 `cmd/fetch_antigravity_models/`
- `internal/cache/signature_cache.go`：删除 gemini grouping（L127–157、L186、L194–195）、antigravity bypass（L215、L231–233）；如果该文件主要服务于 gemini/antigravity，整体精简或删除
- `internal/constant/constant.go`：删除 `Gemini`、`GeminiCLI`（L7–11）及其他被删 provider 常量
- 删除 `internal/util/gemini_schema.go`
- `internal/util/provider.go`：精简 provider 列表
- `internal/runtime/executor/helps/thinking_providers.go`：删除 kimi/xai/gemini 等 thinking provider 注册
- 删除 `internal/thinking/provider/gemini/`、`kimi/`、`xai/`、`antigravity/`（如有）
- `internal/thinking/apply.go`：去掉 openai-compatibility 与上述 provider 分支
- `sdk/cliproxy/auth/conductor.go`、`types.go`、`openai_compat_pool_test.go`、`conductor_overrides_test.go`、`oauth_model_alias_test.go`、`antigravity_credits_test.go`：清理或删除
- `sdk/api/handlers/openai/openai_images_handlers.go` + `_test.go`：与 `/v1/images/*` 路由一并删除

### M. 示例 / 文档

- **`config.example.yaml`**：删除 L131、L150、L162–186（gemini-api-key）、L296–308（vertex-api-key）、L349–445（oauth-model-alias/oauth-excluded-models/payload-rule 中关于已删 provider 的段）；`amp:` 配置块（如有）；`openai-compatibility:` 配置块
- **`README.md`**、**`README_CN.md`**：删除 Gemini/Vertex/Antigravity/xAI/Kimi/openai-compatibility/Amp 的描述、命令示例与表格行
- **`AGENTS.md`** / **`CLAUDE.md`**：更新顶部对支持协议的描述为 "OpenAI/Claude compatible APIs with OAuth"；删除已删模块的 architecture 段落

### N. 测试清理（连同源码同步删）

`gemini_executor_test.go`、`antigravity_executor_*_test.go`、`xai_executor_test.go`、`xai_auth_test.go`、`sdk/auth/xai_test.go`、`sdk/auth/kimi*_test.go`、`amp/*_test.go`、`amp_management_test.go`、`openai_compat_pool_test.go`、`openai_compat*_test.go`、`gemini_bridge_test.go`、`gemini_schema_test.go`、`antigravity_credits_test.go`、`service_xai_executor_binding_test.go`、`service_excluded_models_test.go`（精简）、`signature_cache_test.go`（精简）、`thinking_conversion_test.go`（精简）、`oauth_model_alias_test.go`（精简）、`config_diff_test.go`（精简）、`config_test.go`（synthesizer，精简）

---

## 关键文件（实操参考索引）

| 文件 | 角色 |
|---|---|
| `cmd/server/main.go` | CLI flag + 启动分支 |
| `internal/api/server.go` | 路由注册中枢 |
| `sdk/cliproxy/service.go` | Executor 注册中枢 |
| `internal/translator/init.go` | Translator 注册中枢 |
| `internal/config/config.go` | 配置结构总览 |
| `internal/registry/model_definitions.go` | 模型注册 |
| `internal/api/handlers/management/api_tools.go` | 管理 API 残留最多 |
| `sdk/auth/manager.go` | SDK auth provider 注册 |
| `internal/tui/oauth_tab.go` + `keys_tab.go` | TUI 入口 |

---

## 执行顺序（保证每一步都可编译）

按"依赖向反方向删除"原则：

1. **路由层**（server.go、amp routes、management routes）— 切断对内部包的调用
2. **CLI flag + main 分支** — 切断 cmd 入口
3. **handlers** — 删除 gemini handlers、amp handlers、management 已删 provider 相关
4. **AMP 模块整体**
5. **Executor + 注册** — service.go switch case + 文件删除
6. **Auth 包 + SDK auth** — 文件删除
7. **`cmd/` 子目录** — login.go 等
8. **Translator** — `init.go` 先精简，再删目录
9. **Registry / Cache / Watcher / Thinking** — 删 provider 分支与文件
10. **TUI** — keys_tab、oauth_tab
11. **Config 结构** — 最后删（其他代码都不再引用了）
12. **杂项**：fetch_antigravity_models、antigravity_version、constants、util、共享 helpers
13. **测试 + 示例 + 文档** — 最后一轮扫尾

每完成一个里程碑（1–4、5–8、9–12、13）跑：

```bash
gofmt -w .
go build -o /tmp/cli-proxy-api ./cmd/server && rm /tmp/cli-proxy-api
```

若有 import-cycle 或 unused 报错，按错误信息回到对应章节定位残留。

---

## 验证

### 静态检查

```bash
gofmt -w .
go vet ./...
go build -o /tmp/cli-proxy-api ./cmd/server && rm /tmp/cli-proxy-api
go test ./...
```

### 启动验证

1. 用最小 `config.yaml`（仅 `claude-api-key` 或 `claude-oauth` + `codex-oauth`）启动 `go run ./cmd/server`
2. **应返回 200**：
   - `POST /v1/chat/completions` → Claude 后端 + Codex 后端均 OK
   - `POST /v1/messages` → Claude 后端 + Codex 后端均 OK
   - `POST /v1/responses` → Codex 后端 OK
   - `GET /v1/models` → 列出 Claude + Codex 模型
3. **应返回 404**：
   - `/v1beta/models`、`/v1internal:method`
   - `/v1/images/generations`、`/v1/videos`
   - `/ampcode/...`、`/google/callback`、`/antigravity/callback`、`/xai/callback`
   - `/v0/management/openai-compatibility`、`/v0/management/gemini-api-key` 等
4. **登录 flag**：
   - `--claude-login`、`--codex-login`、`--codex-device-login` 可用
   - `--login`、`--xai-login`、`--kimi-login`、`--antigravity-login`、`--vertex-import` 应报 "flag provided but not defined"
5. **旧 config 加载**：用包含 `gemini-api-key:`、`amp:`、`vertex-api-key:` 的旧文件启动，因字段不存在 yaml 解码会忽略或报错（视 `KnownFields`/`Strict` 设置）。两种结果都符合"无向后兼容"
6. **TUI**（`--tui`）：OAuth tab 只剩 Claude、Codex（含 device）；Keys tab 不再出现 Gemini/Vertex/OpenAI-Compat 段
7. **README/CN 双语**两端一致，无悬空链接或表格

---

## 风险与提示

1. **`helps/vertex_payload_helpers.go`、`helps/thinking_providers.go` 复用面**：删前 grep 一次，确认仅被即将删除的 executor 引用，否则改名/拆解后保留。
2. **`/backend-api/codex/*`**：是 Codex 后端必经路径还是仅外部 alias，需要在 server.go 上下文确认；保守保留，等编译时再裁。
3. **`AntigravityCredits` 调用方**：claude/codex executor 里可能有 quota 满 fallback 走 antigravity 的逻辑，要全仓搜后清理。
4. **`internal/translator/` 内 import 链复杂**：先删 `init.go` 中 `import _` 行，再删目录；目录里可能有内部相互引用，按编译错误倒推。
5. **常量删除可能误伤**：`internal/constant/constant.go` 中 `Gemini`/`GeminiCLI` 字符串可能被字典或配置 schema 反引用，全仓 grep 后再删。
6. **`OpenAICompatibility` 命名歧义**：删的是"第三方 OpenAI 兼容端点"的 provider，而 OpenAI 协议入口（`/v1/chat/completions`）保留。注意不要把 `internal/translator/openai/` 整树删掉——只删 `openai/gemini/`、`openai/gemini-cli/`、可能的 `openai/openai/`（如果该子目录只服务于已删 provider）。
7. **embed 资源**：`sdk/api/handlers/gemini/`、amp 模块、`internal/auth/{antigravity,xai,kimi}/html_templates.go` 中 embed 的模板/静态资源会随包删除一并消失，无需额外处理。
8. **首次启动若报 `unknown executor` 或 `unknown provider`**：通常是某处 string switch 漏改，按错误日志定位。
9. **不需要保留 deprecated 包**：已确认彻底清理。
