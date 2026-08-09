# 校園網 Webserver 軟體設計文件 (SDD)

版本：v0.1（草案）
負責人：Terry（Webserver / Docker Compose 建置）
關聯文件：`blue-team-topology.drawio`、`blue-team-topology-explanation.md`

---

## 一、文件目的

本文件說明「校園網」專案 Webserver 端的技術設計，範圍涵蓋：

- Docker Compose 服務編排
- Nginx 反向代理與路由規則
- 容器網路與隔離設計
- API 契約（給前端與資料庫團隊對齊）
- Log 收集與 Wazuh / Grafana 監控串接
- 團隊分工邊界

不包含前端 UI/UX 細節與資料庫內部查詢優化，這兩部分分別由前端、資料庫負責人另行撰寫設計文件。

---

## 二、系統架構總覽

```text
Internet
   ↓
Fortigate 40C (Firewall)
   ↓
Ubuntu Webserver VM  (Docker Host, 192.168.2.112)
   │
   ├── DMZ
   │     └── Nginx (Reverse Proxy, Port 80/443)
   │
   ├── Application (dmz-net)
   │     ├── Portal Container   (前端 - 校園網首頁)
   │     ├── Admin Container    (前端 - 後台管理)
   │     ├── Course API         (後端服務)
   │     └── Student API        (後端服務)
   │
   ├── Database (data-net)
   │     ├── PostgreSQL  TCP 5432
   │     └── Redis       TCP 6379
   │
   └── Blue Team Monitoring / SOC
         ├── Wazuh Server
         └── Grafana
```

**設計原則**：前端容器與 API 容器共用 `dmz-net`，只有 API 容器能進一步連到 `data-net`；前端容器完全無法直接存取資料庫，符合 DMZ 隔離精神。

---

## 三、容器網路設計

| 網路 | 成員 | 用途 |
|---|---|---|
| `dmz-net` | nginx, portal, admin, course-api, student-api | 對外服務層，Nginx 統一入口 |
| `data-net` | course-api, student-api, postgres, redis | 資料存取層，禁止前端容器加入 |

Portal / Admin 容器**不**加入 `data-net`，確保資料庫僅能被兩個 API 服務存取。

---

## 四、Nginx 反向代理設計

### 4.1 路由規則

| Path | 轉發目標 | 說明 |
|---|---|---|
| `/` | `portal:3000` | 校園網前台首頁 |
| `/admin` | `admin:3000` | 後台管理介面 |
| `/api/course/` | `course-api:3000` | 課程相關 API |
| `/api/student/` | `student-api:3000` | 學生相關 API |

### 4.2 Access Log 格式（JSON）

沿用藍隊架構規劃，輸出至 `/var/log/nginx/access_json.log`，供 Wazuh 讀取：

```json
{
  "remote_addr": "",
  "request_method": "",
  "request_uri": "",
  "status": "",
  "body_bytes_sent": "",
  "request_time": "",
  "upstream_response_time": "",
  "http_user_agent": "",
  "host": ""
}
```

---

## 五、Docker Compose 服務規劃

```yaml
services:
  nginx:
    build: ./nginx
    ports: ["80:80"]
    networks: [dmz-net]
    depends_on: [portal, admin, course-api, student-api]

  portal:
    build: ./portal
    networks: [dmz-net]

  admin:
    build: ./admin
    networks: [dmz-net]

  course-api:
    build: ./course-api
    networks: [dmz-net, data-net]
    depends_on: [postgres, redis]

  student-api:
    build: ./student-api
    networks: [dmz-net, data-net]
    depends_on: [postgres, redis]

  postgres:
    image: postgres:16
    networks: [data-net]
    volumes: ["pgdata:/var/lib/postgresql/data"]

  redis:
    image: redis:7
    networks: [data-net]

networks:
  dmz-net:
  data-net:

volumes:
  pgdata:
```

> 上述為骨架草案，各服務的 `Dockerfile`、環境變數與 secrets 管理待各自實作階段補齊。

---

## 六、API 契約（給前端 / 資料庫團隊對齊用）

> 此區塊為前端與後端平行開發的關鍵：前端可依此先 mock 資料，資料庫可依此設計 schema，不需等對方完成。

### 6.1 Course API

| Method | Path | 說明 |
|---|---|---|
| GET | `/api/course/list` | 取得課程列表 |
| GET | `/api/course/:id` | 取得單一課程詳情 |
| POST | `/api/course` | 新增課程（Admin 用） |

範例 Response：
```json
{
  "id": 1,
  "name": "資料庫概論",
  "teacher": "王老師",
  "credits": 3
}
```

### 6.2 Student API

| Method | Path | 說明 |
|---|---|---|
| POST | `/api/student/login` | 登入 |
| GET | `/api/student/:id` | 取得學生資料 |
| GET | `/api/student/:id/courses` | 取得學生選課列表 |

範例 Response：
```json
{
  "id": 1001,
  "name": "陳同學",
  "department": "資訊工程系"
}
```

> 詳細欄位與錯誤碼待與資料庫團隊確認 schema 後補齊為正式版。

---

## 七、資料庫需求（給資料庫團隊）

初步預期資料表（草案，實際 schema 由資料庫負責人設計）：

- `students`：學生基本資料
- `courses`：課程資料
- `enrollments`：選課關聯表
- `admins`：後台管理帳號

Redis 用途：Session 儲存、API 快取（例如課程列表短期快取）。

---

## 八、Log / 監控串接

| 來源 | 收集方式 | 用途 |
|---|---|---|
| Nginx access log | Wazuh agent 監看 `/var/log/nginx/access_json.log` | 異常流量偵測、攻防 Demo 素材 |
| API 應用 log | 待定（規劃中，尚未實作） | 錯誤追蹤 |
| Wazuh 分析結果 | Grafana Dashboard | 視覺化監控 |

> 目前僅 Nginx access log 為已規劃項目，API 應用層 log 與 Qwen AI 分析整合仍屬「架構規劃」，尚未實作，報告時需明確區分。

---

## 九、團隊分工邊界

| 角色 | 負責範圍 |
|---|---|
| Webserver（本人） | docker-compose、Nginx、容器網路、Log 轉發串接、API 服務骨架 |
| 前端 | Portal / Admin 容器內的 UI 與功能邏輯，依第六節 API 契約串接 |
| 資料庫 | Schema 設計、Migration、依第七節需求補完欄位 |

---

## 十、待辦事項 (Open Items)

- [ ] 各服務 Dockerfile
- [ ] Nginx 正式 `nginx.conf`（含 JSON log format 設定）
- [ ] API 契約定稿（與資料庫 schema 對齊後）
- [ ] Wazuh agent 部署與規則設定
- [ ] 環境變數 / secrets 管理方式（`.env` 或 Docker secrets）
- [ ] HTTPS 憑證（Nginx 對外是否啟用 443）
