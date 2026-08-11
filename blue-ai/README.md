# Blue AI

SMB 資安攻防平台的藍隊 AI 防禦模組。

主要功能：

- SYN / Packet Flood 偵測
- Qwen2.5-3B AI 分析
- IP 白名單
- 手動封鎖 / 解封
- Host `INPUT` 與 Docker `DOCKER-USER` 防護
- AI 自動封鎖

## 安裝與啟動

先確認 SSH 管理端 IP：

```bash
echo "$SSH_CLIENT"
```

第一個 IP 即為管理端 IP。

進入目錄並安裝：

```bash
cd ~/SMB/blue-ai
sudo ./install.sh --management-ip <管理端IP>
```

例如：

```bash
sudo ./install.sh --management-ip 192.168.1.10
```

網卡會自動從 Default Route 偵測；如需手動指定：

```bash
sudo ./install.sh \
  --management-ip <管理端IP> \
  --interface <網卡名稱>
```

安裝完成後確認：

```bash
sudo systemctl status blueai-ddos-detector --no-pager
ollama list
sudo blueai-ipctl whitelist list
```

查看即時偵測與 AI 分析：

```bash
sudo journalctl -u blueai-ddos-detector -f
```

## 常用指令

查看封鎖名單：

```bash
sudo blueai-ipctl blocked list
```

手動封鎖：

```bash
sudo blueai-ipctl block <IP>
```

解除封鎖：

```bash
sudo blueai-ipctl unblock <IP>
```

加入白名單：

```bash
sudo blueai-ipctl whitelist add <IP>/32
```

## 注意

安裝完成後預設不會自動封鎖：

```json
"auto_block": false
```

確認 Detector、Qwen 與手動封鎖功能正常後，可執行：

```bash
sudo jq '.auto_block = true' \
  /opt/blue-ai/config/settings.json \
  > /tmp/blueai-settings.json

sudo install \
  -o root -g blueai -m 0640 \
  /tmp/blueai-settings.json \
  /opt/blue-ai/config/settings.json
```

確認是否已開啟：

```bash
sudo jq '.auto_block' /opt/blue-ai/config/settings.json
```

顯示：

```text
true
```

即代表自動封鎖已啟用。

若要關閉，將 `true` 改成 `false`：

```bash
sudo jq '.auto_block = false' \
  /opt/blue-ai/config/settings.json \
  > /tmp/blueai-settings.json

sudo install \
  -o root -g blueai -m 0640 \
  /tmp/blueai-settings.json \
  /opt/blue-ai/config/settings.json
```

目前 Blue AI 主要處理封包層 DDoS；Nginx HTTP Log、Wazuh、Grafana 等功能尚未整合。
