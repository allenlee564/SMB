const express = require('express');
const path = require('path');

const app = express();
const PORT = process.env.PORT || 3000;

app.use('/vendor/xterm', express.static(path.join(__dirname, '../node_modules/@xterm/xterm/lib')));
app.use('/vendor/xterm-css', express.static(path.join(__dirname, '../node_modules/@xterm/xterm/css')));
app.use('/vendor/xterm-addon-fit', express.static(path.join(__dirname, '../node_modules/@xterm/addon-fit/lib')));
app.use(express.static(path.join(__dirname, '../public')));

app.listen(PORT, () => console.log(`[portal] listening on ${PORT}`));
