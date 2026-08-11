// 同一個靶機、同一個漏洞，三個難度只差提示給多細
const HINTS = {
  easy: {
    label: '簡單（新手，步驟詳細）',
    steps: [
      '先在終端機打 sudo -l，看看 customer 這個帳號被允許用 sudo 執行什麼指令。',
      '你會看到 /opt/backup/backup.sh 可以無密碼用 root 身份執行，而且可以帶任意參數。',
      '用 cat /opt/backup/backup.sh 看看腳本內容，注意 tar czf /tmp/backup.tar.gz $1 這一行，$1 沒有加雙引號。',
      '沒加雙引號代表傳進去的字串會被 bash 拆成多個參數，可以偽裝成 tar 的選項。',
      '試試看：sudo /opt/backup/backup.sh "--checkpoint=1 --checkpoint-action=exec=/bin/sh /etc/hostname"（後面要加一個真的存在的檔案，tar 才不會因為沒東西可備份而直接報錯）。',
      '這樣 tar 執行到一半就會用 root 權限開一個新的 shell，接著打 cat /root/flag.txt 拿 flag。',
    ],
  },
  normal: {
    label: '普通（方向提示，需要自己嘗試）',
    steps: [
      '確認 customer 有沒有被允許用 sudo 執行特定指令。',
      '看看那個腳本裡面的變數有沒有正確地加雙引號——這是常見的 shell script 寫法錯誤。',
      '這是 tar 指令一種常見的提權手法（可以查查 GTFOBins 上 tar 的用法），想辦法讓它在備份過程中順便執行你要的指令。',
    ],
  },
  hard: {
    label: '困難（幾乎沒有提示）',
    steps: ['customer 這個帳號擁有一些 sudo 權限，仔細找找看有沒有可以濫用的地方，目標是拿到 /root/flag.txt。'],
  },
};
