# Metis Blue AI Handoff

## 主要修改

- frontend/shared/ai-assistant.js
- frontend/blue/answers.json
- frontend/blue/script.json

## 已完成功能

- Ollama Qwen2.5:3b 連線
- 第 1～5 關題號辨識
- Qwen semantic challenge routing
- 支援模糊自然語言提問
- 正式答案由 answers.json 控制
- 避免 LLM 自行幻想不存在的路徑與修補方法
- 通用 Linux 問題與 Challenge routing 分流
- 無關問題 fallback
- Hidden / Bonus 題限制保留

## 已驗證

- 第一題 -> .env
- 第二題 -> /etc/shadow
- 第三題 -> sudoers / NOPASSWD vim
- 第四題 -> internal_hosts
- 第五題 -> system_backup.sh

模糊語意測試：
- 普通帳號可讀密碼檔 -> shadow
- user1 免密使用編輯器取得 root -> sudoers
- DB 保存內網主機登入資料 -> internal_hosts
- root 定期執行且低權限使用者可修改的腳本 -> backup
- 網站資料庫設定檔權限過度開放 -> .env

## Pending

/admission/session/context 目前可能回傳 401 Unauthorized。

因此目前：
- AI challenge routing：可用
- 官方答案：可用
- 即時 Lab 狀態：尚待 Admission context 權限整合
