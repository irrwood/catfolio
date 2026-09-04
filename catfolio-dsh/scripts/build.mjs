/**
 * Build script for catfolio-dsh.
 *
 * Produces:
 *   lib/index.js   — server half (Cordis plugin), ESM
 *   lib/client.js  — client half (lazy-CJS factory bundle for the harness
 *                    client module loader: window.__ModuleLoader__.load)
 *   data/*.json    — copied demo assets
 *   package.json   — plugin manifest with dsh.client config
 *
 * Usage: node scripts/build.mjs [--out <dir>]   (default: ./dist)
 */
import { build, context } from "esbuild";
import { cpSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const outFlag = process.argv.indexOf("--out");
const outDir = resolve(root, outFlag !== -1 ? process.argv[outFlag + 1] : "dist");
const watch = process.argv.includes("--watch");

const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));

async function buildAll() {
  rmSync(outDir, { recursive: true, force: true });
  mkdirSync(join(outDir, "lib"), { recursive: true });
  mkdirSync(join(outDir, "data"), { recursive: true });

  // ── server half ──────────────────────────────────────────────────────────
  await build({
    entryPoints: [join(root, "src/server/index.ts")],
    bundle: true,
    platform: "node",
    format: "esm",
    target: "node20",
    outfile: join(outDir, "lib/index.js"),
    sourcemap: true,
    logLevel: "info",
  });

  // ── client half (bundle body) ────────────────────────────────────────────
  const clientBody = join(outDir, "lib/.client-body.js");
  const clientCtx = await context({
    entryPoints: [join(root, "src/client/index.tsx")],
    bundle: true,
    platform: "browser",
    format: "cjs",
    target: "es2020",
    jsx: "automatic",
    outfile: clientBody,
    sourcemap: false,
    minify: true,
    // Provided by the harness shell / other client bundles at runtime.
    external: ["react", "react/jsx-runtime"],
    logLevel: "info",
  });

  const buildClient = async () => {
    await clientCtx.rebuild();
    const body = readFileSync(clientBody, "utf8");
    const wrapped = [
      "window.__ModuleLoader__.load({",
      "\tid: \"catfolio-dsh\",",
      "\tfactory: (require) => {",
      "\t\tvar module = { exports: {} };",
      "\t\tvar exports = module.exports;",
      "\t\tObject.defineProperty(exports, Symbol.toStringTag, { value: \"Module\" });",
      body,
      "\t\treturn module.exports;",
      "\t}",
      "});",
      "",
    ].join("\n");
    writeFileSync(join(outDir, "lib/client.js"), wrapped);
    console.log("[client] wrapped -> lib/client.js");
  };

  if (watch) {
    await buildClient();
    await clientCtx.watch();
    console.log("[watch] rebuilding client on changes…");
    return;
  }
  await buildClient();
  await clientCtx.dispose();

  // ── package manifest + data ──────────────────────────────────────────────
  const manifest = {
    name: pkg.name,
    version: pkg.version,
    description: pkg.description,
    private: true,
    type: "module",
    main: "lib/index.js",
    exports: {
      ".": "./lib/index.js",
      "./client": "./lib/client.js",
      "./package.json": "./package.json",
    },
    dsh: pkg.dsh,
  };
  writeFileSync(join(outDir, "package.json"), JSON.stringify(manifest, null, 2) + "\n");
  cpSync(join(root, "data"), join(outDir, "data"), { recursive: true });
  console.log(`[done] built into ${outDir}`);
}

await buildAll();
