# Blue AI Assistant

Blue AI Assistant 是 Cyber Range 的本地 AI 問答元件。它負責在使用者知情下於
Windows 部署 Qwen2.5:3b，並提供 localhost HTTP API 供 Web UI 呼叫。

它不負責 Challenge Checker、修補驗證、Retest、PASS/FAIL、計分、Challenge
完成狀態、Hidden 解鎖、Portal session、Target VM 或 Lab 狀態管理。

## 架構與責任

```text
Cyber Range Web Page
  ├─ 讀取由 Web/Portal 團隊維護的 Scenario JSON
  ├─ 將 scenario system_prompt 與使用者問題組成 prompt
  └─ POST http://127.0.0.1:8765/api/generate
                         │
                         ▼
                  Blue AI Assistant
                         │
                         ▼
              Ollama 127.0.0.1:11434
                         │
                         ▼
                    qwen2.5:3b
```

Blue AI 不讀取 Scenario JSON，也不連接 Checker、Scoring Engine、Challenge DB 或
Target VM。實際模型只由後端 `config/settings.json` 決定。

## 系統需求

- Windows 10 或 Windows 11
- PowerShell
- Python 3.11 以上（建議 3.12）
- Ollama 與 Qwen2.5:3b（模型約 1.9 GB）
- 建議至少 8 GB RAM 與 5 GB 可用磁碟空間
- 安裝 Python、Ollama、dependencies 或下載模型時可能需要 Internet
- 自動安裝 prerequisites 需要 `winget`

## 知情安裝

先預覽，不寫入、不下載：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\install.ps1 -DryRun
```

確認內容後安裝；缺少 Python 或 Ollama 時允許安裝 prerequisites，缺少模型時下載：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\install.ps1 -AcceptTerms -InstallPrerequisites -PullModel
```

安裝器會明確說明將檢查或安裝 Python、Ollama、Qwen2.5:3b 與專案 `.venv`。
Blue AI 與 Ollama 都只使用 localhost；安裝器不修改演練 VM、不新增 inbound
firewall rule、不開放 LAN、不讀取使用者文件，也不移除既有模型。

若模型已安裝，可省略 `-PullModel`。若有效 `.venv` 已存在，不要求 system Python。

## 啟動與驗證

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\start.ps1
```

啟動時會預熱模型：

```text
Loading qwen2.5:3b into memory...
qwen2.5:3b ready
Blue AI Assistant ready
```

預熱與每次推論都使用 `keep_alive=-1`，要求 Ollama process 持續保留模型，避免每次
問題重新熱機。模型首次載入可能需要約 30 秒或更久；停止或重新啟動 Ollama 後仍需
重新預熱，實際保留時間也可能受系統資源管理影響。

驗證安裝：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\verify.ps1
```

Verify 只檢查 project venv、Python dependencies/tests、Ollama CLI/API、模型是否安裝、
Blue AI `/health`、模型 loaded 與 localhost-only 狀態。成功 exit code 為 `0`，失敗為
`1`。

## HTTP API

### `GET /health`

Ready 時回傳：

```json
{
  "status": "ok",
  "service": "blue-ai-assistant",
  "version": "0.3.0",
  "ollama": { "reachable": true },
  "model": {
    "name": "qwen2.5:3b",
    "installed": true,
    "loaded": true
  },
  "localhost_only": true
}
```

此 contract 不包含 Portal、Checker、Challenge、difficulty 或 score 狀態。

### `POST /api/generate`

紅隊 HTML 模板相容 request：

```json
{
  "model": "qwen2.5:3b",
  "prompt": "System: ...\nUser: ...",
  "stream": true
}
```

`model` 僅為模板相容欄位；即使 caller 傳入其他值，也不能改變後端實際模型。
Request 只接受 `model`、`prompt`、`stream`，額外的 checker、completed、score 或
hidden 欄位會以 `422` 拒絕。

`stream=true` 使用 `application/x-ndjson`：

```json
{"response":"第一段"}
{"response":"第二段"}
{"done":true}
```

`stream=false` 回傳：

```json
{"response":"完整回答","done":true}
```

錯誤 contract：invalid body `422`、prompt 過大 `413`、rate/concurrency limit `429`、
模型或 Ollama unavailable `503`、未預期錯誤 `500`。Streaming 已開始後若失敗，最後
一行為不含內部細節的 error JSON。

### `POST /api/assistant/chat`

Native API 保留並與 `/api/generate` 共用同一個模型 service：

