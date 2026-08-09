-- 暫定 schema，供 webserver 端啟動測試用
-- 正式欄位設計由資料庫團隊負責，這份檔案將被取代

CREATE TABLE IF NOT EXISTS courses (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    teacher TEXT,
    credits INTEGER
);

CREATE TABLE IF NOT EXISTS students (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    department TEXT
);

CREATE TABLE IF NOT EXISTS enrollments (
    student_id INTEGER REFERENCES students(id),
    course_id INTEGER REFERENCES courses(id),
    PRIMARY KEY (student_id, course_id)
);

INSERT INTO courses (name, teacher, credits) VALUES
    ('資料庫概論', '王老師', 3),
    ('網路安全導論', '李老師', 3)
ON CONFLICT DO NOTHING;

INSERT INTO students (name, department) VALUES
    ('陳同學', '資訊工程系')
ON CONFLICT DO NOTHING;
