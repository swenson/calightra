#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Calightra Contributors.
//
// End-to-end headless browser test for the Calightra WASM RTL Simulator.
//
// Serves www/ locally, launches headless Firefox over native WebDriver BiDi
// (zero npm dependencies; requires Node 22+ built-in WebSocket), and verifies:
//   1. index.html defaults to the real Caliptra 2.1 ROM + Runtime
//      (caliptra-rom-with-log.bin + image-bundle-mldsa.bin), synchronizes the
//      independent ROM/firmware dropdowns (#rom-select, #fw-select, #image-preset),
//      and boots the real Caliptra 2.1 ROM into hardware power-on KATs ([kat] ++,
//      BOOT_STATUS=KatStarted, no [fake-rom-cold-reset]).
//   2. Switching #rom-select to fake-caliptra-rom.bin clocks calightra's
//      caliptra_top to ROM_IDLE (ready_for_mb_processing=1), populates hardware
//      KeyVault/PCR/Fuse DPI inspectors, and executes VERSION & CAPABILITIES
//      over the AXI4-Lite Mailbox UI.
//   3. Booting "fast-mldsa" streams the firmware bundle over AXI4-Lite FW_LOAD
//      into SRAM and enters hardware ECC-384 + ML-DSA-87 verification (or full
//      ready_for_runtime + FW_INFO when --full-runtime is passed).
//   4. pk-hash.html and debug-unlock.html compute expected cryptographic
//      digests and mailbox payloads without console errors.

import { spawn } from "node:child_process";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createServer } from "node:http";
import { homedir, tmpdir } from "node:os";
import { dirname, extname, join, normalize, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const WWW = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..", "www");

function parseArgs(argv) {
  const out = { fullRuntime: false, timeout: 480, outDir: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--full-runtime") {
      out.fullRuntime = true;
      if (out.timeout === 480) out.timeout = 4200;
    } else if (argv[i] === "--timeout") {
      out.timeout = Number(argv[++i]);
    } else if (argv[i] === "--out") {
      out.outDir = argv[++i];
    } else if (argv[i] === "-h" || argv[i] === "--help") {
      console.log("usage: boot-test.mjs [--full-runtime] [--timeout SECS] [--out DIR]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${argv[i]}`);
    }
  }
  return out;
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".bin": "application/octet-stream",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
};

function serveWww() {
  const server = createServer((req, res) => {
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (path.endsWith("/")) path += "index.html";
    const file = normalize(join(WWW, path));
    if (!file.startsWith(WWW + sep) || !existsSync(file) || !statSync(file).isFile()) {
      res.writeHead(404).end("not found");
      return;
    }
    res.writeHead(200, {
      "Content-Type": MIME[extname(file)] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    createReadStream(file).pipe(res);
  });
  return new Promise((ok) => server.listen(0, "127.0.0.1", () => ok(server)));
}

function freePort() {
  return new Promise((ok, fail) => {
    const s = createServer();
    s.on("error", fail);
    s.listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => ok(port));
    });
  });
}

function profileParent() {
  if (process.env.BROWSER_TEST_PROFILE_DIR) return process.env.BROWSER_TEST_PROFILE_DIR;
  if (!process.env.FIREFOX && existsSync("/snap/bin/firefox")) {
    return join(homedir(), "snap", "firefox", "common", "tmp");
  }
  return tmpdir();
}

