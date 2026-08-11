#!/usr/bin/env python3
import collections, ipaddress, json, pathlib, subprocess, time

BASE = pathlib.Path("/opt/blue-ai")


def classify_window(total, syn, sources, cfg):
    many = len(sources) >= cfg["unique_ip_threshold"]
    if syn >= cfg["syn_threshold"]:
        return (("Distributed " if many else "") + "SYN Flood",
                "ddos_syn_flood" if many else "dos_syn_flood")
    if total >= cfg["packet_threshold"]:
        return (("Distributed " if many else "") + "Packet Flood",
                "ddos_packet_flood" if many else "dos_packet_flood")
    return None


def analyze(samples, cfg):
    packets, syns = collections.Counter(), collections.Counter()
    for sample in samples:
        try:
            source, flag = sample.split()
            source = str(ipaddress.ip_address(source))
        except (ValueError, TypeError):
            continue
        packets[source] += 1
        syns[source] += flag == "S"
    total, syn = sum(packets.values()), sum(syns.values())
    kind = classify_window(total, syn, packets, cfg)
    if not kind:
        return []
    level = "critical" if max(total / cfg["packet_threshold"], syn / cfg["syn_threshold"]) >= 3 else "high"
    output = []
    for source, count in packets.most_common():
        if count < cfg["candidate_min_packets"]:
            continue
        output.append({"source_ip": source, "attack_type": kind[0], "attack_category": kind[1],
                       "severity": level, "evidence": {"window_seconds": cfg["window_seconds"],
                       "total_packets": total, "total_syn_packets": syn,
                       "unique_source_ips": len(packets), "source_packet_count": count,
                       "source_syn_count": syns[source], "source_syn_ratio": round(syns[source] / count, 4),
                       "source_packet_share": round(count / total, 4)}})
        if len(output) >= cfg["max_ai_candidates"]:
            break
    return output


def capture(cfg):
    done = subprocess.run(["timeout", str(cfg["window_seconds"]), "tcpdump", "-n", "-l", "-i",
                           cfg["interface"], "tcp"], text=True, capture_output=True, check=False)
    output = []
    for line in done.stdout.splitlines():
        words = line.split()
        if "IP" not in words:
            continue
        try:
            source = words[words.index("IP") + 1].rstrip(":").rsplit(".", 1)[0]
            ipaddress.ip_address(source)
        except (ValueError, IndexError):
            continue
        output.append(f"{source} {'S' if 'Flags [S]' in line else '-'}")
    return output


def main():
    cfg = json.loads((BASE / "config/ddos_detector.json").read_text())
    last = {}
    while True:
        for event in analyze(capture(cfg), cfg):
            source = event["source_ip"]
            if time.monotonic() - last.get(source, 0) < cfg["cooldown_seconds"]:
                continue
            path = BASE / "events" / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{source}.json")
            path.write_text(json.dumps(event, ensure_ascii=False, indent=2) + "\n")
            subprocess.run(["/usr/bin/python3", str(BASE / "app/analyzer.py"), str(path)], check=False)
            last[source] = time.monotonic()


if __name__ == "__main__":
    main()
