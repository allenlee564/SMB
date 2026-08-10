const express = require("express");
const pool = require("./db");

const app = express();
app.use(express.json());

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "course-api" });
});

// GET /api/course/list
app.get("/list", async (_req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, teacher, credits FROM courses ORDER BY id"
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: "query_failed", detail: err.message });
  }
});

// GET /api/course/:id
app.get("/:id", async (req, res) => {
  try {
    const { rows } = await pool.query(
      "SELECT id, name, teacher, credits FROM courses WHERE id = $1",
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

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`course-api listening on ${port}`);
});
