# SMB

資安攻防平台藍隊

## Webserver / Docker

後端 + Web Server 骨架，對應 `campus-webserver-sdd.md` 的架構設計。

### 目前狀態

- ✅ Nginx（反代 + JSON log）
- ✅ course-api / student-api（Node + Express 骨架，DB 查詢已接上暫定 schema）
- ✅ PostgreSQL / Redis
- ✅ Portal（`frontend-example` 分支的 `campus-portal` 靜態頁面，已接進 `docker-compose.yml` + 串上真的 API，見下方「前端整合」）
- ⏳ Admin（後台管理前端容器，待前端負責人完成後於 `docker-compose.yml` 比照 portal 接入）
- ✅ DB schema 初版（`db/init/001_init_schema.sql`：`users`（含 role 區分 student/admin）、`courses`、`enrollments`（含成績欄位）、`incidents`、`incident_actions`，附假資料）
- ✅ `/api/student/login`（bcrypt 驗證，開發假帳密見下方；尚未核發 session/JWT，僅回傳使用者資料）
- ⏳ `incidents` / `incident_actions` 目前只有 DB schema，API 尚未提供對應的 CRUD 端點

### 啟動方式

```bash
docker compose up --build
```

啟動後：

- `http://localhost/` — 校園入口網站（登入頁：`login.html`）
- `http://localhost/api/course/list` — 課程列表
- `http://localhost/api/student/1` — 學生資料

測試登入（開發假帳密，`student_no` 見 `db/init/001_init_schema.sql`，密碼皆為 `Passw0rd!`）：

```bash
curl -X POST http://localhost/api/student/login \
  -H "Content-Type: application/json" \
  -d '{"student_no":"B11123001","password":"Passw0rd!"}'
```

### 前端整合

`portal/public/` 是 `frontend-example` 分支 `smb2/campus-portal` 那幾支靜態頁面搬過來的，已經串上真的 API（原本是純假資料 + `localStorage`）：

| 頁面 | 串接內容 |
|---|---|
| `login.html` | `POST /api/student/login` |
| `index.html` | 進站檢查登入狀態（沒登入導回 `login.html`），顯示真實姓名 |
| `courses.html` | `GET /api/student/:id/courses`（含成績），課表格柵因為 DB 沒有上課時間欄位先移除 |
| `grades.html` | 同上，前端算學分加權 GPA、依學期分組統計 |
| `enrollment.html` | `GET /api/course/list` + `POST /api/student/:id/courses`（新增的選課端點） |
| `profile.html` | 姓名/系所/學號走 `GET`/`PUT /api/student/:id`；年級/班級/Email/電話/入學年度資料庫還沒有對應欄位，先存 `localStorage`（頁面上有註明，不是真的存進資料庫） |

共用邏輯（`requireLogin`、`apiFetch`、GPA 換算等）都在 `portal/public/api.js`，六支頁面都靠 `<script src="api.js">` 載入。

`portal` 容器（`portal/Dockerfile` + `portal/src/index.js`）是純 Express 靜態檔案伺服器，`docker-compose.yml`／`nginx.conf` 已經接好（`/` 走 `portal:3000`）。後台管理前端（`admin`）之後比照這個模式接入即可。

### 給資料庫團隊

`db/init/001_init_schema.sql` 是目前的 schema 初版（`users` / `courses` / `enrollments` / `incidents` / `incident_actions`，附假資料），僅供本機測試。完整的表結構、ER 圖、欄位說明、假資料清單請看 `campus-database-sdd.md`。之後若要改欄位，建議用新增編號檔（`002_xxx.sql`…）的 migration 方式擴充，而不是直接改這支檔案——因為 `db/init` 只會在 Postgres volume 是空的時候自動執行一次，改完舊檔案在既有環境不會生效，需要 `docker compose down -v` 重跑。