async function launchFirefox() {
  const bin = process.env.FIREFOX || "firefox";
  const parent = profileParent();
  mkdirSync(parent, { recursive: true });
  const profile = mkdtempSync(join(parent, "calightra-wasm-test-"));
  const port = await freePort();
  const proc = spawn(
    bin,
    [
      "--headless",
      "--no-remote",
      "--window-size=1440,1080",
      "--profile",
      profile,
      "--remote-debugging-port",
      String(port),
      "about:blank",
    ],
    { stdio: ["ignore", "pipe", "pipe"] }
  );
  let stderr = "";
  const wsUrl = await new Promise((ok, fail) => {
    const timer = setTimeout(
      () => fail(new Error(`Firefox did not start BiDi within 60s:\n${stderr}`)),
      60_000
    );
    const onData = (d) => {
      stderr += d;
      const m = stderr.match(/WebDriver BiDi listening on (ws:\/\/\S+)/);
      if (m) {
        clearTimeout(timer);
        ok(m[1]);
      }
    };
    proc.stderr.on("data", onData);
    proc.stdout.on("data", onData);
    proc.on("exit", (code) => {
      clearTimeout(timer);
      fail(new Error(`Firefox exited (${code}) before BiDi was ready:\n${stderr}`));
    });
    proc.on("error", (e) => {
      clearTimeout(timer);
      fail(new Error(`Could not launch ${bin}: ${e.message}`));
    });
  });
  const cleanup = () => {
    proc.kill("SIGTERM");
    try {
      rmSync(profile, { recursive: true, force: true });
    } catch {}
  };
  return { wsUrl, cleanup };
}

class Bidi {
  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = [];
    ws.addEventListener("message", (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id !== undefined && this.pending.has(msg.id)) {
        const { ok, fail } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.type === "error") fail(new Error(`${msg.error}: ${msg.message}`));
        else ok(msg.result);
      } else if (msg.type === "event") {
        for (const l of this.listeners) l(msg);
      }
    });
  }

  static async connect(url) {
    const ws = new WebSocket(url.replace(/\/?$/, "/session"));
    await new Promise((ok, fail) => {
      ws.addEventListener("open", ok, { once: true });
      ws.addEventListener("error", () => fail(new Error(`Cannot connect to ${url}`)), {
        once: true,
      });
    });
    const bidi = new Bidi(ws);
    await bidi.send("session.new", { capabilities: { alwaysMatch: {} } });
    return bidi;
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((ok, fail) => this.pending.set(id, { ok, fail }));
  }

  on(fn) {
    this.listeners.push(fn);
  }

  async eval(context, expression) {
    const r = await this.send("script.evaluate", {
      expression: `(async () => JSON.stringify(await (${expression})))()`,
      target: { context },
      awaitPromise: true,
      resultOwnership: "none",
    });
    if (r.type === "exception") {
      throw new Error(`Page script threw: ${r.exceptionDetails?.text}`);
    }
    return r.result.value === undefined ? undefined : JSON.parse(r.result.value);
  }
}

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

async function saveScreenshot(bidi, context, outDir, name) {
  if (!outDir) return;
  mkdirSync(outDir, { recursive: true });
  try {
    const shot = await bidi.send("browsingContext.captureScreenshot", {
      context,
      origin: "document",
    });
    writeFileSync(join(outDir, `${name}.png`), Buffer.from(shot.data, "base64"));
  } catch (e) {
    console.warn(`Screenshot (${name}) failed: ${e.message}`);
  }
}

async function waitForPageReady(bidi, context) {
  const deadline = Date.now() + 60_000;
  for (;;) {
    const st = await bidi.eval(
      context,
      `({
        status: document.getElementById("status")?.textContent || "",
        runDisabled: document.getElementById("btn-run")?.disabled,
        badge: document.getElementById("caliptra-release-badge")?.textContent || "",
        buildInfo: document.getElementById("build-info")?.textContent || "",
        vendorPk: document.getElementById("vendor-pk")?.value || "",
        ownerPk: document.getElementById("owner-pk")?.value || "",
        romInfo: document.getElementById("rom-info")?.textContent || "",
        fwInfo: document.getElementById("fw-info")?.textContent || "",
      })`
    );
    if (st.status === "Ready" && !st.runDisabled && st.vendorPk.length === 96) {
      return st;
    }
    if (/failed|error/i.test(st.status)) {
      throw new Error(`Simulator page failed to initialize: ${st.status}`);
    }
    if (Date.now() > deadline) {
      throw new Error(`Simulator page not ready after 60s: ${JSON.stringify(st)}`);
    }
    await sleep(250);
  }
}

