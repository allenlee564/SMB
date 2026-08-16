/*
 * 共用的 API 串接小工具，六支頁面都會載入這支檔案。
 * 透過 nginx 反代，同一個 origin 下 /api/... 就能打到 course-api / student-api，
 * 不用另外處理 CORS 或寫死 host。
 */

const API_BASE = "/api";

/** 讀取目前登入的使用者物件（login.html 登入成功後會存進來）。 */
function getLoginUser() {
  const raw = localStorage.getItem("loginUser");
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch (err) {
    return null;
  }
}

/** 沒登入就導回 login.html，回傳 null；已登入回傳使用者物件。 */
function requireLogin() {
  const user = getLoginUser();
  if (!user) {
    window.location.href = "login.html";
    return null;
  }
  return user;
}

function logout() {
  localStorage.removeItem("loginUser");
  window.location.href = "login.html";
}

/**
 * 呼叫後端 API，回傳解析後的 JSON。
 * 非 2xx 會 throw，err.status 是 HTTP 狀態碼、err.body 是後端回傳的錯誤物件。
 */
async function apiFetch(path, options = {}) {
  const res = await fetch(API_BASE + path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });

  if (!res.ok) {
    const body = await res.json().catch(() => ({}));
    const err = new Error(body.error || `HTTP ${res.status}`);
    err.status = res.status;
    err.body = body;
    throw err;
  }

  if (res.status === 204) return null;
  return res.json();
}

/** 0~100 分數換算成等第（A+/A/... /F），score 為 null 時回傳「未評分」。 */
function scoreToLetter(score) {
  if (score === null || score === undefined) return "未評分";
  const s = Number(score);
  if (s >= 90) return "A+";
  if (s >= 85) return "A";
  if (s >= 80) return "A-";
  if (s >= 77) return "B+";
  if (s >= 73) return "B";
  if (s >= 70) return "B-";
  if (s >= 67) return "C+";
  if (s >= 63) return "C";
  if (s >= 60) return "C-";
  return "F";
}

/** 0~100 分數換算成 4.0 GPA 級距，score 為 null 時回傳 null（不列入平均計算）。 */
function scoreToGpaPoint(score) {
  if (score === null || score === undefined) return null;
  const s = Number(score);
  if (s >= 90) return 4.3;
  if (s >= 85) return 4.0;
  if (s >= 80) return 3.7;
  if (s >= 77) return 3.3;
  if (s >= 73) return 3.0;
  if (s >= 70) return 2.7;
  if (s >= 67) return 2.3;
  if (s >= 63) return 2.0;
  if (s >= 60) return 1.7;
  return 0;
}

function formatScore(score) {
  return score === null || score === undefined ? "—" : score;
}
