#!/usr/bin/env python3
import ipaddress, json, pathlib, re, subprocess, sys, urllib.request

BASE = pathlib.Path("/opt/blue-ai")
SEVERITY = {"low": 0, "medium": 1, "high": 2, "critical": 3}


def load(path):
    with open(path, encoding="utf-8") as file:
        return json.load(file)


def compact(event):
    evidence = event.get("evidence", {})
    keys = ("window_seconds", "total_packets", "total_syn_packets", "unique_source_ips",
            "source_packet_count", "source_syn_count", "source_syn_ratio", "source_packet_share")
    return {"source_ip": event.get("source_ip"), "attack_type": event.get("attack_type"),
            "attack_category": event.get("attack_category"), "severity": event.get("severity"),
            "evidence": {key: evidence.get(key) for key in keys}}


def ask(settings, event):
    prompt = """你是藍隊資安分析 AI。Detector 已完成分類，你只評估候選來源是否應封鎖。
source_ip 只是候選來源；unique_source_ips 是整場來源數。high/critical 且證據明確才封鎖。
不得修改或虛構數據及 IP。只回答三行：
BLOCK=true或false
REASON=一句簡短理由
ACTION=一項簡短建議"""
    payload = {"model": settings["model"], "stream": False, "keep_alive": "30m",
               "options": {"temperature": 0, "num_ctx": 1024, "num_predict": 80},
               "messages": [{"role": "system", "content": prompt},
                            {"role": "user", "content": json.dumps(compact(event), ensure_ascii=False,
                                                                     separators=(",", ":"))}]}
    request = urllib.request.Request(settings["ollama_url"], data=json.dumps(payload).encode(),
                                     headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=180) as response:
        return json.load(response).get("message", {}).get("content", "")


def parse(text):
    fields = {}
    for line in text.splitlines():
        match = re.match(r"^(BLOCK|REASON|ACTION)\s*=\s*(.*)$", line.strip(), re.I)
        if match:
            fields[match.group(1).upper()] = match.group(2).strip()
    if fields.get("BLOCK", "").lower() not in ("true", "false"):
        raise ValueError("invalid BLOCK response")
    return fields["BLOCK"].lower() == "true", fields


def main():
    if len(sys.argv) != 2:
        raise SystemExit(f"Usage: {sys.argv[0]} EVENT.json")
    settings, event = load(BASE / "config/settings.json"), load(sys.argv[1])
    source = str(ipaddress.IPv4Address(event["source_ip"]))
    severity = str(event.get("severity", "low")).lower()
    if severity not in SEVERITY:
        raise SystemExit("Invalid event severity")
    wants_block, fields = parse(ask(settings, event))
    gate = (settings.get("auto_block") is True and wants_block and
            SEVERITY[severity] >= SEVERITY.get(settings.get("min_block_severity", "high"), 2))
    result = "AUTO_BLOCK disabled or severity gate denied"
    if gate:
        done = subprocess.run(["sudo", "-n", "/usr/local/sbin/blueai-autoblock", source],
                              text=True, capture_output=True, check=False)
        result = (done.stdout or done.stderr).strip()
    print(f"來源 IP: {source}\n事件嚴重度: {severity}\nREASON: {fields.get('REASON', '')}\n"
          f"ACTION: {fields.get('ACTION', '')}")
    print(f"AI 建議封鎖: {wants_block}\n防火牆結果: {result}")


if __name__ == "__main__":
    main()