async function sendMailboxCommandUi(bidi, context, cmdValue, expectedRegex, timeoutMs = 90_000) {
  await bidi.eval(
    context,
    `(() => {
      const sel = document.getElementById("mbox-cmd");
      sel.value = ${JSON.stringify(cmdValue)};
      sel.dispatchEvent(new Event("change", { bubbles: true }));
      document.getElementById("btn-mbox-send").click();
      return true;
    })()`
  );
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    await sleep(400);
    const out = await bidi.eval(
      context,
      `({
        resp: document.getElementById("mbox-response").textContent,
        sendDisabled: document.getElementById("btn-mbox-send").disabled,
      })`
    );
    if (/^Error:/m.test(out.resp)) {
      throw new Error(`Mailbox ${cmdValue} returned error:\n${out.resp}`);
    }
    if (expectedRegex.test(out.resp) && !out.sendDisabled) {
      return out.resp;
    }
    if (Date.now() > deadline) {
      throw new Error(`Mailbox ${cmdValue} timed out (${timeoutMs} ms):\n${out.resp}`);
    }
  }
}

async function testDefaultRealRomAndSelectors(bidi, context, baseUrl, timeoutSecs, outDir, pageErrors) {
  console.log("\n=== [1/5] Default Real Caliptra 2.1 ROM + Selector Sync + Hardware KAT Boot ===");
  pageErrors.length = 0;

  await bidi.send("browsingContext.navigate", {
    context,
    url: `${baseUrl}index.html`,
    wait: "complete",
  });

  const defaults = JSON.parse(readFileSync(join(WWW, "defaults.json"), "utf8"));
  const ready = await waitForPageReady(bidi, context);
  console.log(`  Page ready: ${ready.badge} — ${ready.buildInfo}`);

  if (ready.vendorPk !== defaults.vendor_pk_hash) {
    throw new Error(`Unexpected auto-computed vendor PK hash: ${ready.vendorPk}`);
  }
  if (ready.ownerPk !== defaults.owner_pk_hash) {
    throw new Error(`Unexpected auto-computed owner PK hash: ${ready.ownerPk}`);
  }

  // Verify default selection is Real Caliptra 2.1 ROM + Real ML-DSA-87 Runtime bundle
  const initialSel = await bidi.eval(
    context,
    `({
      preset: document.getElementById("image-preset").value,
      rom: document.getElementById("rom-select").value,
      fw: document.getElementById("fw-select").value,
      hint: document.getElementById("preset-hint").textContent,
      romInfo: document.getElementById("rom-info").textContent,
      fwInfo: document.getElementById("fw-info").textContent,
    })`
  );
  if (
    initialSel.preset !== "full-mldsa" ||
    initialSel.rom !== "caliptra-rom-with-log.bin" ||
    initialSel.fw !== "image-bundle-mldsa.bin"
  ) {
    throw new Error(`Expected default full-mldsa Real ROM + Real FW, got: ${JSON.stringify(initialSel)}`);
  }
  if (!initialSel.hint.includes("Real Caliptra 2.1 ROM selected")) {
    throw new Error(`Expected Real ROM hint by default, got: ${initialSel.hint}`);
  }

  // Verify independent #rom-select switching (production quiet ROM -> preset becomes "custom")
  await bidi.eval(
    context,
    `(() => {
      const r = document.getElementById("rom-select");
      r.value = "caliptra-rom.bin";
      r.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`
  );
  await sleep(400);
  const quietSel = await bidi.eval(
    context,
    `({
      preset: document.getElementById("image-preset").value,
      romInfo: document.getElementById("rom-info").textContent,
    })`
  );
  if (quietSel.preset !== "custom" || !quietSel.romInfo.includes("(96 KB)")) {
    throw new Error(`Expected quiet ROM custom sync, got: ${JSON.stringify(quietSel)}`);
  }

  // Switch back to Real ROM with UART log + ROM-only button -> syncs to "rom-only-full"
  await bidi.eval(
    context,
    `(() => {
      const r = document.getElementById("rom-select");
      r.value = "caliptra-rom-with-log.bin";
      r.dispatchEvent(new Event("change", { bubbles: true }));
      document.getElementById("btn-clear-fw").click();
      return true;
    })()`
  );
  await sleep(400);
  const realRomOnlySel = await bidi.eval(
    context,
    `({
      preset: document.getElementById("image-preset").value,
      rom: document.getElementById("rom-select").value,
      fw: document.getElementById("fw-select").value,
    })`
  );
  if (
    realRomOnlySel.preset !== "rom-only-full" ||
    realRomOnlySel.rom !== "caliptra-rom-with-log.bin" ||
    realRomOnlySel.fw !== "none"
  ) {
    throw new Error(`Expected rom-only-full sync, got: ${JSON.stringify(realRomOnlySel)}`);
  }
  console.log("  Verified default Real ROM + independent #rom-select / #fw-select dropdown sync");

  // Boot the REAL Caliptra 2.1 ROM into hardware power-on KATs ([kat] ++, BOOT_STATUS=KatStarted)
  await bidi.eval(
    context,
    `(() => {
      document.getElementById("pause-on-ready").checked = true;
      document.getElementById("start-paused").checked = false;
      document.getElementById("btn-run").click();
      return true;
    })()`
  );

  const t0 = Date.now();
  let katState = null;
  for (;;) {
    await sleep(750);
    const st = await bidi.eval(
      context,
      `({
        status: document.getElementById("status").textContent,
        stats: document.getElementById("stats").textContent,
        phase: document.getElementById("hw-phase").textContent,
        bootStatus: document.getElementById("hw-boot-status").textContent,
        uart: document.getElementById("uart-output").textContent,
        errHidden: document.getElementById("error-decoder").hidden,
        errText: document.getElementById("error-decoder").textContent,
      })`
    );
    if (pageErrors.length) {
      throw new Error(`Console errors during Real ROM boot:\n${pageErrors.join("\n")}`);
    }
    if (!st.errHidden) {
      throw new Error(`Error decoder triggered during Real ROM boot:\n${st.errText}`);
    }
    if (/Halted|Exited: failed|init failed/i.test(st.status)) {
      throw new Error(`Simulator halted unexpectedly during Real ROM boot: ${st.status}\nUART:\n${st.uart}`);
    }
    if (st.uart.includes("fake-rom")) {
      throw new Error(`Real ROM unexpectedly printed fake-rom banner:\n${st.uart}`);
    }
    if (
      st.uart.includes("Running Caliptra ROM") &&
      st.uart.includes("[kat]") &&
      /0x0000018[23]/.test(st.bootStatus)
    ) {
      katState = st;
      break;
    }
    const elapsed = (Date.now() - t0) / 1000;
    if (elapsed > timeoutSecs) {
      throw new Error(
        `Real ROM KAT milestone timed out after ${timeoutSecs}s (phase=${st.phase}, boot=${st.bootStatus}, stats=${st.stats})`
      );
    }
  }

  const katSecs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(
    `  Real Caliptra 2.1 ROM entered hardware KATs (${katState.bootStatus}) in ${katSecs}s — ${katState.stats}`
  );

  await bidi.eval(context, `(document.getElementById("btn-stop").click(), true)`);
  await sleep(300);

  if (outDir) {
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "real-rom-kat-uart.txt"), katState.uart);
    await saveScreenshot(bidi, context, outDir, "simulator-real-rom-kat");
  }
}

