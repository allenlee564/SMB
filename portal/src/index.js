const express = require("express");
const path = require("path");

const app = express();
const publicDir = path.join(__dirname, "..", "public");

app.use(express.static(publicDir));

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "portal" });
});

// SPA 式 fallback：非靜態檔案的路徑一律回 index.html，交給前端自己導頁
app.get("*", (_req, res) => {
  res.sendFile(path.join(publicDir, "index.html"));
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`portal listening on ${port}`);
});
