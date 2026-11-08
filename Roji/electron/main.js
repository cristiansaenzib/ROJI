const { app, BrowserWindow } = require("electron");
const path = require("path");
function crear() {
  const w = new BrowserWindow({ width: 1280, height: 800, autoHideMenuBar: true, webPreferences: { contextIsolation: true } });
  w.loadFile(path.join(__dirname, "../www/index.html"));
}
app.whenReady().then(crear);
app.on("window-all-closed", () => app.quit());
