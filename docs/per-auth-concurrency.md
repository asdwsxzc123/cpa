# Per-Auth Concurrency Limiting

## Background

When multiple upstream accounts are configured, there is currently no way to limit the number of concurrent requests per account. This document describes the design for adding a `max-concurrent` field to each API key entry in `config.yaml`.

## Behavior

- When an account reaches its concurrency limit, the incoming request **skips** that account and selects the next available one (non-blocking, round-robin fallback).
- If all accounts are at capacity, the request fails with an error (same as the existing "no available auth" path).
- Default value `0` means unlimited (no change from current behavior).

## Configuration

Add `max-concurrent` to any API key entry:

```yaml
claude-api-key:
  - api-key: "sk-ant-..."
    max-concurrent: 5   # 0 = unlimited (default)

gemini-api-key:
  - api-key: "AIzaSy..."
    max-concurrent: 3

codex-api-key:
  - api-key: "sk-..."
    max-concurrent: 10

openai-compatibility:
  - name: "openrouter"
    max-concurrent: 20        # provider-level default
    api-key-entries:
      - api-key: "sk-or-..."
        max-concurrent: 5     # per-key override (takes precedence)

vertex-api-key:
  - api-key: "vk-..."
    max-concurrent: 8
```

OAuth file-based auth also supports this via the auth JSON metadata field `max_concurrent`.

---

## Implementation Plan

### 1. Config structs — `internal/config/config.go`

Add `MaxConcurrent int` to each per-auth entry struct:

| Struct | File | Approximate line |
|---|---|---|
| `ClaudeKey` | `internal/config/config.go` | ~414 |
| `CodexKey` | `internal/config/config.go` | ~473 |
| `GeminiKey` | `internal/config/config.go` | ~520 |
| `OpenAICompatibility` | `internal/config/config.go` | ~567 |
| `OpenAICompatibilityAPIKey` | `internal/config/config.go` | ~576 |
| `VertexCompatKey` | `internal/config/vertex_compat.go` | ~39 |

```go
MaxConcurrent int `yaml:"max-concurrent,omitempty" json:"max-concurrent,omitempty"`
```

---

### 2. Synthesizers — write `max_concurrent` into `Auth.Attributes`

Follow the existing pattern used for `priority` (~line 68 in `config.go`).

**`internal/watcher/synthesizer/config.go`** — in each `synthesize*Keys()`:

```go
if entry.MaxConcurrent > 0 {
    attrs["max_concurrent"] = strconv.Itoa(entry.MaxConcurrent)
}
```

Functions to update:

| Function | Approximate line |
|---|---|
| `synthesizeGeminiKeys()` | ~70 |
| `synthesizeClaudeKeys()` | ~122 |
| `synthesizeCodexKeys()` | ~177 |
| `synthesizeOpenAICompat()` | ~250 (per-key override logic) |
| `synthesizeVertexCompat()` | ~341 |

**`internal/watcher/synthesizer/file.go`** — OAuth file-based auth:

In `synthesizeFileAuths()` (~line 155, after the priority/note block):
```go
if rawVal, ok := metadata["max_concurrent"]; ok {
    if v, ok := rawVal.(float64); ok && v > 0 {
        a.Attributes["max_concurrent"] = strconv.Itoa(int(v))
    }
}
```

In `SynthesizeGeminiVirtualAuths()` (~line 262, after the proxy_url block):
```go
if v, ok := metadata["max_concurrent"]; ok {
    metadataCopy["max_concurrent"] = v
}
```

---

### 3. Auth helper method — `sdk/cliproxy/auth/types.go`

Add `MaxConcurrentOverride()` following the same pattern as `DisableCoolingOverride()` (~line 384):

```go
func (a *Auth) MaxConcurrentOverride() (int, bool) {
    if a == nil || a.Attributes == nil {
        return 0, false
    }
    if val, ok := a.Attributes["max_concurrent"]; ok {
        if n, err := strconv.Atoi(val); err == nil && n > 0 {
            return n, true
        }
    }
    return 0, false
}
```

---

### 4. Concurrency tracking — `sdk/cliproxy/auth/conductor.go`

#### 4a. Add field to the manager struct

```go
// concurrencySlots tracks active request counts per auth (keyed by auth.Index).
concurrencySlots sync.Map // map[string]*atomic.Int32
```

#### 4b. Add two private methods

```go
// tryAcquireConcurrency attempts to reserve a concurrency slot for the given auth.
// Returns false (without blocking) if the auth is at its configured limit.
func (m *manager) tryAcquireConcurrency(auth *Auth) bool {
    limit, ok := auth.MaxConcurrentOverride()
    if !ok {
        return true // no limit configured
    }
    v, _ := m.concurrencySlots.LoadOrStore(auth.Index, new(atomic.Int32))
    counter := v.(*atomic.Int32)
    for {
        cur := counter.Load()
        if cur >= int32(limit) {
            return false
        }
        if counter.CompareAndSwap(cur, cur+1) {
            return true
        }
    }
}

func (m *manager) releaseConcurrency(auth *Auth) {
    if _, ok := auth.MaxConcurrentOverride(); !ok {
        return
    }
    if v, ok := m.concurrencySlots.Load(auth.Index); ok {
        v.(*atomic.Int32).Add(-1)
    }
}
```

**Why `sync.Map` keyed by `auth.Index`**: `auth.Index` is a stable hash-based identifier that survives config reloads. This ensures in-flight counters are correctly maintained across hot-reloads — the new Auth object for the same upstream key gets the same counter.

#### 4c. Insert acquire/release in execute functions

In **`executeMixedOnce()`** and **`executeStreamMixedOnce()`**, after `pickNextMixed()` returns an auth and before calling `executor.Execute()` / `executor.ExecuteStream()`:

```go
// Skip this auth if it is at its concurrency limit.
if !m.tryAcquireConcurrency(auth) {
    tried[auth.ID] = struct{}{}
    continue
}
defer m.releaseConcurrency(auth)
```

---

## Data Flow Summary

```
config.yaml (max-concurrent: N)
    ↓
internal/config/config.go  (ClaudeKey.MaxConcurrent, ...)
    ↓
internal/watcher/synthesizer/config.go  (attrs["max_concurrent"] = "N")
    ↓
sdk/cliproxy/auth/types.go  (Auth.Attributes["max_concurrent"])
    ↓  MaxConcurrentOverride()
sdk/cliproxy/auth/conductor.go  (tryAcquireConcurrency / releaseConcurrency)
    ↓
executor.Execute() / executor.ExecuteStream()
```

---

## Verification

```bash
# 1. Compile check
go build -o test-output ./cmd/server && rm test-output

# 2. Synthesizer unit tests
go test -v ./internal/watcher/synthesizer/...

# 3. Manual test: set max-concurrent: 1 on one key,
#    send 2 concurrent requests and confirm they route to different accounts
#    (check server logs for auth selection entries)
```
