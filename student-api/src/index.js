const express = require("express");
const pool = require("./db");

const app = express();
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "student-api" });
});

// POST /api/student/login
// TODO: 待資料庫團隊完成 students/admins 認證欄位設計後補上真正的密碼驗證邏輯
app.post("/login", (_req, res) => {
  res.status(501).json({ error: "not_implemented", detail: "auth schema pending" });
});

// GET /api/student/:id
app.get("/:id", async (req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, department FROM students WHERE id = $1",
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
