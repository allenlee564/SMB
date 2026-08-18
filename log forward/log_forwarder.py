#!/usr/bin/env python3
"""
Metis Log Forwarder

用途：
    收集藍隊主機上既有的 Log，
    本機備份後，依設定轉發至紫隊 Center。

傳輸方式：
    TCP
    Port: 514

設定檔：
    config/log_forward.json

設定範例：
    {
        "enabled": true,
        "destination": "192.168.50.20"
    }

啟動：
    python log_forwarder.py

指定收集間隔：
    python log_forwarder.py --interval 60
"""

import os
import sys
import json
import time
import socket
import argparse
import subprocess
from datetime import datetime
from pathlib import Path


# ============================================================
# 固定傳輸設定
# ============================================================

FORWARD_PROTOCOL = "tcp"
FORWARD_PORT = 514

CONFIG_FILENAME = "log_forward.json"


# ============================================================
# 設定檔
# ============================================================

def load_forward_config(project_root: str):
    """
    讀取：
        config/log_forward.json

    設定格式：

        {
            "enabled": true,
            "destination": "192.168.50.20"
        }
    """

    config_file = (
        Path(project_root)
        / "config"
        / CONFIG_FILENAME
    )

    default_config = {
        "enabled": False,
        "destination": ""
    }

    if not config_file.exists():
        print(
            f"⚠ 找不到設定檔：{config_file}"
        )
        return default_config

    try:
        with open(
            config_file,
            "r",
            encoding="utf-8"
        ) as f:
            config = json.load(f)

        enabled = bool(
            config.get("enabled", False)
        )

        destination = str(
            config.get("destination", "")
        ).strip()

        return {
            "enabled": enabled,
            "destination": destination
        }

    except json.JSONDecodeError as e:
        print(
            f"❌ 設定檔 JSON 格式錯誤：{e}"
        )
        return default_config

    except Exception as e:
        print(
            f"❌ 讀取設定檔失敗：{e}"
        )
        return default_config


# ============================================================
# Log Forwarder
# ============================================================

