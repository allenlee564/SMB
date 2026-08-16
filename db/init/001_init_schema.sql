-- 校園網 初版正式 schema（取代原 001_placeholder_schema.sql）
-- 僅供本機開發 / 資安攻防演練 demo 使用，users 為假資料
--
-- 設計重點：
-- 1. students / admins 合併為單一 users 表，用 role 欄位區分身份，
--    對應 student-api 的 GET /:id、POST /login。
-- 2. 登入帳號使用「學號」(student_no)：學生用真實學號，admin 也在此欄位
--    放一組管理用帳號（可視為工號），方便未來 /login 統一用同一套查詢邏輯。
--    格式統一為「1 碼角色代碼 + 8 碼數字」：學生用 B 開頭（B11123001），
--    admin 用 A 開頭（A00000001），長度和位數一致，方便日後 regex 驗證格式。
-- 3. courses / enrollments 沿用原設計，enrollments 加上 score / semester
--    當作「成績」欄位（一筆選課對應一筆成績）。
-- 4. incidents / incident_actions：藍隊記錄「偵測到的入侵事件」與「對應做的
--    應變措施」，一個事件可以有多筆處置記錄，方便事後產出時間軸 / 報告。

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- 提供 crypt() / gen_salt('bf')，種子資料用來產生真正的 bcrypt hash

CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    student_no TEXT UNIQUE NOT NULL,      -- 登入帳號：學生為學號，admin 為管理帳號
    password_hash TEXT NOT NULL,          -- bcrypt hash（$2a$/$2b$），由 pgcrypto 或 bcryptjs 產生
    name TEXT NOT NULL,
    department TEXT,                      -- admin 可為 NULL
    role TEXT NOT NULL DEFAULT 'student' CHECK (role IN ('student', 'admin')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS courses (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    teacher TEXT,
    credits INTEGER
);

CREATE TABLE IF NOT EXISTS enrollments (
    student_id INTEGER REFERENCES users(id),
    course_id INTEGER REFERENCES courses(id),
    semester TEXT,                        -- 例如 '2025-2'，先用自由格式，之後有需要再拆學年/學期欄位
    score NUMERIC(5,2),                   -- 成績，NULL 代表尚未評分
    PRIMARY KEY (student_id, course_id)
);

-- 入侵事件：藍隊 / Wazuh 偵測到的每一次攻擊事件
CREATE TABLE IF NOT EXISTS incidents (
    id SERIAL PRIMARY KEY,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    source_ip INET,                       -- 攻擊來源 IP，非 IP 型態的來源可留空另外寫在 description
    target_asset TEXT,                    -- 被攻擊的目標，例如 'nginx'、'course-api'、'postgres'
    attack_type TEXT,                     -- 例如 'SQL Injection'、'Brute Force'、'XSS'（先自由填寫，之後視演練情境再收斂成固定分類）
    severity TEXT CHECK (severity IN ('low', 'medium', 'high', 'critical')),
    status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'investigating', 'contained', 'resolved')),
    description TEXT,
    detected_by INTEGER REFERENCES users(id), -- 通報 / 發現此事件的 admin，系統自動偵測(如 Wazuh)可留 NULL
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 系統調整 / 應變措施：針對某個 incident 做了什麼處置，一個事件可以有多筆
CREATE TABLE IF NOT EXISTS incident_actions (
    id SERIAL PRIMARY KEY,
    incident_id INTEGER NOT NULL REFERENCES incidents(id),
    action_type TEXT,                     -- 例如 '封鎖IP'、'修補漏洞'、'重啟服務'、'調整防火牆規則'
    description TEXT NOT NULL,            -- 實際做了什麼、為什麼這樣做
    performed_by INTEGER REFERENCES users(id), -- 執行此措施的 admin
    performed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_incidents_status ON incidents(status);
CREATE INDEX IF NOT EXISTS idx_incidents_detected_at ON incidents(detected_at);
CREATE INDEX IF NOT EXISTS idx_incident_actions_incident_id ON incident_actions(incident_id);

-- ------------------------------------------------------------------
-- 假資料
-- 開發用密碼統一為 'Passw0rd!'（僅供本機測試帳號使用，絕對不要用在正式環境）
-- 用 pgcrypto 的 crypt(..., gen_salt('bf')) 產生真正的 bcrypt hash，
-- Node 端用 bcryptjs 的 compare() 可以直接驗證。
-- ------------------------------------------------------------------
INSERT INTO users (student_no, password_hash, name, department, role) VALUES
    ('B11123001', crypt('Passw0rd!', gen_salt('bf')), '陳同學', '資訊工程系', 'student'),
    ('B11123002', crypt('Passw0rd!', gen_salt('bf')), '林同學', '資訊工程系', 'student'),
    ('B11123003', crypt('Passw0rd!', gen_salt('bf')), '黃同學', '電機工程系', 'student'),
    ('B11123004', crypt('Passw0rd!', gen_salt('bf')), '張同學', '企業管理系', 'student'),
    ('B11123005', crypt('Passw0rd!', gen_salt('bf')), '李同學', '應用外語系', 'student'),
    ('B11123006', crypt('Passw0rd!', gen_salt('bf')), '王同學', '資訊管理系', 'student'),
    ('B11123007', crypt('Passw0rd!', gen_salt('bf')), '吳同學', '機械工程系', 'student'),
    ('B11123008', crypt('Passw0rd!', gen_salt('bf')), '劉同學', '財務金融系', 'student'),
    ('B11123009', crypt('Passw0rd!', gen_salt('bf')), '蔡同學', '大眾傳播系', 'student'),
    ('B11123010', crypt('Passw0rd!', gen_salt('bf')), '楊同學', '運動科學系', 'student'),
    ('A00000001', crypt('Passw0rd!', gen_salt('bf')), '系統管理員', NULL, 'admin')
ON CONFLICT (student_no) DO NOTHING;

INSERT INTO courses (name, teacher, credits) VALUES
    ('資料庫概論', '王老師', 3),
    ('網路安全導論', '李老師', 3)
ON CONFLICT DO NOTHING;

-- 選課 + 成績（用 student_no / 課程名稱查 id，避免依賴固定的 SERIAL 值）
INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 88
FROM users u, courses c
WHERE u.student_no = 'B11123001' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 75
FROM users u, courses c
WHERE u.student_no = 'B11123001' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', NULL -- 尚未評分
FROM users u, courses c
WHERE u.student_no = 'B11123002' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 92
FROM users u, courses c
WHERE u.student_no = 'B11123003' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 68
FROM users u, courses c
WHERE u.student_no = 'B11123004' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 81
FROM users u, courses c
WHERE u.student_no = 'B11123004' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', NULL -- 尚未評分
FROM users u, courses c
WHERE u.student_no = 'B11123005' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 95
FROM users u, courses c
WHERE u.student_no = 'B11123006' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 55
FROM users u, courses c
WHERE u.student_no = 'B11123007' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 60
FROM users u, courses c
WHERE u.student_no = 'B11123007' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 77
FROM users u, courses c
WHERE u.student_no = 'B11123008' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', NULL -- 尚未評分
FROM users u, courses c
WHERE u.student_no = 'B11123009' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 89
FROM users u, courses c
WHERE u.student_no = 'B11123010' AND c.name = '資料庫概論'
ON CONFLICT DO NOTHING;

INSERT INTO enrollments (student_id, course_id, semester, score)
SELECT u.id, c.id, '2025-2', 91
FROM users u, courses c
WHERE u.student_no = 'B11123010' AND c.name = '網路安全導論'
ON CONFLICT DO NOTHING;

-- 入侵事件 + 應變措施 假資料（示範藍隊記錄格式）
INSERT INTO incidents (detected_at, source_ip, target_asset, attack_type, severity, status, description, detected_by)
SELECT now() - interval '2 days', '203.0.113.45', 'student-api', 'SQL Injection',
       'high', 'resolved', '在 /api/student/:id 參數偵測到 SQLi 嘗試，Wazuh 告警觸發。', u.id
FROM users u WHERE u.student_no = 'A00000001';

INSERT INTO incidents (detected_at, source_ip, target_asset, attack_type, severity, status, description, detected_by)
SELECT now() - interval '3 hours', '198.51.100.23', 'nginx', 'Brute Force',
       'medium', 'investigating', '短時間內對 /api/student/login 大量嘗試不同帳密。', u.id
FROM users u WHERE u.student_no = 'A00000001';

INSERT INTO incident_actions (incident_id, action_type, description, performed_by, performed_at)
SELECT i.id, '修補漏洞', '將 SQL 查詢改為 parameterized query，並補上輸入驗證。', u.id, i.detected_at + interval '1 hour'
FROM incidents i, users u
WHERE i.attack_type = 'SQL Injection' AND u.student_no = 'A00000001';

INSERT INTO incident_actions (incident_id, action_type, description, performed_by, performed_at)
SELECT i.id, '封鎖IP', '於 nginx 層封鎖來源 IP 203.0.113.45。', u.id, i.detected_at + interval '10 minutes'
FROM incidents i, users u
WHERE i.attack_type = 'SQL Injection' AND u.student_no = 'A00000001';

INSERT INTO incident_actions (incident_id, action_type, description, performed_by, performed_at)
SELECT i.id, '調整防火牆規則', '對登入端點加上暫時性 rate limit，持續觀察中。', u.id, i.detected_at + interval '15 minutes'
FROM incidents i, users u
WHERE i.attack_type = 'Brute Force' AND u.student_no = 'A00000001';
