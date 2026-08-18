#!/usr/bin/env python3
"""
Metis Log Forwarder
定期收集 Docker / Nginx / Admission 日誌，
並依照 config/log_forward.json 的設定轉發給紫隊。

設定檔：
    config/log_forward.json

範例：
    {
        "enabled": true,
        "destination": "http://192.168.50.100:8080/logs/receive"
    }

啟動：
    python log_forwarder.py

指定收集間隔：
    python log_forwarder.py --interval 60

也可以暫時用命令列覆蓋 Destination：
    python log_forwarder.py --target http://192.168.50.100:8080/logs/receive
"""

import os
import sys
import json
import time
import argparse
import subprocess
from datetime import datetime
from pathlib import Path

try:
    import requests
except ImportError:
    print("❌ 找不到 requests")
    print("請執行：pip install requests")
    sys.exit(1)


# ============================================================
# 設定檔
# ============================================================

def load_forward_config(project_root: str):
    """
    讀取：
        config/log_forward.json

    回傳：
        {
            "enabled": True / False,
            "destination": "http://..."
        }
    """

    config_file = Path(project_root) / "config" / "log_forward.json"

    default_config = {
        "enabled": False,
        "destination": ""
    }

    if not config_file.exists():
        print(f"⚠ 找不到設定檔：{config_file}")
        return default_config

    try:
        with open(config_file, "r", encoding="utf-8") as f:
            config = json.load(f)

        enabled = bool(config.get("enabled", False))

        destination = str(
            config.get("destination", "")
        ).strip()

        return {
            "enabled": enabled,
            "destination": destination
        }

    except json.JSONDecodeError as e:
        print(f"❌ 設定檔 JSON 格式錯誤：{e}")
        return default_config

    except Exception as e:
        print(f"❌ 讀取設定檔失敗：{e}")
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
                ["docker", "compose", "logs"],
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
            print("⚠ 找不到 docker 指令")
            return ""

        except Exception as e:
            print(f"❌ 無法收集 Docker 日誌：{e}")
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
            print(f"⚠ Nginx Log 讀取失敗：{e}")
            return ""

    # --------------------------------------------------------
    # Admission Logs
    # --------------------------------------------------------

    def collect_admission_logs(self):
        """收集 Admission Python 日誌"""

        admission_log = self.log_dir / "admission"

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
                        f"⚠ 無法讀取 {logfile}：{e}"
                    )

            return "\n".join(logs)

        except Exception as e:
            print(
                f"❌ Admission Log 收集失敗：{e}"
            )
            return ""

    # --------------------------------------------------------
    # Package Logs
    # --------------------------------------------------------

    def package_logs(self):
        """將所有 Log 打包成 JSON"""

        timestamp = datetime.now().isoformat()

        return {
            "timestamp": timestamp,
            "hostname": (
                os.getenv(
                    "COMPUTERNAME",
                    os.getenv("HOSTNAME", "unknown")
                )
            ),
            "source": "blue-team",
            "docker_logs": self.collect_docker_logs(),
            "nginx_logs": self.collect_nginx_logs(),
            "admission_logs": self.collect_admission_logs(),
        }

    # --------------------------------------------------------
    # Upload
    # --------------------------------------------------------

    def upload_to_purple(
        self,
        logs: dict,
        target_url: str,
        token: str = None
    ):
        """使用 HTTP POST 將 Log 傳送到紫隊"""

        if not target_url:
            print("⚠ Destination 是空的，取消傳送")
            return False

        try:
            headers = {
                "Content-Type": "application/json"
            }

            if token:
                headers["Authorization"] = (
                    f"Bearer {token}"
                )

            response = requests.post(
                target_url,
                json=logs,
                headers=headers,
                timeout=10
            )

            if response.status_code in (
                200,
                201,
                202
            ):
                print(
                    f"✓ [{logs['timestamp']}] "
                    f"日誌上傳成功 → {target_url}"
                )
                return True

            print(
                f"⚠ [{logs['timestamp']}] "
                f"上傳失敗 "
                f"(HTTP {response.status_code})"
            )

            if response.text:
                print(
                    f"  回應：{response.text[:200]}"
                )

            return False

        except requests.exceptions.ConnectionError:
            print(
                f"❌ 無法連線到 Destination："
                f"{target_url}"
            )
            return False

        except requests.exceptions.Timeout:
            print(
                f"❌ 連線 Timeout："
                f"{target_url}"
            )
            return False

        except Exception as e:
            print(f"❌ 上傳失敗：{e}")
            return False

    # --------------------------------------------------------
    # Local Backup
    # --------------------------------------------------------

    def save_locally(self, logs: dict):
        """將收集到的 Log 備份到本機"""

        backup_dir = (
            self.log_dir / "archive"
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
                f"❌ 本機 Log 備份失敗：{e}"
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
        """顯示目前 Forwarder 狀態"""

        print()
        print("=" * 55)
        print("              Metis Log Forwarder")
        print("=" * 55)

        if enabled:
            print("Forwarding       : ON")
        else:
            print("Forwarding       : OFF")

        if destination:
            print(
                f"Destination      : {destination}"
            )
        else:
            print(
                "Destination      : (未設定)"
            )

        print(
            f"Interval         : {self.interval} 秒"
        )

        print("=" * 55)
        print()

    # --------------------------------------------------------
    # Main Loop
    # --------------------------------------------------------

    def run(
        self,
        target_override: str = None,
        token: str = None
    ):
        """
        主迴圈。

        每一輪都重新讀取：
            config/log_forward.json

        因此：
            enabled
            destination

        可以在程式執行期間修改，
        下一輪就會套用。
        """

        print("🚀 Metis Log Forwarder 已啟動")
        print(
            f"   專案根目錄："
            f"{self.project_root}"
        )
        print(
            f"   Log 目錄："
            f"{self.log_dir}"
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
                # 每一輪重新讀設定
                # ------------------------------------------------

                config = load_forward_config(
                    self.project_root
                )

                enabled = config["enabled"]

                destination = (
                    target_override
                    if target_override
                    else config["destination"]
                )

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

                # ------------------------------------------------
                # 收集 Log
                # ------------------------------------------------

                logs = self.package_logs()

                # ------------------------------------------------
                # 本機備份
                # ------------------------------------------------

                self.save_locally(logs)

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

                    print(
                        f"    → 傳送到："
                        f"{destination}"
                    )

                    self.upload_to_purple(
                        logs,
                        destination,
                        token
                    )

                # ------------------------------------------------
                # 等待下一輪
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
                    f"    {self.interval} 秒後重試"
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
            "收集並轉發藍隊日誌"
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
        help="收集間隔（秒，預設 60）"
    )

    parser.add_argument(
        "--target",
        default=None,
        help=(
            "暫時覆蓋 config/log_forward.json "
            "中的 Destination"
        )
    )

    parser.add_argument(
        "--token",
        default=os.getenv(
            "PURPLE_LOG_TOKEN"
        ),
        help="紫隊認證 Token"
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
    # 顯示目前設定
    # --------------------------------------------------------

    config = load_forward_config(
        args.project_root
    )

    destination = (
        args.target
        if args.target
        else config["destination"]
    )

    forwarder.print_status(
        enabled=config["enabled"],
        destination=destination
    )

    # --------------------------------------------------------
    # 啟動
    # --------------------------------------------------------

    forwarder.run(
        target_override=args.target,
        token=args.token
    )


# ============================================================
# Entry Point
# ============================================================

if __name__ == "__main__":
    main()