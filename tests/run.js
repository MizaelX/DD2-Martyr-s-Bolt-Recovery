// Runs tests/sim.lua against src/MartyrsBoltRecovery.lua in fengari (Lua 5.3 VM in JS).
// Usage: node tests/run.js   (needs `npm i fengari@0.1.4` resolvable, e.g. via NODE_PATH)
const fs = require("fs");
const path = require("path");
const { lua, lauxlib, lualib, to_luastring } = require("fengari");

const root = path.join(__dirname, "..");
const mod = fs.readFileSync(path.join(root, "src", "MartyrsBoltRecovery.lua"), "utf8");
const sim = fs.readFileSync(path.join(__dirname, "sim.lua"), "utf8");

const L = lauxlib.luaL_newstate();
lualib.luaL_openlibs(L);
lua.lua_pushstring(L, to_luastring(mod));
lua.lua_setglobal(L, to_luastring("MOD_SRC"));
if (lauxlib.luaL_dostring(L, to_luastring(sim)) !== lua.LUA_OK) {
  console.error("Lua error:", lua.lua_tojsstring(L, -1));
  process.exit(2);
}
lua.lua_getglobal(L, to_luastring("RESULT_FAIL"));
process.exit(lua.lua_tointeger(L, -1) === 0 ? 0 : 1);
