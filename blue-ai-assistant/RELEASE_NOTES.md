# Blue AI Assistant 0.3.0 Release Notes

> Source-tree notice: the current working source has completed an unreleased AI-only
> scope cleanup and Red-Team `/api/generate` compatibility change. It does not rebuild or
> replace the historical v0.3.0 ZIP described by this document.

Release date: 2026-08-13

## 本版重點

- 透過本機 Ollama 執行 Qwen2.5:3b 推論。
- Easy／Normal／Hard 難度的 AI assistance 資料隔離；Hard mode 不呼叫模型。
- 未解鎖隱藏題不送入模型。
- FastAPI 服務只監聽 `127.0.0.1:8765`，Ollama 使用 `127.0.0.1:11434`。
- 啟動時預熱 Qwen2.5:3b，並以 `keep_alive=-1` 要求 Ollama 在其 process 持續運行期間保留模型。
- `/health` 同時回報 Ollama reachable、模型 installed／loaded 與 localhost-only 狀態。
- Windows PowerShell 安裝流程支援 DryRun、明確同意、prerequisite 安裝、模型下載及安裝後 Verify。
- Verify 檢查虛擬環境、dependencies、Python tests、Ollama、模型及 API readiness，並提供明確 exit code。
- 保守解除安裝只刪除專案 `.venv`，不移除共用 Python、Ollama 或任何 Ollama model。
- 提供可重建、可驗證的 Windows Release ZIP 與 SHA-256 checksum。

## System Requirements

- Windows 10 或 Windows 11；主要驗證平台為 Windows 11。
- PowerShell。
- Python 3.11 以上；建議 Python 3.12。
- Ollama 與 Qwen2.5:3b（約 1.9 GB）。
- 建議至少 8 GB RAM、約 5 GB 可用磁碟空間；GPU 可選。
- 安裝 prerequisites、Python dependencies 或下載模型時可能需要 Internet。
- 缺少 Python／Ollama 時，自動安裝路徑需要可用的 `winget`。

## Security Model

- Blue AI 與 Ollama 預設僅使用 localhost，不新增 inbound firewall rule，也不對 LAN 開放。
- Blue AI 是輔助服務，不決定 PASS／FAIL，不自動攻擊、修改、修補或封鎖演練 VM。
- Checker／Retest 是 Challenge 修補狀態的正式判定來源。
- AI 推論透過本機 Ollama 執行；只有選用安裝或下載流程時才可能需要外部網路。
- 難度與隱藏題資料由後端範圍控制；本 Release 文件不包含 Challenge answers。
- 本機 API 尚未具備供 LAN 暴露使用的完整認證設計，不應自行改成對外 bind。
- 不蒐集 telemetry，不加入 analytics 或 remote logging。

## Known Limitations

- 本版沒有 Web UI、Portal 整合、正式 Challenge 題庫或 VM auto-remediation。
- 不是 Windows Service；API 在前景執行，以 `Ctrl+C` 停止，沒有獨立 stop script 或開機自啟。
- 未提供 Setup.exe、MSI、code signing、自動更新或 GitHub Release 發布流程。
- Release ZIP 不內嵌 Python、Ollama 或模型；乾淨環境需在安裝時建立 `.venv` 並取得必要元件。
- 模型首次預熱可能約需 30 秒或更久，實際速度取決於硬體與 Ollama。
- `keep_alive=-1` 是送給 Ollama 的持續載入要求；實際記憶體生命週期仍由 Ollama process 與系統資源管理。
- 模型回答可能有錯誤；Hard mode 不提供 AI assistance。
- 主要在 Windows 11 驗證，未完整涵蓋所有 Windows 10／11 build。

## Release Integrity

Windows package 命名為 `blue-ai-assistant-v0.3.0-windows.zip`，並附同名 `.sha256` 檔案。使用前請以 PowerShell `Get-FileHash -Algorithm SHA256` 計算 ZIP 雜湊並比對 checksum。
