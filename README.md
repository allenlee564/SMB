# SMB

資安攻防平台藍隊

## Webserver / Docker

後端 + Web Server 骨架，對應 `campus-webserver-sdd.md` 的架構設計。

### 目前狀態

- ✅ Nginx（反代 + JSON log）
- ✅ course-api / student-api（Node + Express 骨架，DB 查詢已接上暫定 schema）
- ✅ PostgreSQL / Redis
- ✅ Portal（購物網示範頁 + 按鈕觸發終端機，`portal/`）
- ✅ terminal-ws（WebSocket 轉 `docker exec` 進 `target-box`，`terminal-ws/`）
- ⏳ Admin（前端容器，待前端團隊完成後於 `docker-compose.yml` 取消註解接入）
- ⏳ 正式 DB schema（目前 `db/init/001_placeholder_schema.sql` 為暫定版本，待資料庫團隊取代）

### 啟動方式

```bash
docker compose up --build
```

啟動後：

- `http://localhost/api/course/list` — 課程列表
- `http://localhost/api/student/1` — 學生資料
- `http://localhost/` — 暫時頁面（前端尚未接入）

### 給前端團隊

API 路徑與回傳格式請參考 `campus-webserver-sdd.md` 第六節。完成 `portal` / `admin` 容器後，於 `docker-compose.yml` 取消對應註解、於 `nginx/nginx.conf` 將 `/` 與 `/admin` 的 `proxy_pass` 改回實際服務即可接入。

### 給資料庫團隊

`db/init/001_placeholder_schema.sql` 是暫定 schema，僅供本機測試。請依實際欄位需求提供正式 migration 檔案取代此檔。