async function testRomMailboxBoot(bidi, context, timeoutSecs, outDir, pageErrors) {
  console.log("\n=== [2/5] Fake ROM UI Selector + ROM_IDLE + Inspectors + AXI Mailbox ===");

  // Reset and select Fake ROM directly via #rom-select (#fw-select is already "none")
  await bidi.eval(
    context,
    `(() => {
      document.getElementById("btn-reset").click();
      return true;
    })()`
  );
  await sleep(400);

  await bidi.eval(
    context,
    `(() => {
      const r = document.getElementById("rom-select");
      r.value = "fake-caliptra-rom.bin";
      r.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`
  );
  await sleep(400);

  const fakeSel = await bidi.eval(
    context,
    `({
      preset: document.getElementById("image-preset").value,
      hint: document.getElementById("preset-hint").textContent,
    })`
  );
  if (fakeSel.preset !== "rom-only-fast" || !fakeSel.hint.includes("skips power-on KATs and IDevID/LDevID")) {
    throw new Error(`Expected Fake ROM selector to sync preset & hint, got: ${JSON.stringify(fakeSel)}`);
  }

  await bidi.eval(
    context,
    `(() => {
      document.getElementById("pause-on-ready").checked = true;
      document.getElementById("start-paused").checked = false;
      document.getElementById("btn-run").click();
      return true;
    })()`
  );

  const t0 = Date.now();
  let finalState = null;
  for (;;) {
    await sleep(750);
    const st = await bidi.eval(
      context,
      `({
        status: document.getElementById("status").textContent,
        stats: document.getElementById("stats").textContent,
        phase: document.getElementById("hw-phase").textContent,
        bootStatus: document.getElementById("hw-boot-status").textContent,
        sigRst: document.getElementById("sig-rst").textContent,
        sigFuses: document.getElementById("sig-fuses").textContent,
        sigMb: document.getElementById("sig-mb").textContent,
        sigErr: document.getElementById("sig-err").textContent,
        uart: document.getElementById("uart-output").textContent,
        log: document.getElementById("log-output").textContent,
        kv: document.getElementById("keyvault-display").textContent,
        fuses: document.getElementById("fuse-registers").textContent,
        errHidden: document.getElementById("error-decoder").hidden,
        errText: document.getElementById("error-decoder").textContent,
        mboxDisabled: document.getElementById("btn-mbox-send").disabled,
      })`
    );

    if (pageErrors.length) {
      throw new Error(`Console errors on index.html:\n${pageErrors.join("\n")}`);
    }
    if (!st.errHidden) {
      throw new Error(`Error decoder triggered during ROM boot:\n${st.errText}`);
    }
    if (/Halted|Exited: failed|init failed/i.test(st.status)) {
      throw new Error(`Simulator halted unexpectedly: ${st.status}\nUART:\n${st.uart}`);
    }

    if (st.status === "Ready (ROM mailbox)") {
      finalState = st;
      break;
    }

    const elapsed = (Date.now() - t0) / 1000;
    if (elapsed > timeoutSecs) {
      throw new Error(
        `ROM boot timed out after ${timeoutSecs}s (phase=${st.phase}, stats=${st.stats})`
      );
    }
  }

  const bootSecs = ((Date.now() - t0) / 1000).toFixed(1);
  console.log(`  Reached ROM_IDLE in ${bootSecs}s — ${finalState.stats}`);

  // Assert hardware signals, UART milestones, and DPI inspectors
  // Note: ready_for_fuses deasserts to 0 in hardware once CPTRA_FUSE_WR_DONE=1 is written.
  if (
    finalState.sigRst !== "cptra_rst_b=1" ||
    finalState.sigFuses !== "ready_for_fuses=0" ||
    finalState.sigMb !== "ready_for_mb_processing=1" ||
    finalState.sigErr !== "cptra_error=0"
  ) {
    throw new Error(
      `Unexpected RTL signal LEDs: ${finalState.sigRst}, ${finalState.sigFuses}, ${finalState.sigMb}, ${finalState.sigErr}`
    );
  }
  if (!finalState.uart.includes("Running Caliptra ROM") || !finalState.uart.includes("cold-reset]")) {
    throw new Error(`Expected Caliptra ROM banner in UART, got:\n${finalState.uart}`);
  }
  if (!finalState.kv.includes("=== KEYS (24 × 64 bytes) ===") || !finalState.kv.includes("=== PCRs (32 × 48 bytes) ===")) {
    throw new Error(`KeyVault/PCR DPI inspector missing expected sections`);
  }
  if (!finalState.fuses.includes("fuse_vendor_pk_hash[0]: 0x30399676")) {
    throw new Error(`Fuse DPI inspector missing expected vendor PK hash word 0:\n${finalState.fuses.slice(0, 300)}`);
  }
  if (finalState.mboxDisabled) {
    throw new Error("Mailbox Send button should be enabled at ROM_IDLE");
  }

  // Execute VERSION (0x46505652) & CAPABILITIES (0x43415053) over AXI4-Lite Mailbox
  const verResp = await sendMailboxCommandUi(
    bidi,
    context,
    "VERSION",
    /FipsVersionResp:[\s\S]*fips_status: APPROVED \(0\)[\s\S]*name:\s+"Caliptra/
  );
  console.log("  AXI4-Lite Mailbox VERSION -> APPROVED (0), name=\"Caliptra RTM\"");

  await sendMailboxCommandUi(
    bidi,
    context,
    "CAPABILITIES",
    /CapabilitiesResp:[\s\S]*fips_status: APPROVED \(0\)/
  );
  console.log("  AXI4-Lite Mailbox CAPABILITIES -> APPROVED (0)");

  // Switch back to VERSION so the screenshot shows the decoded FipsVersionResp nicely
  await sendMailboxCommandUi(bidi, context, "VERSION", /FipsVersionResp:/);

  if (outDir) {
    mkdirSync(outDir, { recursive: true });
    writeFileSync(join(outDir, "rom-only-uart.txt"), finalState.uart);
    writeFileSync(join(outDir, "rom-only-mbox-version.txt"), verResp);
    await saveScreenshot(bidi, context, outDir, "simulator-rom-ready");
  }
}

