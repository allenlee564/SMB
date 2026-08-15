FROM ubuntu:22.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash sudo \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash customer

# ---- 靶機情境：備份腳本提權（呼應 campus-webserver-sdd.md 的「本地提權」階段）----
# customer 可以 sudo 免密碼執行這個腳本，但 $1 沒加雙引號，
# 會被 bash 拆成多個參數餵給 tar，可用 tar 的 --checkpoint-action 技巧提權。
RUN mkdir -p /opt/backup /var/backups \
    && printf '#!/bin/bash\ncd /var/backups\ntar czf /tmp/backup.tar.gz $1\n' > /opt/backup/backup.sh \
    && chmod 755 /opt/backup/backup.sh \
    && chown root:root /opt/backup/backup.sh \
    && printf 'FLAG{sudo_tar_backup_privesc}\n' > /root/flag.txt \
    && chmod 600 /root/flag.txt \
    && printf 'customer ALL=(root) NOPASSWD: /opt/backup/backup.sh *\n' > /etc/sudoers.d/backup \
    && chmod 440 /etc/sudoers.d/backup

USER customer
WORKDIR /home/customer

CMD ["sleep", "infinity"]