class LogForwarder:

    def __init__(
        self,
        project_root: str,
        log_dir: str,
        interval_seconds: int
    ):
        self.project_root = Path(project_root)
        self.log_dir = Path(log_dir)
        self.interval = interval_seconds

        self.log_dir.mkdir(
            parents=True,
            exist_ok=True
        )

    # --------------------------------------------------------
    # Docker Logs
    # --------------------------------------------------------

    def collect_docker_logs(self):
        """收集 Docker Compose 容器日誌"""

        try:
            result = subprocess.run(
                [
                    "docker",
                    "compose",
                    "logs"
                ],
                cwd=self.project_root / "backend",
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode != 0:
                print(
                    "⚠ Docker Log 收集失敗："
                    f"{result.stderr.strip()}"
                )
                return ""

            return result.stdout

        except FileNotFoundError:
            print(
                "⚠ 找不到 docker 指令"
            )
            return ""

        except Exception as e:
            print(
                f"❌ 無法收集 Docker 日誌：{e}"
            )
            return ""

    # --------------------------------------------------------
    # Nginx Logs
    # --------------------------------------------------------

    def collect_nginx_logs(self):
        """收集 Nginx access.log"""

        nginx_log = (
            self.log_dir
            / "nginx"
            / "access.log"
        )

        if not nginx_log.exists():
            return ""

        try:
            return nginx_log.read_text(
                encoding="utf-8",
                errors="ignore"
            )

        except Exception as e:
            print(
                f"⚠ Nginx Log 讀取失敗：{e}"
            )
            return ""

    # --------------------------------------------------------
    # Admission Logs
    # --------------------------------------------------------

    def collect_admission_logs(self):
        """收集 Admission Python 日誌"""

        admission_log = (
            self.log_dir
            / "admission"
        )

        if not admission_log.exists():
            return ""

        logs = []

        try:
            for logfile in sorted(
                admission_log.glob("*.log")
            ):
                try:
                    content = logfile.read_text(
                        encoding="utf-8",
                        errors="ignore"
                    )

                    logs.append(content)

                except Exception as e:
                    print(
                        f"⚠ 無法讀取 {logfile}："
                        f"{e}"
                    )

            return "\n".join(logs)

        except Exception as e:
            print(
                "❌ Admission Log 收集失敗："
                f"{e}"
            )
            return ""

    # --------------------------------------------------------
    # Package Logs
    # --------------------------------------------------------

    def package_logs(self):
        """將所有 Log 打包成 JSON"""

        timestamp = datetime.now().isoformat()

        hostname = os.getenv(
            "COMPUTERNAME",
            os.getenv(
                "HOSTNAME",
                "unknown"
            )
        )

        return {
            "timestamp": timestamp,
            "hostname": hostname,
            "source": "blue-team",
            "docker_logs": (
                self.collect_docker_logs()
            ),
            "nginx_logs": (
                self.collect_nginx_logs()
            ),
            "admission_logs": (
                self.collect_admission_logs()
            ),
        }

    # --------------------------------------------------------
    # TCP Forward
    # --------------------------------------------------------

    def upload_to_purple(
        self,
        logs: dict,
        destination: str
    ):
        """
        使用 TCP 514 傳送 Log。

        傳輸格式：
            JSON + newline

        紫隊接收端可以依 newline
        將每一個 JSON 視為一筆資料。
        """

        if not destination:
            print(
                "⚠ Destination 是空的，取消傳送"
            )
            return False

        try:
            # 將 JSON 序列化
            payload = json.dumps(
                logs,
                ensure_ascii=False,
                separators=(",", ":")
            )

            # 使用 newline 作為一筆 Log 的結尾
            payload += "\n"

            # UTF-8 編碼
            data = payload.encode(
                "utf-8"
            )

            print(
                f"    → TCP {destination}:"
                f"{FORWARD_PORT}"
            )

            # 建立 TCP Socket
            with socket.socket(
                socket.AF_INET,
                socket.SOCK_STREAM
            ) as sock:

                # TCP 連線 timeout
                sock.settimeout(10)

                # 連線到紫隊 Center
                sock.connect(
                    (
                        destination,
                        FORWARD_PORT
                    )
                )

                # 傳送資料
                sock.sendall(data)

            print(
                f"✓ [{logs['timestamp']}] "
                f"Log TCP 傳送成功 → "
                f"{destination}:{FORWARD_PORT}"
            )

            return True

        except socket.timeout:
            print(
                f"❌ TCP 連線 Timeout："
                f"{destination}:{FORWARD_PORT}"
            )
            return False

        except ConnectionRefusedError:
            print(
                f"❌ TCP 連線被拒絕："
                f"{destination}:{FORWARD_PORT}"
            )
            return False

        except OSError as e:
            print(
                f"❌ TCP 傳送失敗："
                f"{destination}:{FORWARD_PORT}"
            )
            print(
                f"   詳細錯誤：{e}"
            )
            return False

        except Exception as e:
            print(
                f"❌ Log 傳送失敗：{e}"
            )
            return False

    # --------------------------------------------------------
    # Local Backup
    # --------------------------------------------------------

    def save_locally(
        self,
        logs: dict
    ):
        """將收集到的 Log 備份到本機"""

        backup_dir = (
            self.log_dir
            / "archive"
        )

        backup_dir.mkdir(
            parents=True,
            exist_ok=True
        )

        timestamp = (
            logs["timestamp"]
            .replace(":", "-")
            .replace(".", "-")
        )

        backup_file = (
            backup_dir
            / f"logs-{timestamp}.json"
        )

        try:
            with open(
                backup_file,
                "w",
                encoding="utf-8"
            ) as f:

                json.dump(
                    logs,
                    f,
                    indent=2,
                    ensure_ascii=False
                )

            print(
                f"✓ 日誌已備份："
                f"{backup_file}"
            )

            return backup_file

        except Exception as e:
            print(
                f"❌ 本機 Log 備份失敗："
                f"{e}"
            )

            return None

    # --------------------------------------------------------
    # Status
    # --------------------------------------------------------

    def print_status(
        self,
        enabled: bool,
        destination: str
    ):
        """顯示 Forwarder 狀態"""

        print()
        print("=" * 60)
        print(
            "                 Metis Log Forwarder"
        )
        print("=" * 60)

        print(
            f"Forwarding       : "
            f"{'ON' if enabled else 'OFF'}"
        )

        if destination:
            print(
                f"Destination      : "
                f"{destination}"
            )
        else:
            print(
                "Destination      : "
                "(未設定)"
            )

        print(
            f"Protocol         : "
            f"{FORWARD_PROTOCOL.upper()}"
        )

        print(
            f"Port             : "
            f"{FORWARD_PORT}"
        )

        print(
            f"Interval         : "
            f"{self.interval} 秒"
        )

        print("=" * 60)
        print()

    # --------------------------------------------------------
    # Main Loop
    # --------------------------------------------------------

    def run(self):
        """
        主迴圈。

        每一輪重新讀取：
            config/log_forward.json

        因此：
            enabled
            destination

        可以在程式執行期間修改。
        下一輪會套用新的設定。
        """

        print(
            "🚀 Metis Log Forwarder 已啟動"
        )

        print(
            f"   專案根目錄："
            f"{self.project_root}"
        )

        print(
            f"   Log 目錄："
            f"{self.log_dir}"
        )

        print(
            f"   傳輸協定："
            f"{FORWARD_PROTOCOL.upper()}"
        )

        print(
            f"   傳輸 Port："
            f"{FORWARD_PORT}"
        )

        print(
            f"   收集間隔："
            f"{self.interval} 秒"
        )

        print()

        counter = 0

        while True:

            try:
                counter += 1

                # ------------------------------------------------
                # 每一輪重新讀取設定
                # ------------------------------------------------

                config = load_forward_config(
                    self.project_root
                )

                enabled = config[
                    "enabled"
                ]

                destination = config[
                    "destination"
                ]

                print()
                print(
                    f"[{counter}] "
                    f"開始收集 Log..."
                )

                print(
                    f"    Forwarding : "
                    f"{'ON' if enabled else 'OFF'}"
                )

                print(
                    f"    Destination: "
                    f"{destination or '(未設定)'}"
                )

                print(
                    f"    Protocol   : "
                    f"{FORWARD_PROTOCOL.upper()}"
                )

                print(
                    f"    Port       : "
                    f"{FORWARD_PORT}"
                )

                # ------------------------------------------------
                # 收集 Log
                # ------------------------------------------------

                logs = self.package_logs()

                # ------------------------------------------------
                # 本機備份
                # ------------------------------------------------

                self.save_locally(
                    logs
                )

                # ------------------------------------------------
                # Forwarding
                # ------------------------------------------------

                if not enabled:

                    print(
                        "    ℹ Log Forwarding "
                        "目前為 OFF"
                    )

                elif not destination:

                    print(
                        "    ⚠ Forwarding 已開啟，"
                        "但 Destination 未設定"
                    )

                else:

                    self.upload_to_purple(
                        logs,
                        destination
                    )

                # ------------------------------------------------
                # 下一輪
                # ------------------------------------------------

                print(
                    f"    下次收集："
                    f"{self.interval} 秒後"
                )

                time.sleep(
                    self.interval
                )

            except KeyboardInterrupt:

                print()
                print(
                    "⏹ Log Forwarder 已停止"
                )

                sys.exit(0)

            except Exception as e:

                print(
                    f"❌ Forwarder 發生錯誤："
                    f"{e}"
                )

                print(
                    f"    {self.interval} "
                    f"秒後重試"
                )

                time.sleep(
                    self.interval
                )


# ============================================================
# Main
# ============================================================

def main():

    parser = argparse.ArgumentParser(
        description=(
            "Metis Log Forwarder："
            "收集並以 TCP 514 "
            "轉發藍隊日誌"
        )
    )

    parser.add_argument(
        "--project-root",
        default=(
            "C:\\Users\\SCE\\Desktop\\Metis2"
        ),
        help="Metis 專案根目錄"
    )

    parser.add_argument(
        "--log-dir",
        default=(
            "C:\\Users\\SCE\\Desktop\\Metis2\\logs"
        ),
        help="日誌儲存目錄"
    )

    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help=(
            "收集間隔（秒，"
            "預設 60）"
        )
    )

    args = parser.parse_args()

    # --------------------------------------------------------
    # 建立 Forwarder
    # --------------------------------------------------------

    forwarder = LogForwarder(
        project_root=args.project_root,
        log_dir=args.log_dir,
        interval_seconds=args.interval
    )

    # --------------------------------------------------------
    # 讀取目前設定
    # --------------------------------------------------------

    config = load_forward_config(
        args.project_root
    )

    # --------------------------------------------------------
    # 顯示設定
    # --------------------------------------------------------

    forwarder.print_status(
        enabled=config["enabled"],
        destination=config["destination"]
    )

    # --------------------------------------------------------
    # 啟動
    # --------------------------------------------------------

    forwarder.run()


# ============================================================
# Entry Point
# ============================================================

if __name__ == "__main__":
    main()