async function testFwLoadAndRuntimeFlow(bidi, context, fullRuntime, timeoutSecs, outDir, pageErrors) {
  console.log(
    fullRuntime
      ? "\n=== [3/5] Caliptra 2.1 Verilated RTL: Full ROM + FMC + Runtime Boot (fast-mldsa) ==="
      : "\n=== [3/5] Caliptra 2.1 Verilated RTL: ROM + AXI FW_LOAD + PQC Verification Handoff ==="
  );

  // Reset simulator and select fast-mldsa (ROM + Runtime bundle)
  await bidi.eval(
    context,
    `(() => {
      document.getElementById("btn-reset").click();
      return true;
    })()`
  );
  await sleep(400);

  await bidi.eval(
    context,
    `(() => {
      const sel = document.getElementById("image-preset");
      sel.value = "fast-mldsa";
      sel.dispatchEvent(new Event("change", { bubbles: true }));
      return true;
    })()`
  );
  await sleep(400);

  await bidi.eval(
    context,
    `(() => {
      document.getElementById("pause-on-ready").checked = true;
      document.getElementById("start-paused").checked = false;
      document.getElementById("btn-run").click();
      return true;
    })()`
  );

  const t0 = Date.now();
  let lastLog = 0;
  for (;;) {
    await sleep(1000);
    const st = await bidi.eval(
      context,
      `({
        status: document.getElementById("status").textContent,
        stats: document.getElementById("stats").textContent,
        phase: document.getElementById("hw-phase").textContent,
        bootStatus: document.getElementById("hw-boot-status").textContent,
        uploadHidden: document.getElementById("fw-upload-wrap").hidden,
        uploadLabel: document.getElementById("fw-upload-label").textContent,
        sigRt: document.getElementById("sig-rt").textContent,
        uart: document.getElementById("uart-output").textContent,
        errHidden: document.getElementById("error-decoder").hidden,
        errText: document.getElementById("error-decoder").textContent,
      })`
    );

    if (pageErrors.length) {
      throw new Error(`Console errors during FW boot:\n${pageErrors.join("\n")}`);
    }
    if (!st.errHidden) {
      throw new Error(`Error decoder triggered during FW boot:\n${st.errText}`);
    }

    const elapsed = (Date.now() - t0) / 1000;
    if (elapsed - lastLog >= 15) {
      lastLog = elapsed;
      console.log(`  ${elapsed.toFixed(0)}s: phase=${st.phase} boot=${st.bootStatus} (${st.stats})`);
    }

    if (!fullRuntime) {
      // Verify full 222.5 KB AXI FW_LOAD completes and ROM enters FwProcessor / ManifestLoaded (0x81+)
      if (
        st.phase === "FW_VERIFY_AND_RT" &&
        !st.uploadHidden &&
        st.uploadLabel.includes("100%") &&
        /0x0000008[1-9]|0x000000c[0-9]|0x00000140|0x0000040[0-9]/.test(st.bootStatus)
      ) {
        console.log(
          `  Verified AXI FW_LOAD (${st.uploadLabel}) & hardware manifest verification (${st.bootStatus}) in ${elapsed.toFixed(1)}s`
        );
        await bidi.eval(context, `(document.getElementById("btn-stop").click(), true)`);
        await sleep(300);
        await saveScreenshot(bidi, context, outDir, "simulator-fw-verify");
        return;
      }
    } else if (st.status === "Ready (Runtime mailbox)") {
      console.log(`  Reached RUNTIME_READY (${st.sigRt}) in ${elapsed.toFixed(1)}s — ${st.stats}`);
      if (!st.uart.includes("[rt] RT listening for mailbox commands")) {
        throw new Error(`Expected Runtime listening message in UART, got:\n${st.uart}`);
      }
      const fwInfoResp = await sendMailboxCommandUi(
        bidi,
        context,
        "FW_INFO",
        /FwInfoResp:[\s\S]*fips_status: APPROVED \(0\)[\s\S]*ML-DSA-87 \(1\)/
      );
      console.log("  AXI4-Lite Runtime Mailbox FW_INFO -> APPROVED (0), ML-DSA-87 (1)");
      if (outDir) {
        writeFileSync(join(outDir, "runtime-uart.txt"), st.uart);
        writeFileSync(join(outDir, "runtime-fw-info.txt"), fwInfoResp);
        await saveScreenshot(bidi, context, outDir, "simulator-runtime-ready");
      }
      return;
    }

    if (elapsed > timeoutSecs) {
      throw new Error(
        `Timed out after ${timeoutSecs}s waiting for FW milestone (phase=${st.phase}, boot=${st.bootStatus})`
      );
    }
  }
}

