
# Metis Log Forwarder

## 1. 用途

`log_forwarder.py` 是藍隊端的 Log Forwarder。

主要用途：

1. 收集藍隊主機上既有的 Log。
2. 將 Log 整理成 JSON。
3. 在藍隊本機建立 Log 備份。
4. 啟用轉發後，將 Log 傳送至指定的 Destination。
5. Destination 可以透過設定檔修改。

---

## 2. 架構

```text
                    【藍隊】
                 藍隊主機
                     │
                     │ 原本存在的 Log
                     ▼
              Log Forwarder
                     │
             ┌───────┴────────┐
             │                │
             ▼                ▼
       本機 Log 備份       Log Forwarding
             │                │
             │                │ Destination
             │                ▼
             │          【紫隊 Center】
             │          實體主機
             │                │
             │                ▼
             │         既有 Container
             │                │
             │                ▼
             │       指定 Log 資料夾
             │
             ▼
       logs/archive/
````

藍隊負責：

* 收集自己的 Log
* 本機備份
* 將 Log Forward 到指定位置

紫隊負責：

* 接收 Log
* 儲存 Log
* 後續分析或交由 SIEM 處理

---

## 3. Log 來源

目前 Forwarder 會收集以下來源：

### Docker

執行：

```text
docker compose logs
```

來源目錄：

```text
Metis2/backend
```

---

### Nginx

讀取：

```text
logs/nginx/access.log
```

---

### Admission

讀取：

```text
logs/admission/*.log
```

---

## 4. Log 資料格式

Forwarder 會將 Log 整理成 JSON：

```json
{
    "timestamp": "2026-08-18T11:00:00",
    "hostname": "BLUE-PC",
    "source": "blue-team",
    "docker_logs": "...",
    "nginx_logs": "...",
    "admission_logs": "..."
}
```

---

## 5. 設定檔

設定檔：

```text
config/log_forward.json
```

目前基本設定：

```json
{
    "enabled": false,
    "destination": ""
}
```

### enabled

控制是否啟用 Log Forwarding。

```json
"enabled": false
```

代表：

```text
收集 Log
   ↓
本機備份
   ↓
不轉發
```

---

```json
"enabled": true
```

代表：

```text
收集 Log
   ↓
本機備份
   ↓
傳送到 Destination
```

---

### destination

指定 Log Forwarder 的目的地。

例如：

```json
{
    "enabled": true,
    "destination": "http://192.168.50.20:8080/logs/receive"
}
```

其中：

```text
192.168.50.20
```

為紫隊 Center 的 IP。

---

## 6. 啟動

在 Metis2 根目錄執行：

```cmd
python log_forwarder.py
```

---

## 7. 指定收集間隔

預設：

```text
60 秒
```

可以指定：

```cmd
python log_forwarder.py --interval 30
```

代表每 30 秒收集一次。

---

## 8. 本機 Log 備份

收集到的 Log 會備份到：

```text
logs/archive/
```

例如：

```text
logs/archive/
└── logs-2026-08-18T11-00-00-123456.json
```

即使 Forwarding 沒有啟用，Log 仍會進行本機備份。

---

## 9. Forwarding 流程

啟用：

```json
{
    "enabled": true,
    "destination": "http://192.168.50.20:8080/logs/receive"
}
```

流程：

```text
原本存在的 Log
       ↓
Log Forwarder
       ↓
package_logs()
       ↓
JSON
       ↓
本機 archive
       ↓
HTTP POST
       ↓
Destination
       ↓
紫隊接收端
```

---

## 10. HTTP POST

目前 Forwarder 使用 HTTP POST 傳送 Log。

Request：

```text
POST /logs/receive
Content-Type: application/json
```

Request Body 為收集到的 JSON Log。

目前程式使用：

```python
requests.post(
    target_url,
    json=logs,
    headers=headers,
    timeout=10
)
```

---

## 11. 認證 Token

如果需要 Token，可以使用：

```text
PURPLE_LOG_TOKEN
```

例如 Windows CMD：

```cmd
set PURPLE_LOG_TOKEN=YOUR_TOKEN
```

Forwarder 會加入：

```text
Authorization: Bearer YOUR_TOKEN
```

---

## 12. Destination 動態修改

Forwarder 每一輪都會重新讀取：

```text
config/log_forward.json
```

因此可以在程式執行期間修改：

```json
{
    "enabled": true,
    "destination": "http://192.168.50.20:8080/logs/receive"
}
```

下一輪收集時會使用新的 Destination。

不需要重新建立 Forwarder。

---

## 13. 測試 OFF

設定：

```json
{
    "enabled": false,
    "destination": ""
}
```

執行：

```cmd
python log_forwarder.py
```

預期：

```text
Forwarding : OFF
Destination: (未設定)
```

Log 仍會收集及備份，但不會 Forward。

---

## 14. 測試 Destination

例如：

```json
{
    "enabled": true,
    "destination": "http://127.0.0.1:9999/logs/receive"
}
```

如果本機沒有服務監聽 `9999`，可能看到：

```text
無法連線到 Destination
```

這代表 Forwarder 已經嘗試送出，但 Destination 沒有接收服務。

---

## 15. 檢查 Python 語法

執行：

```cmd
python -m py_compile log_forwarder.py
```

沒有輸出代表 Python 語法檢查通過。

---

## 16. requests 套件

如果出現：

```text
找不到 requests
```

執行：

```cmd
python -m pip install requests
```

然後再次執行：

```cmd
python log_forwarder.py
```

---

## 17. 目前注意事項

目前 `log_forwarder.py` 的傳送方式是：

```text
HTTP POST
```

不是：

```text
TCP Syslog 514
```

因此如果紫隊提供的是 HTTP Endpoint：

```text
http://<Purple-Center-IP>:<Port>/logs/receive
```

目前架構可以使用。

如果紫隊要求：

```text
TCP 514
```

則需要將 Forwarder 的傳送功能改成 TCP 傳輸。

---

## 18. 最終部署概念

```text
【Blue Team】

Existing Logs
     │
     ▼
Log Forwarder
     │
     ├── enabled
     ├── destination
     │
     ├── Local Archive
     │
     ▼
HTTP POST
     │
     ▼

【Purple Center】

Physical Host
     │
     ▼
Existing Container
     │
     ▼
Log Receive Service
     │
     ▼
指定 Log 資料夾
```

---

## 19. 重要原則

### Blue Team

負責：

```text
Collect
Package
Backup
Forward
```

### Purple Team

負責：

```text
Receive
Store
Analyze
```

Blue Team 不需要進入 Purple Center Container。

Purple Team 也不需要反向進入 Blue Team 主機撈取 Log。

Log 由 Blue Team Forwarder 主動傳送到 Purple Team 指定的 Destination。

```

這份 README 跟你**目前實際程式**是一致的；尤其我刻意沒有把 `port: 514 / protocol: tcp` 寫成已經支援，因為你目前程式實際是 `requests.post()` 的 HTTP POST。:contentReference[oaicite:0]{index=0}

如果你下一步確定要改成**固定 TCP 514、設定檔只放 `enabled + destination`**，那 README 也應該跟著改成 TCP 版，而不是沿用上面這個 HTTP 版本。
```
