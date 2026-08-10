const express = require("express");
const bcrypt = require("bcryptjs");
const pool = require("./db");

const app = express();
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "student-api" });
});

// 帳號不存在時也要跑一次 bcrypt.compare（比對這組固定的假 hash），
// 讓「帳號不存在」跟「密碼錯誤」的回應時間差不多，避免被拿來列舉帳號。
const DUMMY_HASH = "$2a$10$CwTycUXWue0Thq9StjUM0uJ8Q9auGz2VBUNzXe1KGusfBs0psJp/i";

// POST /api/student/login
app.post("/login", async (req, res) => {
  const { student_no, password } = req.body || {};
  if (!student_no || !password) {
    return res.status(400).json({ error: "missing_fields" });
  }

  try {
    const { rows } = await pool.query(
      "SELECT id, student_no, name, department, role, password_hash FROM users WHERE student_no = $1",
      [student_no]
    );
    const user = rows[0];
    const matched = await bcrypt.compare(password, user ? user.password_hash : DUMMY_HASH);

    if (!user || !matched) {
      return res.status(401).json({ error: "invalid_credentials" });
    }

    // TODO: 目前只回傳使用者資料，尚未核發 session/JWT。
    // docker-compose 已經有 redis，之後可以拿來存 session（見 SDD 第七節）。
    res.json({
      id: user.id,
      student_no: user.student_no,
      name: user.name,
      department: user.department,
      role: user.role,
    });
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

// GET /api/student/:id
app.get("/:id", async (req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, student_no, name, department FROM users WHERE id = $1 AND role = 'student'",
      [req.params.id]
    );
    if (rows.length === 0) {
      return res.status(404).json({ error: "not_found" });
    }
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

// GET /api/student/:id/courses
app.get("/:id/courses", async (req, res) => {
  try {
    const { rows } = await pool.query(
      `SELECT c.id, c.name, c.teacher, c.credits
       FROM enrollments e
       JOIN courses c ON c.id = e.course_id
       WHERE e.student_id = $1`,
      [req.params.id]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`student-api listening on ${port}`);
});