async function testPkHashPage(bidi, context, baseUrl, outDir, pageErrors) {
  console.log("\n=== [4/5] Companion Tool: pk-hash.html ===");
  pageErrors.length = 0;
  await bidi.send("browsingContext.navigate", {
    context,
    url: `${baseUrl}pk-hash.html`,
    wait: "complete",
  });

  const defaults = JSON.parse(readFileSync(join(WWW, "defaults.json"), "utf8"));
  const deadline = Date.now() + 15_000;
  for (;;) {
    const st = await bidi.eval(
      context,
      `({
        vHash: document.getElementById("v-hash")?.textContent || "",
        oHash: document.getElementById("o-hash")?.textContent || "",
        vMatch: document.getElementById("v-match")?.textContent || "",
        oMatch: document.getElementById("o-match")?.textContent || "",
      })`
    );
    if (st.vHash === defaults.vendor_pk_hash && st.oHash === defaults.owner_pk_hash) {
      if (!st.vMatch.startsWith("Matches") || !st.oMatch.startsWith("Matches")) {
        throw new Error(`Expected PK hash match badges, got: ${st.vMatch} / ${st.oMatch}`);
      }
      if (pageErrors.length) {
        throw new Error(`Console errors on pk-hash.html:\n${pageErrors.join("\n")}`);
      }
      console.log("  Verified Vendor & Owner PK SHA-384 hashes match Caliptra 2.1 bundle");
      await saveScreenshot(bidi, context, outDir, "pk-hash");
      return;
    }
    if (Date.now() > deadline) {
      throw new Error(`pk-hash.html did not compute expected hashes: ${JSON.stringify(st)}`);
    }
    await sleep(200);
  }
}