```json
{"message":"chmod 600 是什麼意思？"}
```

回傳：

```json
{"reply":"...","done":true}
```

## Web 整合範例

```javascript
const promptPayload =
  `System: ${currentScenario.system_prompt}\nUser: ${text}`;

const response = await fetch('http://127.0.0.1:8765/api/generate', {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    model: 'qwen2.5:3b',
    prompt: promptPayload,
    stream: true
  })
});
```

前端可使用 `response.body.getReader()` 逐行解析 NDJSON。`[cmd]command[/cmd]` 維持
純文字，由前端轉為 Copy Button。AI raw response 是不可信文字，必須 escape 或
sanitize 後 render；不可未處理就插入 `innerHTML`。

## Scenario JSON 分工

建議由 Web/Portal 團隊維護：

```json
{
  "scenario_id": "easy_01",
  "difficulty": "簡單",
  "title": "網頁伺服器基礎偵查",
  "objective": "透過 CLI 探索目前系統環境。",
  "ai_enabled": true,
  "system_prompt": "你是一個 Cyber Range AI 助手...",
  "tutorial_tips": []
}
```

- Easy Scenario 可提供完整教學、精確路徑與範例命令。
- Medium Scenario 應只提供排查方向與工具，不應包含完整答案、Flag 或 Hidden 內容。
- Hard Scenario 可設定 `ai_enabled: false`，由前端停用 AI 輸入區。

Blue AI 不維護正式題庫，也不知道 Scenario 是否 Hidden、是否已解鎖或先前題目是否
完成。

### Browser-side prompt 的安全取捨

此相容模式沿用 Browser-side Scenario JSON。Scenario JSON 與 `system_prompt` 對使用者
可見且可修改，因此其中只能放該難度原本就允許使用者取得的提示。

Medium 的提示限制是教學政策，不是不可繞過的伺服器端授權邊界。Blue AI 仍會在所有
Scenario prompt 之前加入不可覆寫的 advisory-only base policy：AI 不是 Checker、不能
宣告官方 PASS/FAIL、完成、得分或 Hidden 解鎖；正式狀態由外部平台判定。

## CORS、限流與網路邊界

Blue AI 永遠 bind `127.0.0.1:8765`。跨 origin Web UI 可在 `allowed_origins` 加入明確的
`http://localhost:...` 或 `http://127.0.0.1:...` origin；不接受 wildcard。CORS 設定不會
把服務暴露到 LAN，也不應把 listen host 改為 `0.0.0.0`。

Standalone runtime 以 client IP 做簡單的 process-memory rate limit，並有 process-global
inference concurrency limit；不建立 session DB。Prompt 預設上限為 12000 characters。

Production log 只記錄 startup、request 結果、限流及 Ollama error 等固定 metadata，不
記錄完整 prompt、Scenario system prompt 或完整回答。

## 手動 non-stream 測試

```powershell
$body = @{
    model  = "qwen2.5:3b"
    prompt = "System: 你是一個資安助手。`nUser: chmod 600 是什麼意思？"
    stream = $false
} | ConvertTo-Json

Invoke-RestMethod `
    -Uri "http://127.0.0.1:8765/api/generate" `
    -Method Post `
    -ContentType "application/json" `
    -Body $body
```

回答內容由模型生成，不應以逐字文字作為驗收條件。

## 解除安裝

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\uninstall.ps1
```

只移除本專案 `.venv`；不移除 Python、Ollama、模型、source 或 user settings。

## Release 與完整性

目前 VERSION 維持 `0.3.0`，本次 source cleanup 不重建或覆寫歷史 ZIP。歷史
`blue-ai-assistant-v0.3.0-windows.zip` 的 SHA-256 為：

```text
C49750300EF5B31D9A1EF3D7975AC7E4F2AE9D034FD312F0663703F648C863A9
```

未來 release package 只允許 AI runtime、config、installer、必要 tests 與文件，不包含
Portal、Challenge、Checker、target adapter、Lab provisioning 或 scoring engine。

## 已知限制

- 沒有內建 Web UI；本專案只提供 HTTP API 與整合範例。
- Browser-side Scenario prompt 是可見、可修改的教學資料。
- 沒有提供給 LAN/Internet 暴露使用的 authentication 或 TLS 設計。
- 不是 Windows Service；以前景執行，使用 `Ctrl+C` 停止。
- 模型回答可能錯誤，且 AI 無法判定正式 Challenge 結果。
- 沒有 Setup.exe、MSI、code signing、自動更新或自動發布流程。
