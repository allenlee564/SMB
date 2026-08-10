# SMB

資安攻防平台藍隊

## Webserver / Docker

後端 + Web Server 骨架，對應 `campus-webserver-sdd.md` 的架構設計。

### 目前狀態

- ✅ Nginx（反代 + JSON log）
- ✅ course-api / student-api（Node + Express 骨架，DB 查詢已接上暫定 schema）
- ✅ PostgreSQL / Redis
- ⏳ Portal / Admin（前端容器，待前端團隊完成後於 `docker-compose.yml` 取消註解接入）
- ✅ DB schema 初版（`db/init/001_init_schema.sql`：`users`（含 role 區分 student/admin）、`courses`、`enrollments`（含成績欄位）、`incidents`、`incident_actions`，附假資料）
- ✅ `/api/student/login`（bcrypt 驗證，開發假帳密見下方；尚未核發 session/JWT，僅回傳使用者資料）
- ⏳ `incidents` / `incident_actions` 目前只有 DB schema，API 尚未提供對應的 CRUD 端點

### 啟動方式

```bash
docker compose up --build
```

啟動後：

- `http://localhost/api/course/list` — 課程列表
- `http://localhost/api/student/1` — 學生資料
- `http://localhost/` — 暫時頁面（前端尚未接入）

測試登入（開發假帳密，`student_no` 見 `db/init/001_init_schema.sql`，密碼皆為 `Passw0rd!`）：

```bash
curl -X POST http://localhost/api/student/login \
  -H "Content-Type: application/json" \
  -d '{"student_no":"B11123001","password":"Passw0rd!"}'
```

### 給前端團隊

API 路徑與回傳格式請參考 `campus-webserver-sdd.md` 第六節。完成 `portal` / `admin` 容器後，於 `docker-compose.yml` 取消對應註解、於 `nginx/nginx.conf` 將 `/` 與 `/admin` 的 `proxy_pass` 改回實際服務即可接入。

### 給資料庫團隊

`db/init/001_init_schema.sql` 是目前的 schema 初版（`users` / `courses` / `enrollments` / `incidents` / `incident_actions`，附假資料），僅供本機測試。完整的表結構、ER 圖、欄位說明、假資料清單請看 `campus-database-sdd.md`。之後若要改欄位，建議用新增編號檔（`002_xxx.sql`…）的 migration 方式擴充，而不是直接改這支檔案——因為 `db/init` 只會在 Postgres volume 是空的時候自動執行一次，改完舊檔案在既有環境不會生效，需要 `docker compose down -v` 重跑。