async function testDebugUnlockPage(bidi, context, baseUrl, outDir, pageErrors) {
  console.log("\n=== [5/5] Companion Tool: debug-unlock.html ===");
  pageErrors.length = 0;
  await bidi.send("browsingContext.navigate", {
    context,
    url: `${baseUrl}debug-unlock.html`,
    wait: "complete",
  });

  const deadline = Date.now() + 15_000;
  for (;;) {
    const st = await bidi.eval(
      context,
      `({
        manufHash: document.getElementById("manuf-hash")?.textContent || "",
        manufCmd: document.getElementById("manuf-cmd")?.textContent || "",
        prodReqCmd: document.getElementById("prod-req-cmd")?.textContent || "",
      })`
    );
    if (
      /^[0-9a-f]{128}$/.test(st.manufHash) &&
      /^[0-9a-f]{72}$/.test(st.manufCmd) &&
      /^[0-9a-f]{24}$/.test(st.prodReqCmd)
    ) {
      await bidi.eval(context, `(window.generateEccKeys(), true)`);
      await sleep(500);
      const eccStatus = await bidi.eval(
        context,
        `document.getElementById("ecc-status")?.textContent || ""`
      );
      if (eccStatus !== "Generated") {
        throw new Error(`ECC P-384 key generation failed on debug-unlock.html: ${eccStatus}`);
      }
      if (pageErrors.length) {
        throw new Error(`Console errors on debug-unlock.html:\n${pageErrors.join("\n")}`);
      }
      console.log("  Verified SHA-512 manuf token hash, checksummed commands & P-384 keygen");
      await saveScreenshot(bidi, context, outDir, "debug-unlock");
      return;
    }
    if (Date.now() > deadline) {
      throw new Error(`debug-unlock.html did not compute commands: ${JSON.stringify(st)}`);
    }
    await sleep(200);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (typeof WebSocket === "undefined") {
    throw new Error("Node 22+ is required (global WebSocket)");
  }
  if (!existsSync(join(WWW, "calightra_verilated.wasm"))) {
    throw new Error("www/calightra_verilated.wasm is missing; run ./build-wasm.sh first");
  }

  const server = await serveWww();
  const baseUrl = `http://127.0.0.1:${server.address().port}/`;
  console.log(`Serving ${WWW} at ${baseUrl}`);

  const ff = await launchFirefox();
  try {
    const bidi = await Bidi.connect(ff.wsUrl);
    const pageErrors = [];
    await bidi.send("session.subscribe", { events: ["log.entryAdded"] });
    bidi.on((ev) => {
      if (ev.method === "log.entryAdded" && ev.params.level === "error") {
        // Ignore optional external CDN failure for @noble/post-quantum in offline CI environments
        const txt = ev.params.text || "";
        if (txt.includes("esm.sh")) return;
        pageErrors.push(txt);
      }
    });

    const tree = await bidi.send("browsingContext.getTree", {});
    const context = tree.contexts[0].context;

    await testDefaultRealRomAndSelectors(
      bidi,
      context,
      baseUrl,
      args.timeout,
      args.outDir,
      pageErrors
    );
    await testRomMailboxBoot(bidi, context, args.timeout, args.outDir, pageErrors);
    await testFwLoadAndRuntimeFlow(
      bidi,
      context,
      args.fullRuntime,
      args.timeout,
      args.outDir,
      pageErrors
    );
    await testPkHashPage(bidi, context, baseUrl, args.outDir, pageErrors);
    await testDebugUnlockPage(bidi, context, baseUrl, args.outDir, pageErrors);

    await bidi.send("session.end").catch(() => {});
    console.log("\nPASS: All Calightra WASM browser E2E tests succeeded.");
  } finally {
    ff.cleanup();
    server.close();
  }
}

main().catch((err) => {
  console.error(`\nFAIL: ${err.stack || err}`);
  process.exit(1);
});
