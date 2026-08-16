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

// PUT /api/student/:id  (更新個人資料，目前只有 name/department 是真的 DB 欄位)
app.put("/:id", async (req, res) => {
  const { name, department } = req.body || {};
  if (!name || !name.trim()) {
    return res.status(400).json({ error: "missing_name" });
  }

  try {
    const { rows } = await pool.query(
      `UPDATE users SET name = $1, department = $2
       WHERE id = $3 AND role = 'student'
       RETURNING id, student_no, name, department`,
      [name.trim(), department || null, req.params.id]
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
      `SELECT c.id, c.name, c.teacher, c.credits, e.semester, e.score
       FROM enrollments e
       JOIN courses c ON c.id = e.course_id
       WHERE e.student_id = $1
       ORDER BY c.id`,
      [req.params.id]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

// POST /api/student/:id/courses  (選課，body: { course_id })
app.post("/:id/courses", async (req, res) => {
  const { course_id } = req.body || {};
  if (!course_id) {
    return res.status(400).json({ error: "missing_course_id" });
  }

  try {
    const studentCheck = await pool.query(
      "SELECT id FROM users WHERE id = $1 AND role = 'student'",
      [req.params.id]
    );
    if (studentCheck.rows.length === 0) {
      return res.status(404).json({ error: "student_not_found" });
    }

    const courseCheck = await pool.query("SELECT id, name, teacher, credits FROM courses WHERE id = $1", [
      course_id,
    ]);
    if (courseCheck.rows.length === 0) {
      return res.status(404).json({ error: "course_not_found" });
    }

    const { rows } = await pool.query(
      `INSERT INTO enrollments (student_id, course_id, semester)
       VALUES ($1, $2, to_char(now(), 'YYYY') || '-1')
       ON CONFLICT (student_id, course_id) DO NOTHING
       RETURNING student_id, course_id, semester, score`,
      [req.params.id, course_id]
    );

    if (rows.length === 0) {
      return res.status(409).json({ error: "already_enrolled" });
    }

    res.status(201).json({ ...courseCheck.rows[0], semester: rows[0].semester, score: rows[0].score });
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

// DELETE /api/student/:id/courses/:courseId（退選）
app.delete("/:id/courses/:courseId", async (req, res) => {
  try {
    const { rowCount } = await pool.query(
      "DELETE FROM enrollments WHERE student_id = $1 AND course_id = $2",
      [req.params.id, req.params.courseId]
    );
    if (rowCount === 0) {
      return res.status(404).json({ error: "not_enrolled" });
    }
    res.status(204).end();
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`student-api listening on ${port}`);
});
