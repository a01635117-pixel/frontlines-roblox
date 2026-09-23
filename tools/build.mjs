// Builds Roblox model files from src/ for import into Studio.
//
// Usage: node tools/build.mjs
//
// Layout (Rojo-like):
//   src/shared/**           -> build/Shared.rbxmx   (Folder "Shared", import into ReplicatedStorage)
//   src/client/*.client.luau -> build/Client.rbxmx  (LocalScripts, import into StarterPlayerScripts)
//   src/server/*.server.luau -> build/Server.rbxmx  (Scripts, import into ServerScriptService)
//
// Inside src/shared, directories become Folders and *.luau files become
// ModuleScripts named after the file.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const buildDir = path.join(root, "build");

let referent = 0;

function xmlEscape(s) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// CDATA cannot contain "]]>": split it across two CDATA sections.
function cdata(s) {
  return `<![CDATA[${s.replace(/]]>/g, "]]]]><![CDATA[>")}]]>`;
}

function item(className, name, children = [], source) {
  const props = [`<string name="Name">${xmlEscape(name)}</string>`];
  if (source !== undefined) {
    props.push(`<ProtectedString name="Source">${cdata(source)}</ProtectedString>`);
  }
  return `<Item class="${className}" referent="RBX${referent++}"><Properties>${props.join("")}</Properties>${children.join("")}</Item>`;
}

function document(items) {
  return `<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">${items.join("")}</roblox>`;
}

function read(file) {
  // Normalise line endings; git on Windows may check files out as CRLF.
  return fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n");
}

function sharedTree(dir, name) {
  const children = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      children.push(sharedTree(full, entry.name));
    } else if (entry.name.endsWith(".luau")) {
      children.push(item("ModuleScript", entry.name.replace(/\.luau$/, ""), [], read(full)));
    }
  }
  return item("Folder", name, children);
}

function scripts(dir, suffix, className) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(suffix))
    .sort()
    .map((f) => item(className, f.slice(0, -suffix.length), [], read(path.join(dir, f))));
}

function write(name, items) {
  const file = path.join(buildDir, name);
  fs.writeFileSync(file, document(items));
  console.log(`${path.relative(root, file)}  ${(fs.statSync(file).size / 1024).toFixed(0)} KB  (${items.length} top-level)`);
}

fs.mkdirSync(buildDir, { recursive: true });
write("Shared.rbxmx", [sharedTree(path.join(root, "src/shared"), "Shared")]);
write("Client.rbxmx", scripts(path.join(root, "src/client"), ".client.luau", "LocalScript"));
write("Server.rbxmx", scripts(path.join(root, "src/server"), ".server.luau", "Script"));
