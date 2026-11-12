// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Calightra Contributors.
//
// Calightra Browser RTL Simulator — Main UI Controller
// Drives the Verilated Caliptra 2.1 SystemVerilog RTL WebAssembly Worker,
// live hardware signal panel, UART console, AXI4-Lite mailbox client,
// and zero-cycle DPI KeyVault / PCR / Fuse inspectors.

const DEFAULT_MANUF_DBG_TOKEN_HEX =
  "d8922c55792b737f2913f3e5cbe654756252016eaee963a1dd4e753af787f096";

const PRESETS = {
  "fast-mldsa": {
    rom: "fake-caliptra-rom.bin",
    fw: "fake-image-bundle-mldsa.bin",
    pqc: 1,
    romLabel: "Fast-boot ROM (fake-caliptra-rom.bin)",
    fwLabel: "Fast-boot ML-DSA bundle (fake-image-bundle-mldsa.bin)",
  },
  "rom-only-fast": {
    rom: "fake-caliptra-rom.bin",
    fw: null,
    pqc: 1,
    romLabel: "Fast-boot ROM (fake-caliptra-rom.bin)",
    fwLabel: "None — ROM mailbox only (~420k cycles, ~2 min)",
  },
  "fast-lms": {
    rom: "fake-caliptra-rom.bin",
    fw: "fake-image-bundle-lms.bin",
    pqc: 3,
    romLabel: "Fast-boot ROM (fake-caliptra-rom.bin)",
    fwLabel: "Fast-boot LMS bundle (fake-image-bundle-lms.bin)",
  },
  "rom-only-full": {
    rom: "caliptra-rom-with-log.bin",
    fw: null,
    pqc: 1,
    romLabel: "Production ROM with KATs (caliptra-rom-with-log.bin)",
    fwLabel: "None — ROM mailbox only (~4.2M cycles)",
  },
  "full-mldsa": {
    rom: "caliptra-rom-with-log.bin",
    fw: "image-bundle-mldsa.bin",
    pqc: 1,
    romLabel: "Production ROM with KATs (caliptra-rom-with-log.bin)",
    fwLabel: "Production ML-DSA bundle (image-bundle-mldsa.bin)",
  },
  "full-lms": {
    rom: "caliptra-rom-with-log.bin",
    fw: "image-bundle-lms.bin",
    pqc: 3,
    romLabel: "Production ROM with KATs (caliptra-rom-with-log.bin)",
    fwLabel: "Production LMS bundle (image-bundle-lms.bin)",
  },
};

const ROM_BOOT_STATUS_NAMES = {
  0x0000: "Reset",
  0x0001: "IDevIdDecryptUds",
  0x0002: "IDevIdDecryptFe",
  0x0003: "IDevIdClearSecrets",
  0x0004: "IDevIdCdiDerivationComplete",
  0x0005: "IDevIdKeyPairDerivationComplete",
  0x0006: "IDevIdSubjIdSnGenerationComplete",
  0x0007: "IDevIdSubjKeyIdGenerationComplete",
  0x0041: "LDevIdCdiDerivationComplete",
  0x0042: "LDevIdKeyPairDerivationComplete",
  0x0043: "LDevIdSubjIdSnGenerationComplete",
  0x0044: "LDevIdSubjKeyIdGenerationComplete",
  0x0045: "LDevIdCertSigGenerationComplete",
  0x0046: "LDevIdDerivationComplete (Mailbox Ready)",
  0x0081: "FwDownloadComplete",
  0x0082: "ManifestLoaded (verifying sigs)",
  0x0083: "ImageVerified",
  0x0084: "DataVaultPopulated",
  0x0085: "PcrExtended (loading ICCM)",
  0x0086: "ImageLoaded (hashing ICCM)",
  0x0087: "FwProcessorComplete",
  0x0088: "KeyLadderComplete",
  0x0089: "FwLoadDone",
  0x00c1: "FmcAliasDeriveCdiComplete",
  0x00c2: "FmcAliasKeyPairDerivationComplete",
  0x00c3: "FmcAliasSubjIdSnGenerationComplete",
  0x00c4: "FmcAliasSubjKeyIdGenerationComplete",
  0x00c5: "FmcAliasCertSigGenerationComplete",
  0x00c6: "FmcAliasDerivationComplete",
  0x0101: "ColdBootMailboxReady",
  0x0140: "ColdResetComplete (Booting FMC)",
  0x0181: "CfiInitialized",
  0x0182: "KatStarted",
  0x0183: "KatComplete",
  0x0400: "FmcBootStarted",
  0x0401: "RtAliasDeriveCdiComplete",
  0x0402: "RtAliasKeyPairDerivationComplete",
  0x0404: "RtAliasCertSigGenerationComplete",
  0x0406: "RtAliasComplete (Runtime Ready)",
};

// DOM elements
const imagePresetSelect = document.getElementById("image-preset");
const romFileInput = document.getElementById("rom-file");
const romInfo = document.getElementById("rom-info");
const fwFileInput = document.getElementById("fw-file");
const fwInfo = document.getElementById("fw-info");
const btnClearFw = document.getElementById("btn-clear-fw");
const vendorPkInput = document.getElementById("vendor-pk");
const ownerPkInput = document.getElementById("owner-pk");
const lifecycleSelect = document.getElementById("lifecycle");
const debugIntentInput = document.getElementById("debug-intent");

// Fuse override fields
const fusePqcKeyType = document.getElementById("fuse-pqc-key-type");
const fuseEccRevocation = document.getElementById("fuse-ecc-revocation");
const fuseLmsRevocation = document.getElementById("fuse-lms-revocation");
const fuseMldsaRevocation = document.getElementById("fuse-mldsa-revocation");
const socSteppingId = document.getElementById("soc-stepping-id");
const socManifestMaxSvn = document.getElementById("soc-manifest-max-svn");
const socManifestSvn = document.getElementById("soc-manifest-svn");
const fwSvn = document.getElementById("fw-svn");
const manufDbgUnlockToken = document.getElementById("manuf-dbg-unlock-token");
const idevidCertAttr = document.getElementById("idevid-cert-attr");
const idevidManufHsmId = document.getElementById("idevid-manuf-hsm-id");
const antiRollbackDisable = document.getElementById("anti-rollback-disable");
const btnClearFuses = document.getElementById("btn-clear-fuses");

// Run controls & stats
const statusEl = document.getElementById("status");
const btnRun = document.getElementById("btn-run");
const btnStop = document.getElementById("btn-stop");
const btnReset = document.getElementById("btn-reset");
const pauseOnReadyInput = document.getElementById("pause-on-ready");
const startPausedInput = document.getElementById("start-paused");
const stepButtons = document.querySelectorAll(".step-btn");
const statsEl = document.getElementById("stats");

// Hardware signal elements
const sigRst = document.getElementById("sig-rst");
const sigFuses = document.getElementById("sig-fuses");
const sigMb = document.getElementById("sig-mb");
const sigRt = document.getElementById("sig-rt");
const sigMboxAvail = document.getElementById("sig-mbox-avail");
const sigEtrng = document.getElementById("sig-etrng");
const sigErr = document.getElementById("sig-err");
const hwPhaseEl = document.getElementById("hw-phase");
const hwBootStatusEl = document.getElementById("hw-boot-status");
const hwFlowStatusEl = document.getElementById("hw-flow-status");
const fwUploadWrap = document.getElementById("fw-upload-wrap");
const fwUploadLabel = document.getElementById("fw-upload-label");
const fwUploadFill = document.getElementById("fw-upload-fill");

// Output, Mailbox & Inspectors
const uartOutput = document.getElementById("uart-output");
const errorDecoder = document.getElementById("error-decoder");
const mboxReadyHint = document.getElementById("mbox-ready-hint");
const mboxCmdSelect = document.getElementById("mbox-cmd");
const btnMboxSend = document.getElementById("btn-mbox-send");
const mboxFormFields = document.getElementById("mbox-form-fields");
const mboxRawInput = document.getElementById("mbox-raw-input");
const mboxPayload = document.getElementById("mbox-payload");
const mboxParams = document.getElementById("mbox-params");
const mboxShaAlgo = document.getElementById("mbox-sha-algo");
const mboxShaInput = document.getElementById("mbox-sha-input");
const mboxResponse = document.getElementById("mbox-response");
const mboxDownloads = document.getElementById("mbox-downloads");
const keyvaultDisplay = document.getElementById("keyvault-display");
const fuseRegisters = document.getElementById("fuse-registers");
const logOutput = document.getElementById("log-output");

// Simulator & UI state
let simInitialized = false;
let simRunning = false;
let mailboxBusy = false;
let lastStatus = { initialized: false, phase: "UNINIT", total_cycles: 0 };
let lastErrorRegs = null;
let ERROR_CODES = {};
let defaultManufDbgTokenHashHex = "";
let autoPk = { vendor: "", owner: "" };

const binCache = new Map();
let activeRomBytes = null;
let activeFwBytes = null;
let customRomBytes = null;
let customFwBytes = null;
let presetLoadGeneration = 0;

// Timing / speed stats
let accumulatedRunMs = 0;
let speedSamples = [];

// ============================================================================
// Web Worker Bridge
// ============================================================================

const worker = new Worker("worker.js", { type: "module" });
let nextReqId = 1;
const pendingReqs = new Map();
let mboxProgressHandler = null;

let resolveWorkerReady;
let rejectWorkerReady;
const workerReady = new Promise((res, rej) => {
  resolveWorkerReady = res;
  rejectWorkerReady = rej;
});

worker.addEventListener("error", (ev) => {
  const errMsg = ev.message || "Web Worker runtime error";
  rejectWorkerReady(new Error(errMsg));
  setStatus(`Worker error: ${errMsg}`, "exited");
});

worker.addEventListener("message", (ev) => {
  const msg = ev.data;
  if (!msg) return;

  if (msg.event) {
    handleWorkerEvent(msg);
    return;
  }

  if (msg.reqId !== undefined && pendingReqs.has(msg.reqId)) {
    const { resolve, reject } = pendingReqs.get(msg.reqId);
    pendingReqs.delete(msg.reqId);
    if (msg.ok) {
      resolve(msg);
    } else {
      const err = new Error(msg.error || "Worker request failed");
      err.workerMsg = msg;
      reject(err);
    }
  }
});

function callWorker(type, payload = {}, transfer = []) {
  const reqId = nextReqId++;
  return new Promise((resolve, reject) => {
    pendingReqs.set(reqId, { resolve, reject });
    worker.postMessage({ reqId, type, ...payload }, transfer);
  });
}

function handleWorkerEvent(msg) {
  switch (msg.event) {
    case "ready":
      resolveWorkerReady();
      break;

    case "init_error":
      rejectWorkerReady(new Error(msg.error || "Failed to initialize WASM"));
      break;

    case "tick": {
      recordSlice(msg.cyclesRan, msg.elapsedMs);
      appendConsoleOutput(msg.uart, msg.log);
      if (msg.status) applyStatus(msg.status);
      if (msg.inspectors) applyInspectors(msg.inspectors);
      else if (msg.uart) updateErrorDecoder(lastErrorRegs, lastStatus);
      updateStatsDisplay(msg.status?.total_cycles ?? 0);
      break;
    }

    case "milestone_paused": {
      simRunning = false;
      recordSlice(msg.cyclesRan, msg.elapsedMs);
      appendConsoleOutput(msg.uart, msg.log);
      if (msg.status) applyStatus(msg.status);
      if (msg.inspectors) applyInspectors(msg.inspectors);
      updateStatsDisplay(msg.status?.total_cycles ?? 0);

      const label =
        msg.milestone === "RUNTIME_READY"
          ? "Ready (Runtime mailbox)"
          : "Ready (ROM mailbox)";
      setStatus(label, "passed");
      btnRun.disabled = false;
      btnStop.disabled = true;
      setStepButtonsDisabled(false);
      syncMailboxControls();
      break;
    }

    case "halted": {
      simRunning = false;
      recordSlice(msg.cyclesRan, msg.elapsedMs);
      appendConsoleOutput(msg.uart, msg.log);
      if (msg.status) applyStatus(msg.status);
      if (msg.inspectors) applyInspectors(msg.inspectors);
      updateStatsDisplay(msg.status?.total_cycles ?? 0);

      if (msg.status?.passed) {
        setStatus("Exited: passed", "passed");
      } else if (msg.status?.phase === "FATAL_ERROR") {
        setStatus("Halted: hardware/firmware fatal error", "exited");
      } else {
        setStatus("Exited: failed", "exited");
      }
      btnRun.disabled = true;
      btnStop.disabled = true;
      setStepButtonsDisabled(true);
      syncMailboxControls();
      break;
    }

    case "mbox_progress": {
      recordSlice(msg.cyclesRan, msg.elapsedMs);
      appendConsoleOutput(msg.uart, msg.log);
      if (msg.status) applyStatus(msg.status);
      updateStatsDisplay(msg.status?.total_cycles ?? 0);
      if (mboxProgressHandler) mboxProgressHandler(msg.cycles, msg.status);
      break;
    }
  }
}

// ============================================================================
// Metadata, Error Lookup & Default Token Hash
// ============================================================================

fetch("error-codes.json")
  .then((r) => (r.ok ? r.json() : {}))
  .then((j) => {
    ERROR_CODES = j;
  })
  .catch((e) => console.warn("Failed to load error-codes.json:", e));

const UPSTREAM_REPOS = {
  caliptra_rtl_rev: ["caliptra-rtl", "https://github.com/chipsalliance/caliptra-rtl/commit/"],
  caliptra_sw_rev: ["caliptra-sw", "https://github.com/chipsalliance/caliptra-sw/commit/"],
  calightra_rev: ["calightra", "https://github.com/swenson/calightra/commit/"],
};

fetch("build-info.json", { cache: "no-cache" })
  .then((r) => (r.ok ? r.json() : null))
  .then((info) => {
    if (!info) return;
    if (info.caliptra_release) {
      document.getElementById("caliptra-release-badge").textContent = `Caliptra ${info.caliptra_release}`;
    }
    const el = document.getElementById("build-info");
    const parts = [];
    if (info.engine) parts.push(document.createTextNode(info.engine));
    if (info.rom_version) parts.push(document.createTextNode(`ROM ${info.rom_version}`));
    if (info.fmc_version) parts.push(document.createTextNode(`FMC ${info.fmc_version}`));
    if (info.runtime_version) parts.push(document.createTextNode(`RT ${info.runtime_version}`));
    for (const [key, [name, base]] of Object.entries(UPSTREAM_REPOS)) {
      const rev = info[key];
      if (!rev || !/^[0-9a-f]{7,40}$/i.test(rev)) continue;
      const a = document.createElement("a");
      a.href = base + rev;
      a.target = "_blank";
      a.rel = "noopener";
      a.textContent = `${name}@${rev.slice(0, 8)}`;
      parts.push(a);
    }
    el.replaceChildren();
    parts.forEach((node, i) => {
      if (i > 0) el.appendChild(document.createTextNode(" · "));
      el.appendChild(node);
    });
  })
  .catch((e) => console.warn("Failed to load build-info.json:", e));

async function computeDefaultManufTokenHash() {
  try {
    if (!crypto?.subtle) return;
    const raw = parseHexPayload(DEFAULT_MANUF_DBG_TOKEN_HEX);
    const digest = new Uint8Array(await crypto.subtle.digest("SHA-512", raw));
    defaultManufDbgTokenHashHex = toHex(digest);
  } catch (e) {
    console.warn("Could not precompute default manuf debug token hash:", e);
  }
}

// ============================================================================
// Live Hardware Signals, Console & Inspectors
// ============================================================================

function setStatus(text, className) {
  statusEl.textContent = text;
  statusEl.className = "status" + (className ? " " + className : "");
}

function setStepButtonsDisabled(disabled) {
  for (const b of stepButtons) b.disabled = disabled;
}

function setConfigDisabled(disabled) {
  imagePresetSelect.disabled = disabled;
  romFileInput.disabled = disabled;
  fwFileInput.disabled = disabled;
  btnClearFw.disabled = disabled;
  vendorPkInput.disabled = disabled;
  ownerPkInput.disabled = disabled;
  lifecycleSelect.disabled = disabled;
  debugIntentInput.disabled = disabled;
  fusePqcKeyType.disabled = disabled;
  fuseEccRevocation.disabled = disabled;
  fuseLmsRevocation.disabled = disabled;
  fuseMldsaRevocation.disabled = disabled;
  socSteppingId.disabled = disabled;
  socManifestMaxSvn.disabled = disabled;
  socManifestSvn.disabled = disabled;
  fwSvn.disabled = disabled;
  manufDbgUnlockToken.disabled = disabled;
  idevidCertAttr.disabled = disabled;
  idevidManufHsmId.disabled = disabled;
  antiRollbackDisable.disabled = disabled;
  btnClearFuses.disabled = disabled;
}

function recordSlice(cyclesRan, elapsedMs) {
  if (cyclesRan > 0 && elapsedMs > 0) {
    accumulatedRunMs += elapsedMs;
    speedSamples.push({ cycles: cyclesRan, ms: elapsedMs });
    if (speedSamples.length > 16) speedSamples.shift();
  }
}

function resetStats() {
  accumulatedRunMs = 0;
  speedSamples = [];
  statsEl.textContent = "";
}

function updateStatsDisplay(totalCycles, manualLabel = null) {
  if (manualLabel) {
    statsEl.textContent = `${Number(totalCycles).toLocaleString()} cycles · ${manualLabel}`;
    return;
  }
  const winCycles = speedSamples.reduce((acc, s) => acc + s.cycles, 0);
  const winMs = speedSamples.reduce((acc, s) => acc + s.ms, 0);
  const hz = winMs > 0 ? (winCycles * 1000) / winMs : 0;
  const rateStr =
    hz >= 1_000_000
      ? `${(hz / 1_000_000).toFixed(2)} MHz`
      : `${(hz / 1_000).toFixed(2)} kHz`;
  const secs = (accumulatedRunMs / 1000).toFixed(1);
  statsEl.textContent = `${Number(totalCycles).toLocaleString()} cycles · ${secs} s · ${rateStr}`;
}

function appendConsoleOutput(uart, log) {
  if (uart) {
    uartOutput.textContent += uart;
    uartOutput.scrollTop = uartOutput.scrollHeight;
  }
  if (log) {
    logOutput.textContent += log;
    logOutput.scrollTop = logOutput.scrollHeight;
  }
}

function updateSigPill(el, name, bitVal, activeClass) {
  const b = bitVal ? 1 : 0;
  el.textContent = `${name}=${b}`;
  el.className = b ? `sig ${activeClass}` : "sig";
}

function syncMailboxControls() {
  const s = lastStatus;
  const ready =
    Boolean(s?.initialized) &&
    (s.phase === "ROM_IDLE" || s.phase === "RUNTIME_READY") &&
    !mailboxBusy;
  btnMboxSend.disabled = !ready;

  if (s?.phase === "RUNTIME_READY") {
    mboxReadyHint.textContent = "Runtime mailbox ready (ready_for_runtime=1)";
  } else if (s?.phase === "ROM_IDLE") {
    mboxReadyHint.textContent = "ROM mailbox ready (ready_for_mb_processing=1)";
  } else {
    mboxReadyHint.innerHTML =
      "Available once <code>ready_for_mb_processing</code> (ROM-only) or <code>ready_for_runtime</code> asserts";
  }
}

function applyStatus(s) {
  lastStatus = s;
  if (!s || !s.initialized) {
    updateSigPill(sigRst, "cptra_rst_b", 0, "on");
    updateSigPill(sigFuses, "ready_for_fuses", 0, "on");
    updateSigPill(sigMb, "ready_for_mb_processing", 0, "on");
    updateSigPill(sigRt, "ready_for_runtime", 0, "on");
    updateSigPill(sigMboxAvail, "mailbox_data_avail", 0, "warn");
    updateSigPill(sigEtrng, "etrng_req", 0, "warn");
    updateSigPill(sigErr, "cptra_error", 0, "err");
    hwPhaseEl.textContent = "UNINIT";
    hwBootStatusEl.textContent = "0x00000000";
    hwFlowStatusEl.textContent = "0x00000000";
    fwUploadWrap.hidden = true;
    syncMailboxControls();
    return;
  }

  updateSigPill(sigRst, "cptra_rst_b", s.cptra_rst_b, "on");
  updateSigPill(sigFuses, "ready_for_fuses", s.ready_for_fuses, "on");
  updateSigPill(sigMb, "ready_for_mb_processing", s.ready_for_mb_processing, "on");
  updateSigPill(sigRt, "ready_for_runtime", s.ready_for_runtime, "on");
  updateSigPill(sigMboxAvail, "mailbox_data_avail", s.mailbox_data_avail, "warn");
  updateSigPill(sigEtrng, "etrng_req", s.etrng_req, "warn");
  const hasErrWire = Boolean(s.cptra_error_fatal || s.cptra_error_non_fatal);
  updateSigPill(sigErr, "cptra_error", hasErrWire ? 1 : 0, "err");

  hwPhaseEl.textContent = s.phase || "UNINIT";

  const bootVal = parseInt(s.boot_status || "0", 16) >>> 0;
  const bootName = ROM_BOOT_STATUS_NAMES[bootVal];
  hwBootStatusEl.textContent = bootName
    ? `${s.boot_status} (${bootName})`
    : s.boot_status || "0x00000000";
  hwFlowStatusEl.textContent = s.flow_status || "0x00000000";

  const showUpload =
    s.fw_total_bytes > 0 &&
    s.phase !== "UNINIT" &&
    s.phase !== "RESET" &&
    s.phase !== "FUSES" &&
    s.phase !== "ROM_BOOT";
  fwUploadWrap.hidden = !showUpload;
  if (showUpload) {
    const pct = Math.min(100, (s.fw_upload_bytes / s.fw_total_bytes) * 100);
    const doneKb = (s.fw_upload_bytes / 1024).toFixed(1);
    const totalKb = (s.fw_total_bytes / 1024).toFixed(1);
    fwUploadLabel.textContent = `${doneKb} / ${totalKb} KB (${pct.toFixed(0)}%)`;
    fwUploadFill.style.width = `${pct.toFixed(1)}%`;
  }

  syncMailboxControls();
}

function applyInspectors(inspectors) {
  if (!inspectors) return;
  if (inspectors.errors) {
    lastErrorRegs = inspectors.errors;
    updateErrorDecoder(inspectors.errors, lastStatus);
  }
  if (inspectors.keyvault) {
    renderKeyvault(inspectors.keyvault);
  }
  if (inspectors.fuses) {
    renderFuses(inspectors.fuses);
  }
}

function lookupError(hex) {
  return ERROR_CODES[hex.toLowerCase()] || null;
}

function formatErrorEntry(label, val) {
  if (!val || val === "0x00000000" || val === 0) return null;
  const hexStr =
    typeof val === "number"
      ? "0x" + (val >>> 0).toString(16).padStart(8, "0")
      : val.toLowerCase();
  const info = lookupError(hexStr);
  if (info) {
    return `${label}: ${hexStr}\n  ${info.name}\n  ${info.desc}`;
  }
  return `${label}: ${hexStr}\n  (unknown error code)`;
}

function decodeHwFatalBits(hex) {
  const v = parseInt(hex || "0", 16) >>> 0;
  if (!v) return null;
  const names = [];
  if (v & (1 << 0)) names.push("iccm_ecc_unc");
  if (v & (1 << 1)) names.push("dccm_ecc_unc");
  if (v & (1 << 2)) names.push("nmi_pin");
  if (v & (1 << 3)) names.push("crypto_err");
  return `Caliptra hw_error_fatal: ${hex}\n  [${names.join(", ") || "raw bits"}]`;
}

function decodeHwNonFatalBits(hex) {
  const v = parseInt(hex || "0", 16) >>> 0;
  if (!v) return null;
  const names = [];
  if (v & (1 << 0)) names.push("mbox_prot_no_lock");
  if (v & (1 << 1)) names.push("mbox_prot_ooo");
  if (v & (1 << 2)) names.push("mbox_ecc_unc");
  return `Caliptra hw_error_non_fatal: ${hex}\n  [${names.join(", ") || "raw bits"}]`;
}

function updateErrorDecoder(regs, statusObj) {
  if (!simInitialized) {
    errorDecoder.hidden = true;
    errorDecoder.textContent = "";
    return;
  }

  const sections = [];
  const cptraEntries = [];

  if (statusObj?.boot_error) {
    cptraEntries.push(`Boot flow error:\n  ${statusObj.boot_error}`);
  }

  if (regs) {
    const hw1 = decodeHwFatalBits(regs.cptra_hw_error_fatal);
    if (hw1) cptraEntries.push(hw1);
    const hw2 = decodeHwNonFatalBits(regs.cptra_hw_error_non_fatal);
    if (hw2) cptraEntries.push(hw2);

    const fw1 = formatErrorEntry("Caliptra fw_error_fatal", regs.cptra_fw_error_fatal);
    if (fw1) cptraEntries.push(fw1);
    const fw2 = formatErrorEntry("Caliptra fw_error_non_fatal", regs.cptra_fw_error_non_fatal);
    if (fw2) cptraEntries.push(fw2);

    if (Array.isArray(regs.cptra_fw_extended_error_info)) {
      const ext = regs.cptra_fw_extended_error_info;
      if (ext.some((v) => v !== "0x00000000")) {
        cptraEntries.push("Caliptra extended_error_info:\n  " + ext.join(", "));
      }
    }
  }

  if (cptraEntries.length > 0) {
    sections.push("=== CALIPTRA 2.1 CORE ===\n" + cptraEntries.join("\n\n"));
  }

  // UART-detected fatal errors
  const uartText = uartOutput.textContent || "";
  const fatalRe = /Fatal Error:\s*(0x[0-9a-fA-F]{1,8})/g;
  const seen = new Set();
  const uartEntries = [];
  let match;
  while ((match = fatalRe.exec(uartText)) !== null) {
    const hex = "0x" + (parseInt(match[1], 16) >>> 0).toString(16).padStart(8, "0");
    if (seen.has(hex)) continue;
    seen.add(hex);
    const info = lookupError(hex);
    uartEntries.push(
      info
        ? `UART Fatal: ${hex}\n  ${info.name}\n  ${info.desc}`
        : `UART Fatal: ${hex}\n  (unknown error code)`
    );
  }
  if (uartEntries.length > 0) {
    sections.push("=== UART DETECTED ===\n" + uartEntries.join("\n\n"));
  }

  if (sections.length === 0) {
    errorDecoder.hidden = true;
    errorDecoder.textContent = "";
  } else {
    errorDecoder.hidden = false;
    errorDecoder.textContent = "Hardware & firmware error registers\n\n" + sections.join("\n\n");
  }
}

// Caliptra 2.1 KV_CONTROL layout (from wasm_peek_kv_ctrl in calightra_verilated_wasm.sv):
//   bit 0: lock_wr, bit 1: lock_use, bit 2: clear
//   bits [17:9]: dest_valid (9 bits)
//   bits [21:18]: last_dword (4 bits)
const KV_USAGE_NAMES_2_1 = [
  "hmac_key",
  "hmac_block",
  "mldsa_seed",
  "ecc_pkey",
  "ecc_seed",
  "aes_key",
  "mlkem_seed",
  "mlkem_msg",
  "dma_data",
];

function decodeKeyControl(ctrlHex) {
  const v = parseInt(ctrlHex, 16) >>> 0;
  const writeLock = (v >>> 0) & 1;
  const useLock = (v >>> 1) & 1;
  const clear = (v >>> 2) & 1;
  const usage = (v >>> 9) & 0x1ff;
  const lastDword = (v >>> 18) & 0xf;

  const usageList = [];
  for (let i = 0; i < KV_USAGE_NAMES_2_1.length; i++) {
    if (usage & (1 << i)) usageList.push(KV_USAGE_NAMES_2_1[i]);
  }
  const flags = [];
  if (writeLock) flags.push("WRITE_LOCK");
  if (useLock) flags.push("USE_LOCK");
  if (clear) flags.push("CLEAR");

  return {
    lastDword,
    flagsStr: flags.length > 0 ? flags.join("|") : "-",
    usageStr: usageList.length > 0 ? usageList.join(",") : "-",
  };
}

function isAllZero(hex) {
  return /^0+$/.test(hex);
}

function groupHexChunks(s) {
  return s.match(/.{1,16}/g)?.join(" ") || "";
}

function formatKeyHex(hex, lastDword) {
  const activeBytes = Math.min(64, (lastDword + 1) * 4);
  const active = hex.slice(0, activeBytes * 2);
  const inactive = hex.slice(activeBytes * 2);
  if (inactive.length === 0 || isAllZero(inactive)) {
    return groupHexChunks(active);
  }
  return groupHexChunks(active) + " │ " + groupHexChunks(inactive);
}

function renderKeyvault(snap) {
  if (!snap || !Array.isArray(snap.keys) || snap.keys.length === 0) {
    keyvaultDisplay.textContent =
      "Start the simulator to inspect the hardware key vault and PCR vault.";
    return;
  }
  const keyCount = snap.keys.length;
  const keyBytes = snap.keys[0].length / 2;
  let text = `=== KEYS (${keyCount} × ${keyBytes} bytes) ===\n`;
  for (let i = 0; i < keyCount; i++) {
    const ctrl = decodeKeyControl(snap.key_control[i]);
    const keyHex = snap.keys[i];
    const empty = isAllZero(keyHex) && ctrl.usageStr === "-";
    const tag = empty ? "(empty)" : formatKeyHex(keyHex, ctrl.lastDword);
    text += `Key ${String(i).padStart(2)}: [ctrl=${snap.key_control[i]} flags=${ctrl.flagsStr} usage=${ctrl.usageStr} last_dword=${ctrl.lastDword}]\n`;
    text += `         ${tag}\n`;
  }
  text += "\n=== PCRs (32 × 48 bytes) ===\n";
  for (let i = 0; i < snap.pcrs.length; i++) {
    const ctrl = snap.pcr_control[i];
    const ctrlV = parseInt(ctrl, 16) >>> 0;
    const flags = [];
    if (ctrlV & 1) flags.push("LOCK");
    if (ctrlV & 2) flags.push("CLEAR");
    const flagsStr = flags.length > 0 ? flags.join("|") : "-";
    const pcrHex = snap.pcrs[i];
    const empty = isAllZero(pcrHex);
    text += `PCR ${String(i).padStart(2)}: [ctrl=${ctrl} ${flagsStr}] ${empty ? "(empty)" : groupHexChunks(pcrHex)}\n`;
  }
  keyvaultDisplay.textContent = text;
}

function renderFuses(regs) {
  if (!regs || Object.keys(regs).length === 0) {
    fuseRegisters.textContent = "Start the simulator to read soc_ifc_reg fuse registers.";
    return;
  }
  let text = "";
  for (const [name, val] of Object.entries(regs)) {
    text += `${name}: ${val}\n`;
  }
  fuseRegisters.textContent = text;
}

// ============================================================================
// Presets, Binary Loading & Fuse Overrides
// ============================================================================

function fetchBinaryCached(filename) {
  if (!binCache.has(filename)) {
    const p = fetch(filename).then(async (resp) => {
      if (!resp.ok) throw new Error(`HTTP ${resp.status} fetching ${filename}`);
      return new Uint8Array(await resp.arrayBuffer());
    });
    binCache.set(filename, p);
  }
  return binCache.get(filename);
}

async function autoFillPkHashes(fwU8) {
  if (!fwU8 || fwU8.length === 0) return;
  await workerReady;
  const copyBuf = fwU8.slice().buffer;
  const res = await callWorker("fwPkHashes", { fw: copyBuf }, [copyBuf]);
  if (!res.hashesJson) return;
  const h = JSON.parse(res.hashesJson);
  if (vendorPkInput.value === "" || vendorPkInput.value === autoPk.vendor) {
    vendorPkInput.value = h.vendor_pk_hash;
  }
  if (ownerPkInput.value === "" || ownerPkInput.value === autoPk.owner) {
    ownerPkInput.value = h.owner_pk_hash;
  }
  autoPk = { vendor: h.vendor_pk_hash, owner: h.owner_pk_hash };
}

async function loadSelectedPreset(presetKey) {
  const gen = ++presetLoadGeneration;
  if (presetKey === "custom") {
    activeRomBytes = customRomBytes;
    activeFwBytes = customFwBytes;
    romInfo.textContent = customRomBytes
      ? `Custom ROM (${(customRomBytes.length / 1024).toFixed(1)} KB)`
      : "Choose a custom Caliptra ROM binary (.bin)";
    fwInfo.textContent = customFwBytes
      ? `Custom firmware (${(customFwBytes.length / 1024).toFixed(1)} KB)`
      : "None — ROM mailbox only (or choose a bundle)";
    return;
  }

  const preset = PRESETS[presetKey];
  if (!preset) return;

  romInfo.textContent = `Loading ${preset.rom}…`;
  fwInfo.textContent = preset.fw ? `Loading ${preset.fw}…` : preset.fwLabel;

  const [romBytes, fwBytes] = await Promise.all([
    fetchBinaryCached(preset.rom),
    preset.fw ? fetchBinaryCached(preset.fw) : Promise.resolve(null),
  ]);
  if (gen !== presetLoadGeneration) return;

  activeRomBytes = romBytes;
  activeFwBytes = fwBytes;
  romInfo.textContent = `${preset.romLabel} (${(romBytes.length / 1024).toFixed(0)} KB)`;
  fwInfo.textContent = fwBytes
    ? `${preset.fwLabel} (${(fwBytes.length / 1024).toFixed(1)} KB)`
    : preset.fwLabel;

  if (fwBytes) {
    await autoFillPkHashes(fwBytes);
  }
}

imagePresetSelect.addEventListener("change", () => {
  loadSelectedPreset(imagePresetSelect.value).catch((err) => {
    setStatus(`Failed to load preset: ${err.message}`, "exited");
  });
});

romFileInput.addEventListener("change", (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = () => {
    customRomBytes = new Uint8Array(reader.result);
    activeRomBytes = customRomBytes;
    imagePresetSelect.value = "custom";
    romInfo.textContent = `${file.name} (${(customRomBytes.length / 1024).toFixed(1)} KB)`;
  };
  reader.readAsArrayBuffer(file);
});

fwFileInput.addEventListener("change", (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = async () => {
    customFwBytes = new Uint8Array(reader.result);
    if (!customRomBytes && activeRomBytes) {
      customRomBytes = activeRomBytes;
    }
    activeFwBytes = customFwBytes;
    imagePresetSelect.value = "custom";
    fwInfo.textContent = `${file.name} (${(customFwBytes.length / 1024).toFixed(1)} KB)`;
    try {
      await autoFillPkHashes(customFwBytes);
    } catch (err) {
      console.warn("Could not extract PK hashes from custom FW:", err);
    }
  };
  reader.readAsArrayBuffer(file);
});

btnClearFw.addEventListener("click", () => {
  fwFileInput.value = "";
  const cur = imagePresetSelect.value;
  if (cur.startsWith("fast-") || cur === "rom-only-fast") {
    imagePresetSelect.value = "rom-only-fast";
    loadSelectedPreset("rom-only-fast");
  } else if (cur.startsWith("full-") || cur === "rom-only-full") {
    imagePresetSelect.value = "rom-only-full";
    loadSelectedPreset("rom-only-full");
  } else {
    customFwBytes = null;
    activeFwBytes = null;
    fwInfo.textContent = "None — ROM mailbox only";
  }
});

function parseInt32Maybe(s) {
  s = (s || "").trim();
  if (!s) return null;
  const lower = s.toLowerCase();
  const v = lower.startsWith("0x") ? parseInt(lower.slice(2), 16) : parseInt(s, 10);
  return Number.isFinite(v) ? v >>> 0 : null;
}

function parseU32Array4(s) {
  s = (s || "").trim();
  if (!s) return null;
  const parts = s.split(/[\s,]+/).filter((p) => p.length > 0);
  if (parts.length !== 4) return null;
  const out = parts.map(parseInt32Maybe);
  if (out.some((v) => v === null)) return null;
  return out;
}

function buildFuseConfigJson() {
  const cfg = {};
  if (fusePqcKeyType.value !== "") {
    const v = parseInt(fusePqcKeyType.value, 10);
    if (Number.isFinite(v)) cfg.fuse_pqc_key_type = v;
  } else {
    const presetPqc = PRESETS[imagePresetSelect.value]?.pqc;
    cfg.fuse_pqc_key_type = presetPqc !== undefined ? presetPqc : 1;
  }

  const ecc = parseInt32Maybe(fuseEccRevocation.value);
  if (ecc !== null) cfg.fuse_ecc_revocation = ecc;
  const lms = parseInt32Maybe(fuseLmsRevocation.value);
  if (lms !== null) cfg.fuse_lms_revocation = lms;
  const mldsa = parseInt32Maybe(fuseMldsaRevocation.value);
  if (mldsa !== null) cfg.fuse_mldsa_revocation = mldsa;
  if (antiRollbackDisable.checked) cfg.anti_rollback_disable = true;

  const steppingId = parseInt32Maybe(socSteppingId.value);
  if (steppingId !== null) cfg.soc_stepping_id = steppingId;
  const maxSvn = parseInt32Maybe(socManifestMaxSvn.value);
  if (maxSvn !== null) cfg.soc_manifest_max_svn = maxSvn;
  const socSvn = parseU32Array4(socManifestSvn.value);
  if (socSvn) cfg.soc_manifest_svn = socSvn;
  const fwSvnArr = parseU32Array4(fwSvn.value);
  if (fwSvnArr) cfg.fw_svn = fwSvnArr;

  const manufTok = manufDbgUnlockToken.value.trim();
  if (manufTok) {
    cfg.manuf_dbg_unlock_token = manufTok;
  } else if (defaultManufDbgTokenHashHex) {
    cfg.manuf_dbg_unlock_token = defaultManufDbgTokenHashHex;
  }

  const certAttr = idevidCertAttr.value.trim();
  if (certAttr) cfg.idevid_cert_attr = certAttr;
  const hsmId = idevidManufHsmId.value.trim();
  if (hsmId) cfg.idevid_manuf_hsm_id = hsmId;

  return JSON.stringify(cfg);
}

function resetFuseFields() {
  fusePqcKeyType.value = "";
  fuseEccRevocation.value = "";
  fuseLmsRevocation.value = "";
  fuseMldsaRevocation.value = "";
  socSteppingId.value = "";
  socManifestMaxSvn.value = "";
  socManifestSvn.value = "";
  fwSvn.value = "";
  manufDbgUnlockToken.value = "";
  idevidCertAttr.value = "";
  idevidManufHsmId.value = "";
  antiRollbackDisable.checked = false;
}
btnClearFuses.addEventListener("click", resetFuseFields);
window.resetFuseFields = resetFuseFields;

// ============================================================================
// Run, Pause, Step & Reset Controls
// ============================================================================

async function ensureSimInitialized() {
  if (simInitialized) return true;

  if (!activeRomBytes && imagePresetSelect.value !== "custom") {
    await loadSelectedPreset(imagePresetSelect.value);
  }
  if (!activeRomBytes) {
    setStatus("No Caliptra ROM image selected.", "stopped");
    return false;
  }

  setStatus("Initializing Verilated RTL…", "");
  uartOutput.textContent = "";
  logOutput.textContent = "";
  errorDecoder.hidden = true;
  errorDecoder.textContent = "";
  resetStats();

  const romCopy = activeRomBytes.slice().buffer;
  const fwCopy = activeFwBytes ? activeFwBytes.slice().buffer : null;
  const transfers = fwCopy ? [romCopy, fwCopy] : [romCopy];

  try {
    const res = await callWorker(
      "init",
      {
        rom: romCopy,
        fw: fwCopy,
        vendorPk: vendorPkInput.value.trim(),
        ownerPk: ownerPkInput.value.trim(),
        lifecycle: lifecycleSelect.value,
        debugIntent: debugIntentInput.checked,
        fusesJson: buildFuseConfigJson(),
      },
      transfers
    );

    simInitialized = true;
    appendConsoleOutput(res.uart, res.log);
    applyStatus(res.status);
    applyInspectors(res.inspectors);
    setConfigDisabled(true);
    return true;
  } catch (err) {
    setStatus(`RTL init failed: ${err.message}`, "exited");
    return false;
  }
}

btnRun.addEventListener("click", async () => {
  if (simRunning || mailboxBusy) return;
  btnRun.disabled = true;

  const firstInit = !simInitialized;
  const ok = await ensureSimInitialized();
  if (!ok) {
    btnRun.disabled = false;
    return;
  }

  if (firstInit && startPausedInput.checked) {
    setStatus("Paused at cycle 0 (in reset)", "stopped");
    btnRun.disabled = false;
    btnStop.disabled = true;
    setStepButtonsDisabled(false);
    updateStatsDisplay(0, "cycle 0 (ready to step)");
    return;
  }

  simRunning = true;
  setStatus("Running RTL clock", "running");
  btnRun.disabled = true;
  btnStop.disabled = false;
  setStepButtonsDisabled(true);

  try {
    await callWorker("run", { pauseOnReady: pauseOnReadyInput.checked });
  } catch (err) {
    simRunning = false;
    setStatus(`Run error: ${err.message}`, "exited");
    btnRun.disabled = false;
    btnStop.disabled = true;
  }
});

btnStop.addEventListener("click", async () => {
  if (!simRunning) return;
  btnStop.disabled = true;
  try {
    const res = await callWorker("pause");
    simRunning = false;
    appendConsoleOutput(res.uart, res.log);
    applyStatus(res.status);
    applyInspectors(res.inspectors);
    setStatus("Paused", "stopped");
    btnRun.disabled = false;
    setStepButtonsDisabled(false);
    syncMailboxControls();
  } catch (err) {
    setStatus(`Pause failed: ${err.message}`, "exited");
  }
});

for (const btn of stepButtons) {
  btn.addEventListener("click", async () => {
    if (!simInitialized || simRunning || mailboxBusy) return;
    const cycles = parseInt(btn.dataset.step, 10) || 1;
    setStepButtonsDisabled(true);
    btnRun.disabled = true;
    setStatus(`Stepping +${cycles.toLocaleString()} cycles…`, "running");
    try {
      const res = await callWorker("step", { cycles });
      appendConsoleOutput(res.uart, res.log);
      applyStatus(res.status);
      applyInspectors(res.inspectors);
      updateStatsDisplay(res.status.total_cycles, "stepping manually");

      if (!res.stillRunning) {
        if (res.status.passed) {
          setStatus("Exited: passed", "passed");
        } else {
          setStatus("Halted", "exited");
        }
        btnRun.disabled = true;
        setStepButtonsDisabled(true);
      } else {
        setStatus("Paused", "stopped");
        btnRun.disabled = false;
        setStepButtonsDisabled(false);
      }
      syncMailboxControls();
    } catch (err) {
      setStatus(`Step failed: ${err.message}`, "exited");
      btnRun.disabled = false;
      setStepButtonsDisabled(false);
    }
  });
}

btnReset.addEventListener("click", async () => {
  btnReset.disabled = true;
  try {
    await callWorker("destroy");
  } catch (e) {
    console.warn("Destroy warning:", e);
  }
  simInitialized = false;
  simRunning = false;
  mailboxBusy = false;
  lastErrorRegs = null;
  applyStatus({ initialized: false, phase: "UNINIT", total_cycles: 0 });
  resetStats();

  uartOutput.textContent = "";
  logOutput.textContent = "";
  mboxResponse.textContent = "";
  showDownloads(mboxDownloads, []);
  errorDecoder.hidden = true;
  errorDecoder.textContent = "";
  keyvaultDisplay.textContent =
    "Start the simulator to inspect the hardware key vault and PCR vault.";
  fuseRegisters.textContent = "Start the simulator to read soc_ifc_reg fuse registers.";

  setConfigDisabled(false);
  btnRun.disabled = false;
  btnStop.disabled = true;
  btnReset.disabled = false;
  setStepButtonsDisabled(true);
  syncMailboxControls();
  setStatus("Ready", "");
});

// ============================================================================
// Caliptra 2.1 Mailbox Commands, Schemas & Decoders
// ============================================================================

const COMMAND_INFO = {
  // FIPS Commands
  VERSION: { id: 0x46505652, hasInput: false },
  SELF_TEST_START: { id: 0x46504c54, hasInput: false },
  SELF_TEST_GET_RESULTS: { id: 0x46504c67, hasInput: false },
  SHUTDOWN: { id: 0x46505344, hasInput: false },
  // Info / Status
  FW_INFO: { id: 0x494e464f, hasInput: false },
  CAPABILITIES: { id: 0x43415053, hasInput: false },
  GET_IMAGE_INFO: { id: 0x494d4530, hasInput: true },
  GET_MCU_FW_SIZE: { id: 0x474d4653, hasInput: false },
  // Certificate Commands (ECC384)
  GET_IDEV_ECC384_CERT: { id: 0x49444543, hasInput: true },
  GET_IDEV_ECC384_INFO: { id: 0x49444549, hasInput: false },
  POPULATE_IDEV_ECC384_CERT: { id: 0x49444550, hasInput: true },
  GET_LDEV_ECC384_CERT: { id: 0x4c444556, hasInput: false },
  GET_FMC_ALIAS_ECC384_CERT: { id: 0x43455246, hasInput: false },
  GET_RT_ALIAS_ECC384_CERT: { id: 0x43455252, hasInput: false },
  GET_IDEV_ECC384_CSR: { id: 0x49444352, hasInput: false },
  GET_FMC_ALIAS_ECC384_CSR: { id: 0x464d4352, hasInput: false },
  GET_ATTESTED_ECC384_CSR: { id: 0x41454352, hasInput: true },
  // Certificate Commands (MLDSA87)
  GET_IDEV_MLDSA87_CERT: { id: 0x49444d43, hasInput: true },
  GET_IDEV_MLDSA87_INFO: { id: 0x49444d49, hasInput: false },
  POPULATE_IDEV_MLDSA87_CERT: { id: 0x49444d50, hasInput: true },
  GET_LDEV_MLDSA87_CERT: { id: 0x4c444d43, hasInput: false },
  GET_FMC_ALIAS_MLDSA87_CERT: { id: 0x434d4346, hasInput: false },
  GET_RT_ALIAS_MLDSA87_CERT: { id: 0x434d4352, hasInput: false },
  GET_IDEV_MLDSA87_CSR: { id: 0x49444d52, hasInput: false },
  GET_FMC_ALIAS_MLDSA87_CSR: { id: 0x464d4452, hasInput: false },
  GET_ATTESTED_MLDSA87_CSR: { id: 0x414d4352, hasInput: true },
  // Signature Verification
  ECDSA384_SIGNATURE_VERIFY: { id: 0x45435632, hasInput: true },
  LMS_SIGNATURE_VERIFY: { id: 0x4c4d5632, hasInput: true },
  MLDSA87_SIGNATURE_VERIFY: { id: 0x4d4c5632, hasInput: true },
  // Measurement / DPE
  STASH_MEASUREMENT: { id: 0x4d454153, hasInput: true },
  INVOKE_DPE_ECC384: { id: 0x44504543, hasInput: true },
  INVOKE_DPE_MLDSA87: { id: 0x4450454d, hasInput: true },
  DPE_TAG_TCI: { id: 0x54514754, hasInput: true },
  DPE_GET_TAGGED_TCI: { id: 0x47544744, hasInput: true },
  REALLOCATE_DPE_CONTEXT_LIMITS: { id: 0x52435458, hasInput: true },
  // PCR
  INCREMENT_PCR_RESET_COUNTER: { id: 0x50435252, hasInput: true },
  QUOTE_PCRS_ECC384: { id: 0x50435251, hasInput: true },
  QUOTE_PCRS_MLDSA87: { id: 0x5043524d, hasInput: true },
  EXTEND_PCR: { id: 0x50435245, hasInput: true },
  GET_PCR_LOG: { id: 0x504c4f47, hasInput: false },
  // Attestation
  DISABLE_ATTESTATION: { id: 0x4453424c, hasInput: false },
  ADD_SUBJECT_ALT_NAME: { id: 0x414c544e, hasInput: true },
  CERTIFY_KEY_EXTENDED_ECC384: { id: 0x434b4558, hasInput: true },
  CERTIFY_KEY_EXTENDED_MLDSA87: { id: 0x434b584d, hasInput: true },
  // Firmware
  ACTIVATE_FIRMWARE: { id: 0x41435446, hasInput: true },
  FIRMWARE_LOAD: { id: 0x46574c44, hasInput: true },
  FIRMWARE_VERIFY: { id: 0x46575652, hasInput: false },
  // Auth Manifest
  SET_AUTH_MANIFEST: { id: 0x41544d4e, hasInput: true },
  VERIFY_AUTH_MANIFEST: { id: 0x4154564d, hasInput: true },
  AUTHORIZE_AND_STASH: { id: 0x41545348, hasInput: true },
  // Recovery
  RI_DOWNLOAD_FIRMWARE: { id: 0x52494644, hasInput: true },
  RI_DOWNLOAD_ENCRYPTED_FIRMWARE: { id: 0x52494645, hasInput: true },
  // Key Management
  SIGN_WITH_EXPORTED_ECDSA: { id: 0x53574545, hasInput: true },
  SIGN_WITH_EXPORTED_MLDSA: { id: 0x53574d4c, hasInput: true },
  REVOKE_EXPORTED_CDI_HANDLE: { id: 0x52564348, hasInput: true },
  INSTALL_OWNER_PK_HASH: { id: 0x4f574e50, hasInput: true },
  ZEROIZE_UDS_FE: { id: 0x5a455546, hasInput: true },
  FE_PROG: { id: 0x46455052, hasInput: true },
  // Crypto Manager (CM)
  CM_STATUS: { id: 0x434d5354, hasInput: false },
  CM_IMPORT: { id: 0x434d494d, hasInput: true },
  CM_DELETE: { id: 0x434d444c, hasInput: true },
  CM_CLEAR: { id: 0x434d434c, hasInput: false },
  CM_SHA: { id: 0x434d5348, hasInput: true },
  CM_SHA_INIT: { id: 0x434d5349, hasInput: true },
  CM_SHA_UPDATE: { id: 0x434d5355, hasInput: true },
  CM_SHA_FINAL: { id: 0x434d5346, hasInput: true },
  CM_SHAKE256_INIT: { id: 0x434d5849, hasInput: true },
  CM_SHAKE256_UPDATE: { id: 0x434d5855, hasInput: true },
  CM_SHAKE256_FINAL: { id: 0x434d5846, hasInput: true },
  CM_RANDOM_GENERATE: { id: 0x434d5247, hasInput: true },
  CM_RANDOM_STIR: { id: 0x434d5253, hasInput: true },
  CM_AES_ENCRYPT_INIT: { id: 0x434d4149, hasInput: true },
  CM_AES_ENCRYPT_UPDATE: { id: 0x434d4155, hasInput: true },
  CM_AES_DECRYPT_INIT: { id: 0x434d414a, hasInput: true },
  CM_AES_DECRYPT_UPDATE: { id: 0x434d4156, hasInput: true },
  CM_AES_GCM_ENCRYPT_INIT: { id: 0x434d4749, hasInput: true },
  CM_AES_GCM_SPDM_ENCRYPT_INIT: { id: 0x434d5345, hasInput: true },
  CM_AES_GCM_ENCRYPT_UPDATE: { id: 0x434d4755, hasInput: true },
  CM_AES_GCM_ENCRYPT_FINAL: { id: 0x434d4746, hasInput: true },
  CM_AES_GCM_DECRYPT_INIT: { id: 0x434d4449, hasInput: true },
  CM_AES_GCM_SPDM_DECRYPT_INIT: { id: 0x434d5344, hasInput: true },
  CM_AES_GCM_DECRYPT_UPDATE: { id: 0x434d4455, hasInput: true },
  CM_AES_GCM_DECRYPT_FINAL: { id: 0x434d4446, hasInput: true },
  CM_AES_GCM_DECRYPT_DMA: { id: 0x434d4444, hasInput: true },
  CM_ECDH_GENERATE: { id: 0x434d4547, hasInput: true },
  CM_ECDH_FINISH: { id: 0x434d4546, hasInput: true },
  CM_HMAC: { id: 0x434d484d, hasInput: true },
  CM_HMAC_KDF_COUNTER: { id: 0x434d4b43, hasInput: true },
  CM_HKDF_EXTRACT: { id: 0x434d4b54, hasInput: true },
  CM_HKDF_EXPAND: { id: 0x434d4b50, hasInput: true },
  CM_MLDSA_PUBLIC_KEY: { id: 0x434d4d50, hasInput: true },
  CM_MLDSA_SIGN: { id: 0x434d4d53, hasInput: true },
  CM_MLDSA_VERIFY: { id: 0x434d4d56, hasInput: true },
  CM_ECDSA_PUBLIC_KEY: { id: 0x434d4550, hasInput: true },
  CM_ECDSA_SIGN: { id: 0x434d4553, hasInput: true },
  CM_ECDSA_VERIFY: { id: 0x434d4556, hasInput: true },
  CM_DERIVE_STABLE_KEY: { id: 0x494d4453, hasInput: true },
  CM_MLKEM_KEY_GEN: { id: 0x434d4c4b, hasInput: true },
  CM_MLKEM_ENCAPSULATE: { id: 0x434d4c45, hasInput: true },
  CM_MLKEM_DECAPSULATE: { id: 0x434d4c44, hasInput: true },
  // Debug
  MANUF_DEBUG_UNLOCK_REQ_TOKEN: { id: 0x4d445554, hasInput: true },
  PRODUCTION_AUTH_DEBUG_UNLOCK_REQ: { id: 0x50445552, hasInput: true },
  PRODUCTION_AUTH_DEBUG_UNLOCK_TOKEN: { id: 0x50445554, hasInput: true },
  EXTERNAL_MAILBOX_CMD: { id: 0x4558544d, hasInput: true },
  // OCP Lock
  OCP_LOCK_REPORT_HEK_METADATA: { id: 0x52484d54, hasInput: true },
  OCP_LOCK_GET_ALGORITHMS: { id: 0x47414c47, hasInput: false },
  OCP_LOCK_INITIALIZE_MEK_SECRET: { id: 0x494d4b53, hasInput: true },
  OCP_LOCK_MIX_MPK: { id: 0x4d4d504b, hasInput: true },
  OCP_LOCK_DERIVE_MEK: { id: 0x444d454b, hasInput: true },
  OCP_LOCK_ENUMERATE_HPKE_HANDLES: { id: 0x4548444c, hasInput: true },
  OCP_LOCK_ROTATE_HPKE_KEY: { id: 0x5248504b, hasInput: true },
  OCP_LOCK_GENERATE_MEK: { id: 0x474d454b, hasInput: true },
  OCP_LOCK_GET_HPKE_PUB_KEY: { id: 0x4748504b, hasInput: true },
  OCP_LOCK_GENERATE_MPK: { id: 0x474d504b, hasInput: true },
  OCP_LOCK_REWRAP_MPK: { id: 0x52455750, hasInput: true },
  OCP_LOCK_ENABLE_MPK: { id: 0x524d504b, hasInput: true },
  OCP_LOCK_TEST_ACCESS_KEY: { id: 0x5441434b, hasInput: true },
  OCP_LOCK_CLEAR_KEY_CACHE: { id: 0x434c4b43, hasInput: true },
  OCP_LOCK_GET_STATUS: { id: 0x47535441, hasInput: false },
  OCP_LOCK_UNLOAD_MEK: { id: 0x554d454b, hasInput: true },
  OCP_LOCK_LOAD_MEK: { id: 0x4c4d454b, hasInput: true },
};

const COMMAND_FIELDS = {
  VERSION: [],
  SELF_TEST_START: [],
  SELF_TEST_GET_RESULTS: [],
  SHUTDOWN: [],
  FW_INFO: [],
  CAPABILITIES: [],
  GET_MCU_FW_SIZE: [],
  GET_IDEV_ECC384_INFO: [],
  GET_IDEV_MLDSA87_INFO: [],
  GET_PCR_LOG: [],
  DISABLE_ATTESTATION: [],
  FIRMWARE_VERIFY: [],
  CM_STATUS: [],
  CM_CLEAR: [],
  OCP_LOCK_GET_ALGORITHMS: [],
  OCP_LOCK_GET_STATUS: [],
  GET_LDEV_ECC384_CERT: [],
  GET_FMC_ALIAS_ECC384_CERT: [],
  GET_RT_ALIAS_ECC384_CERT: [],
  GET_IDEV_ECC384_CSR: [],
  GET_FMC_ALIAS_ECC384_CSR: [],
  GET_LDEV_MLDSA87_CERT: [],
  GET_FMC_ALIAS_MLDSA87_CERT: [],
  GET_RT_ALIAS_MLDSA87_CERT: [],
  GET_IDEV_MLDSA87_CSR: [],
  GET_FMC_ALIAS_MLDSA87_CSR: [],
  FIRMWARE_LOAD: [],
  RI_DOWNLOAD_FIRMWARE: [],
  RI_DOWNLOAD_ENCRYPTED_FIRMWARE: [],
  OCP_LOCK_INITIALIZE_MEK_SECRET: [],
  OCP_LOCK_MIX_MPK: [],
  OCP_LOCK_DERIVE_MEK: [],
  OCP_LOCK_GENERATE_MPK: [],
  OCP_LOCK_REWRAP_MPK: [],
  OCP_LOCK_ENABLE_MPK: [],
  OCP_LOCK_TEST_ACCESS_KEY: [],
  OCP_LOCK_UNLOAD_MEK: [],
  OCP_LOCK_LOAD_MEK: [],

  ACTIVATE_FIRMWARE: [
    { name: "fw_id_count", type: "u32", desc: "Number of FW IDs" },
    { name: "fw_ids", type: "hex", size: 128, desc: "FW ID array (u32[32])" },
    { name: "mcu_fw_image_size", type: "u32", desc: "MCU FW image size" },
  ],
  GET_IDEV_ECC384_CERT: [
    { name: "tbs_size", type: "u32", desc: "TBS data size" },
    { name: "signature_r", type: "hex", size: 48, desc: "ECDSA signature R" },
    { name: "signature_s", type: "hex", size: 48, desc: "ECDSA signature S" },
    { name: "tbs", type: "hex", size: 916, desc: "TBS certificate data" },
  ],
  GET_IDEV_MLDSA87_CERT: [
    { name: "tbs_size", type: "u32", desc: "TBS data size" },
    { name: "signature", type: "hex", size: 4628, desc: "MLDSA87 signature" },
    { name: "tbs", type: "hex", size: 2820, desc: "TBS certificate data" },
  ],
  POPULATE_IDEV_ECC384_CERT: [
    { name: "cert_size", type: "u32", desc: "Certificate size" },
    { name: "cert", type: "hex", size: 1024, desc: "Certificate data" },
  ],
  POPULATE_IDEV_MLDSA87_CERT: [
    { name: "cert_size", type: "u32", desc: "Certificate size" },
    { name: "cert", type: "hex", size: 8192, desc: "Certificate data" },
  ],
  GET_ATTESTED_ECC384_CSR: [
    { name: "key_id", type: "u32", desc: "Key ID" },
    { name: "nonce", type: "hex", size: 32, desc: "Nonce (32 bytes)" },
  ],
  GET_ATTESTED_MLDSA87_CSR: [
    { name: "key_id", type: "u32", desc: "Key ID" },
    { name: "nonce", type: "hex", size: 32, desc: "Nonce (32 bytes)" },
  ],
  ECDSA384_SIGNATURE_VERIFY: [
    { name: "pub_key_x", type: "hex", size: 48, desc: "Public key X" },
    { name: "pub_key_y", type: "hex", size: 48, desc: "Public key Y" },
    { name: "signature_r", type: "hex", size: 48, desc: "Signature R" },
    { name: "signature_s", type: "hex", size: 48, desc: "Signature S" },
    { name: "hash", type: "hex", size: 48, desc: "SHA-384 hash to verify" },
  ],
  LMS_SIGNATURE_VERIFY: [
    { name: "pub_key_tree_type", type: "u32", desc: "Tree type" },
    { name: "pub_key_ots_type", type: "u32", desc: "OTS type" },
    { name: "pub_key_id", type: "hex", size: 16, desc: "Public key ID" },
    { name: "pub_key_digest", type: "hex", size: 24, desc: "Public key digest" },
    { name: "signature_q", type: "u32", desc: "Signature Q" },
    { name: "signature_ots", type: "hex", size: 1252, desc: "OTS signature" },
    { name: "signature_tree_type", type: "u32", desc: "Signature tree type" },
    { name: "signature_tree_path", type: "hex", size: 360, desc: "Tree path" },
    { name: "hash", type: "hex", size: 48, desc: "Hash to verify" },
  ],
  MLDSA87_SIGNATURE_VERIFY: [
    { name: "pub_key", type: "hex", size: 2592, desc: "MLDSA87 public key" },
    { name: "signature", type: "hex", size: 4628, desc: "MLDSA87 signature" },
    { name: "message_size", type: "u32", desc: "Message size" },
    { name: "message", type: "hex", size: 4096, desc: "Message" },
  ],
  STASH_MEASUREMENT: [
    { name: "metadata", type: "hex", size: 4, desc: "Metadata" },
    { name: "measurement", type: "hex", size: 48, desc: "Measurement (SHA-384)" },
    { name: "context", type: "hex", size: 48, desc: "Context (SHA-384)" },
    { name: "svn", type: "u32", desc: "Security Version Number" },
  ],
  INVOKE_DPE_ECC384: [
    { name: "data_size", type: "u32", desc: "DPE command data size" },
    { name: "data", type: "hex", size: 512, desc: "DPE command data" },
  ],
  INVOKE_DPE_MLDSA87: [
    { name: "flags", type: "u32", desc: "Flags" },
    { name: "axi_addr_lo", type: "u32", desc: "AXI response address (low)" },
    { name: "axi_addr_hi", type: "u32", desc: "AXI response address (high)" },
    { name: "data_size", type: "u32", desc: "DPE command data size" },
    { name: "data", type: "hex", size: 512, desc: "DPE command data" },
  ],
  EXTEND_PCR: [
    { name: "pcr_idx", type: "u32", desc: "PCR index" },
    { name: "data", type: "hex", size: 48, desc: "Data to extend (SHA-384)" },
  ],
  ADD_SUBJECT_ALT_NAME: [
    { name: "dmtf_device_info_size", type: "u32", desc: "Device info size" },
    { name: "dmtf_device_info", type: "hex", size: 128, desc: "DMTF device info" },
  ],
  DPE_TAG_TCI: [
    { name: "handle", type: "hex", size: 16, desc: "DPE context handle" },
    { name: "tag", type: "u32", desc: "Tag value" },
  ],
  DPE_GET_TAGGED_TCI: [{ name: "tag", type: "u32", desc: "Tag to look up" }],
  INCREMENT_PCR_RESET_COUNTER: [{ name: "index", type: "u32", desc: "PCR index" }],
  QUOTE_PCRS_ECC384: [{ name: "nonce", type: "hex", size: 32, desc: "Nonce (32 bytes)" }],
  QUOTE_PCRS_MLDSA87: [{ name: "nonce", type: "hex", size: 32, desc: "Nonce (32 bytes)" }],
  AUTHORIZE_AND_STASH: [
    { name: "fw_id", type: "hex", size: 4, desc: "Firmware ID" },
    { name: "measurement", type: "hex", size: 48, desc: "Image digest (SHA-384)" },
    { name: "context", type: "hex", size: 48, desc: "Context (SHA-384)" },
    { name: "svn", type: "u32", desc: "Security Version Number" },
    { name: "flags", type: "u32", desc: "Flags" },
    { name: "source", type: "u32", desc: "Image source" },
    { name: "image_size", type: "u32", desc: "Image size in bytes" },
  ],
  GET_IMAGE_INFO: [{ name: "fw_id", type: "hex", size: 4, desc: "Firmware ID" }],
  INSTALL_OWNER_PK_HASH: [{ name: "digest", type: "hex", size: 48, desc: "Owner PK hash (u32[12])" }],
  REALLOCATE_DPE_CONTEXT_LIMITS: [{ name: "pl0_context_limit", type: "u32", desc: "PL0 context limit" }],
  ZEROIZE_UDS_FE: [{ name: "flags", type: "u32", desc: "Flags" }],
  FE_PROG: [{ name: "partition", type: "u32", desc: "Partition" }],
  MANUF_DEBUG_UNLOCK_REQ_TOKEN: [
    {
      name: "token",
      type: "hex",
      size: 32,
      desc: "Unlock token (32 bytes)",
      default: DEFAULT_MANUF_DBG_TOKEN_HEX,
    },
  ],
  EXTERNAL_MAILBOX_CMD: [
    { name: "command_id", type: "u32", desc: "Command ID" },
    { name: "command_size", type: "u32", desc: "Command size" },
    { name: "axi_address_start_low", type: "u32", desc: "AXI address (low)" },
    { name: "axi_address_start_high", type: "u32", desc: "AXI address (high)" },
  ],
  CERTIFY_KEY_EXTENDED_ECC384: [
    { name: "flags", type: "u32", desc: "CertifyKeyExtendedFlags" },
    { name: "certify_key_req", type: "hex", size: 72, desc: "Inner CertifyKey request data" },
  ],
  CERTIFY_KEY_EXTENDED_MLDSA87: [
    { name: "flags", type: "u32", desc: "CertifyKeyExtendedFlags" },
    { name: "axi_addr_lo", type: "u32", desc: "AXI response address (low)" },
    { name: "axi_addr_hi", type: "u32", desc: "AXI response address (high)" },
    { name: "axi_max_size", type: "u32", desc: "AXI max size" },
    { name: "certify_key_req", type: "hex", size: 72, desc: "Inner CertifyKey request data" },
  ],
  PRODUCTION_AUTH_DEBUG_UNLOCK_REQ: [
    { name: "length", type: "u32", desc: "Length (in DWORDs)" },
    { name: "unlock_level", type: "u32", desc: "Debug unlock level (1-8)" },
  ],
  PRODUCTION_AUTH_DEBUG_UNLOCK_TOKEN: [
    { name: "token_size", type: "u32", desc: "Token size" },
    { name: "token", type: "hex", size: 4096, desc: "Token data" },
  ],
  SET_AUTH_MANIFEST: [
    { name: "manifest_size", type: "u32", desc: "Manifest size" },
    { name: "manifest", type: "hex", size: 16384, desc: "Auth manifest data" },
  ],
  VERIFY_AUTH_MANIFEST: [
    { name: "manifest_size", type: "u32", desc: "Manifest size" },
    { name: "manifest", type: "hex", size: 16384, desc: "Auth manifest data" },
  ],
  SIGN_WITH_EXPORTED_ECDSA: [
    { name: "exported_cdi_handle", type: "hex", size: 64, desc: "Exported CDI handle" },
    { name: "tbs", type: "hex", size: 48, desc: "TBS digest" },
  ],
  SIGN_WITH_EXPORTED_MLDSA: [
    { name: "exported_cdi_handle", type: "hex", size: 64, desc: "Exported CDI handle" },
    { name: "tbs", type: "hex", size: 48, desc: "TBS digest" },
  ],
  REVOKE_EXPORTED_CDI_HANDLE: [
    { name: "exported_cdi_handle", type: "hex", size: 64, desc: "Exported CDI handle" },
  ],
  // Crypto Manager (CM)
  CM_IMPORT: [
    { name: "key_usage", type: "u32", desc: "Key usage flags" },
    { name: "input_size", type: "u32", desc: "Input size" },
    { name: "input", type: "hex", size: 128, desc: "Key data" },
  ],
  CM_DELETE: [{ name: "cmk", type: "hex", size: 128, desc: "CM Key handle" }],
  CM_SHA_INIT: [
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_SHA_UPDATE: [
    { name: "context", type: "hex", size: 200, desc: "SHA context (from INIT/UPDATE)" },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_SHA_FINAL: [
    { name: "context", type: "hex", size: 200, desc: "SHA context" },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_SHA: [
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 262132, desc: "Input data" },
  ],
  CM_SHAKE256_INIT: [
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_SHAKE256_UPDATE: [
    { name: "context", type: "hex", size: 44, desc: "SHAKE256 context" },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_SHAKE256_FINAL: [
    { name: "context", type: "hex", size: 44, desc: "SHAKE256 context" },
    { name: "input_size", type: "u32", desc: "Input data size" },
    { name: "input", type: "hex", size: 4096, desc: "Input data" },
  ],
  CM_RANDOM_GENERATE: [{ name: "size", type: "u32", desc: "Number of random bytes", default: 32 }],
  CM_RANDOM_STIR: [
    { name: "input_size", type: "u32", desc: "Entropy data size" },
    { name: "input", type: "hex", size: 4096, desc: "Entropy data" },
  ],
  CM_AES_ENCRYPT_INIT: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    {
      name: "mode",
      type: "enum",
      desc: "AES mode",
      options: [
        { value: 0, label: "ECB" },
        { value: 1, label: "CBC" },
        { value: 2, label: "CTR" },
      ],
    },
    { name: "plaintext_size", type: "u32", desc: "Plaintext size" },
    { name: "plaintext", type: "hex", size: 4096, desc: "Plaintext data" },
  ],
  CM_AES_ENCRYPT_UPDATE: [
    { name: "context", type: "hex", size: 156, desc: "AES context" },
    { name: "plaintext_size", type: "u32", desc: "Plaintext size" },
    { name: "plaintext", type: "hex", size: 4096, desc: "Plaintext data" },
  ],
  CM_AES_DECRYPT_INIT: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    {
      name: "mode",
      type: "enum",
      desc: "AES mode",
      options: [
        { value: 0, label: "ECB" },
        { value: 1, label: "CBC" },
        { value: 2, label: "CTR" },
      ],
    },
    { name: "iv", type: "hex", size: 16, desc: "Initialization vector" },
    { name: "ciphertext_size", type: "u32", desc: "Ciphertext size" },
    { name: "ciphertext", type: "hex", size: 4096, desc: "Ciphertext data" },
  ],
  CM_AES_DECRYPT_UPDATE: [
    { name: "context", type: "hex", size: 156, desc: "AES context" },
    { name: "ciphertext_size", type: "u32", desc: "Ciphertext size" },
    { name: "ciphertext", type: "hex", size: 4096, desc: "Ciphertext data" },
  ],
  CM_AES_GCM_ENCRYPT_INIT: [
    { name: "flags", type: "u32", desc: "Flags" },
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "aad_size", type: "u32", desc: "AAD size" },
    { name: "aad", type: "hex", size: 4096, desc: "Additional authenticated data" },
  ],
  CM_AES_GCM_SPDM_ENCRYPT_INIT: [
    { name: "spdm_flags", type: "u32", desc: "SPDM flags" },
    { name: "spdm_counter", type: "hex", size: 8, desc: "SPDM counter" },
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "aad_size", type: "u32", desc: "AAD size" },
    { name: "aad", type: "hex", size: 4096, desc: "Additional authenticated data" },
  ],
  CM_AES_GCM_ENCRYPT_UPDATE: [
    { name: "context", type: "hex", size: 128, desc: "AES-GCM context" },
    { name: "plaintext_size", type: "u32", desc: "Plaintext size" },
    { name: "plaintext", type: "hex", size: 4096, desc: "Plaintext data" },
  ],
  CM_AES_GCM_ENCRYPT_FINAL: [
    { name: "context", type: "hex", size: 128, desc: "AES-GCM context" },
    { name: "plaintext_size", type: "u32", desc: "Plaintext size" },
    { name: "plaintext", type: "hex", size: 4096, desc: "Plaintext data" },
  ],
  CM_AES_GCM_DECRYPT_INIT: [
    { name: "flags", type: "u32", desc: "Flags" },
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "iv", type: "hex", size: 12, desc: "IV (u32[3])" },
    { name: "aad_size", type: "u32", desc: "AAD size" },
    { name: "aad", type: "hex", size: 4096, desc: "Additional authenticated data" },
  ],
  CM_AES_GCM_SPDM_DECRYPT_INIT: [
    { name: "spdm_flags", type: "u32", desc: "SPDM flags" },
    { name: "spdm_counter", type: "hex", size: 8, desc: "SPDM counter" },
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "aad_size", type: "u32", desc: "AAD size" },
    { name: "aad", type: "hex", size: 4096, desc: "Additional authenticated data" },
  ],
  CM_AES_GCM_DECRYPT_UPDATE: [
    { name: "context", type: "hex", size: 128, desc: "AES-GCM context" },
    { name: "ciphertext_size", type: "u32", desc: "Ciphertext size" },
    { name: "ciphertext", type: "hex", size: 4096, desc: "Ciphertext data" },
  ],
  CM_AES_GCM_DECRYPT_FINAL: [
    { name: "context", type: "hex", size: 128, desc: "AES-GCM context" },
    { name: "tag_len", type: "u32", desc: "Tag length" },
    { name: "tag", type: "hex", size: 16, desc: "GCM tag (u32[4])" },
    { name: "ciphertext_size", type: "u32", desc: "Ciphertext size" },
    { name: "ciphertext", type: "hex", size: 4096, desc: "Ciphertext data" },
  ],
  CM_AES_GCM_DECRYPT_DMA: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "iv", type: "hex", size: 12, desc: "IV (u32[3])" },
    { name: "tag", type: "hex", size: 16, desc: "GCM tag (u32[4])" },
    { name: "encrypted_data_sha384", type: "hex", size: 48, desc: "SHA-384 of encrypted data" },
    { name: "axi_addr_lo", type: "u32", desc: "AXI address (low)" },
    { name: "axi_addr_hi", type: "u32", desc: "AXI address (high)" },
    { name: "length", type: "u32", desc: "Data length" },
    { name: "aad_length", type: "u32", desc: "AAD length" },
    { name: "aad", type: "hex", size: 4096, desc: "Additional authenticated data" },
  ],
  CM_ECDH_GENERATE: [{ name: "key_usage", type: "u32", desc: "Key usage flags" }],
  CM_ECDH_FINISH: [
    { name: "context", type: "hex", size: 76, desc: "ECDH context" },
    { name: "key_usage", type: "u32", desc: "Key usage flags" },
    { name: "incoming_exchange_data", type: "hex", size: 96, desc: "Incoming ECDH exchange data" },
  ],
  CM_HMAC: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "data_size", type: "u32", desc: "Data size" },
    { name: "data", type: "hex", size: 4096, desc: "Data to HMAC" },
  ],
  CM_HMAC_KDF_COUNTER: [
    { name: "kin", type: "hex", size: 128, desc: "Input key (CM Key handle)" },
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "key_usage", type: "u32", desc: "Output key usage" },
    { name: "key_size", type: "u32", desc: "Output key size" },
    { name: "label_size", type: "u32", desc: "Label size" },
    { name: "label", type: "hex", size: 4096, desc: "KDF label" },
  ],
  CM_HKDF_EXTRACT: [
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "salt", type: "hex", size: 128, desc: "Salt (CM Key handle)" },
    { name: "ikm", type: "hex", size: 128, desc: "Input keying material (CM Key handle)" },
  ],
  CM_HKDF_EXPAND: [
    { name: "prk", type: "hex", size: 128, desc: "PRK (CM Key handle)" },
    {
      name: "hash_algorithm",
      type: "enum",
      desc: "Hash algorithm",
      options: [
        { value: 1, label: "SHA-384" },
        { value: 2, label: "SHA-512" },
      ],
    },
    { name: "key_usage", type: "u32", desc: "Output key usage" },
    { name: "key_size", type: "u32", desc: "Output key size" },
    { name: "info_size", type: "u32", desc: "Info size" },
    { name: "info", type: "hex", size: 4096, desc: "HKDF info" },
  ],
  CM_MLDSA_PUBLIC_KEY: [{ name: "cmk", type: "hex", size: 128, desc: "CM Key handle" }],
  CM_MLDSA_SIGN: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "message_size", type: "u32", desc: "Message size" },
    { name: "message", type: "hex", size: 4096, desc: "Message to sign" },
  ],
  CM_MLDSA_VERIFY: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle (public key)" },
    { name: "signature", type: "hex", size: 4628, desc: "MLDSA87 signature" },
    { name: "message_size", type: "u32", desc: "Message size" },
    { name: "message", type: "hex", size: 4096, desc: "Message" },
  ],
  CM_ECDSA_PUBLIC_KEY: [{ name: "cmk", type: "hex", size: 128, desc: "CM Key handle" }],
  CM_ECDSA_SIGN: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "message_size", type: "u32", desc: "Message size" },
    { name: "message", type: "hex", size: 4096, desc: "Message to sign" },
  ],
  CM_ECDSA_VERIFY: [
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle (public key)" },
    { name: "signature_r", type: "hex", size: 48, desc: "Signature R" },
    { name: "signature_s", type: "hex", size: 48, desc: "Signature S" },
    { name: "message_size", type: "u32", desc: "Message size" },
    { name: "message", type: "hex", size: 4096, desc: "Message" },
  ],
  CM_DERIVE_STABLE_KEY: [
    { name: "key_type", type: "u32", desc: "Key type" },
    { name: "info", type: "hex", size: 32, desc: "Derivation info" },
  ],
  CM_MLKEM_KEY_GEN: [{ name: "cmk", type: "hex", size: 128, desc: "CM Key handle (seed)" }],
  CM_MLKEM_ENCAPSULATE: [
    { name: "key_usage", type: "u32", desc: "Key usage flags" },
    { name: "encaps_key", type: "hex", size: 1568, desc: "Encapsulation key" },
  ],
  CM_MLKEM_DECAPSULATE: [
    { name: "key_usage", type: "u32", desc: "Key usage flags" },
    { name: "cmk", type: "hex", size: 128, desc: "CM Key handle" },
    { name: "ciphertext", type: "hex", size: 1568, desc: "Ciphertext" },
  ],
  // OCP Lock
  OCP_LOCK_REPORT_HEK_METADATA: [
    { name: "reserved0", type: "u32", desc: "Reserved" },
    { name: "total_slots", type: "u32", desc: "Total slots (u16) + Active slots (u16)" },
    { name: "seed_state", type: "u32", desc: "Seed state (u16) + padding (u16)" },
  ],
  OCP_LOCK_ENUMERATE_HPKE_HANDLES: [{ name: "reserved", type: "u32", desc: "Reserved (0)" }],
  OCP_LOCK_ROTATE_HPKE_KEY: [
    { name: "reserved", type: "u32", desc: "Reserved (0)" },
    { name: "hpke_handle", type: "u32", desc: "HPKE handle" },
  ],
  OCP_LOCK_GENERATE_MEK: [{ name: "reserved", type: "u32", desc: "Reserved (0)" }],
  OCP_LOCK_GET_HPKE_PUB_KEY: [
    { name: "reserved", type: "u32", desc: "Reserved (0)" },
    { name: "hpke_handle", type: "u32", desc: "HPKE handle" },
  ],
  OCP_LOCK_CLEAR_KEY_CACHE: [
    { name: "reserved", type: "u32", desc: "Reserved (0)" },
    { name: "cmd_timeout", type: "u32", desc: "Command timeout" },
  ],
};

function fieldsFor(cmdKey) {
  return COMMAND_FIELDS[cmdKey] || [];
}

function getInputMode() {
  const r = document.querySelector('input[name="mbox-input-mode"]:checked');
  return r ? r.value : "form";
}

function renderFormFields(fields) {
  mboxFormFields.innerHTML = "";
  if (fields.length === 0) {
    const msg = document.createElement("p");
    msg.className = "note";
    msg.textContent = "This command has no parameters.";
    mboxFormFields.appendChild(msg);
    return;
  }
  for (const field of fields) {
    if (field.type === "pad") continue;
    const row = document.createElement("div");
    row.className = "field";

    const label = document.createElement("label");
    label.textContent = field.desc || field.name;
    label.title = `${field.name} (${field.type}${field.size ? ", " + field.size + " bytes" : ""})`;
    row.appendChild(label);

    let input;
    if (field.type === "u32") {
      input = document.createElement("input");
      input.type = "number";
      input.value = String(field.default ?? 0);
      input.min = "0";
      input.max = "4294967295";
      input.dataset.fieldName = field.name;
      input.dataset.fieldType = "u32";
    } else if (field.type === "enum") {
      input = document.createElement("select");
      for (const opt of field.options) {
        const o = document.createElement("option");
        o.value = opt.value;
        o.textContent = opt.label;
        input.appendChild(o);
      }
      input.dataset.fieldName = field.name;
      input.dataset.fieldType = "enum";
    } else if (field.type === "hex") {
      const placeholder = "00".repeat(Math.min(field.size, 8)) + (field.size > 8 ? "…" : "");
      if (field.size > 32) {
        input = document.createElement("textarea");
        input.rows = Math.min(3, Math.ceil(field.size / 32));
        input.placeholder = placeholder;
      } else {
        input = document.createElement("input");
        input.type = "text";
        input.placeholder = placeholder;
      }
      if (field.default) input.value = field.default;
      input.spellcheck = false;
      input.dataset.fieldName = field.name;
      input.dataset.fieldType = "hex";
      input.dataset.fieldSize = field.size;
    }

    row.appendChild(input);
    mboxFormFields.appendChild(row);
  }
}

function updateInputSection(cmdKey, mode) {
  const fields = fieldsFor(cmdKey);
  const hasFields = fields.length > 0;

  if (mode === "form") {
    mboxRawInput.style.display = "none";
    mboxFormFields.style.display = "block";
    renderFormFields(fields);
  } else {
    mboxFormFields.style.display = "none";
    mboxRawInput.style.display = "block";
    const cmd = COMMAND_INFO[cmdKey];
    if (hasFields || (cmd && cmd.hasInput)) {
      mboxPayload.placeholder = "Payload bytes after the checksum, e.g. 01020304";
      mboxPayload.disabled = false;
    } else {
      mboxPayload.placeholder = "This command takes no payload";
      mboxPayload.disabled = true;
    }
    mboxPayload.value = "";
  }
}

mboxCmdSelect.addEventListener("change", () => {
  const val = mboxCmdSelect.value;
  if (val === "CM_SHA_HASH") {
    mboxParams.style.display = "block";
    mboxRawInput.style.display = "none";
    mboxFormFields.style.display = "none";
  } else {
    mboxParams.style.display = "none";
    updateInputSection(val, getInputMode());
  }
});

document.querySelectorAll('input[name="mbox-input-mode"]').forEach((radio) => {
  radio.addEventListener("change", () => {
    const val = mboxCmdSelect.value;
    if (val === "CM_SHA_HASH") return;
    updateInputSection(val, radio.value);
  });
});

function writeU32LE(buf, offset, value) {
  buf[offset] = value & 0xff;
  buf[offset + 1] = (value >>> 8) & 0xff;
  buf[offset + 2] = (value >>> 16) & 0xff;
  buf[offset + 3] = (value >>> 24) & 0xff;
}

function readU32LE(buf, offset) {
  return (
    (buf[offset] |
      (buf[offset + 1] << 8) |
      (buf[offset + 2] << 16) |
      (buf[offset + 3] << 24)) >>>
    0
  );
}

function readU32LEArray(buf, offset, count) {
  const result = [];
  for (let i = 0; i < count; i++) result.push(readU32LE(buf, offset + i * 4));
  return result;
}

function hexBytes(buf, offset, len) {
  return Array.from(buf.slice(offset, offset + len))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function toHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function hexU32BE(words, offset, count) {
  let s = "";
  for (let i = 0; i < count; i++) s += words[i + offset].toString(16).padStart(8, "0");
  return s;
}

function parseHexPayload(hexStr) {
  const cleaned = hexStr.replace(/[\s,]/g, "").replace(/^0x/i, "");
  if (cleaned.length === 0) return new Uint8Array(0);
  if (cleaned.length % 2 !== 0) {
    throw new Error("Hex string must have an even number of characters");
  }
  const bytes = new Uint8Array(cleaned.length / 2);
  for (let i = 0; i < cleaned.length; i += 2) {
    const b = parseInt(cleaned.substring(i, i + 2), 16);
    if (Number.isNaN(b)) {
      throw new Error(`Invalid hex at position ${i}: "${cleaned.substring(i, i + 2)}"`);
    }
    bytes[i / 2] = b;
  }
  return bytes;
}

function serializeFormFields(cmdKey) {
  const fields = fieldsFor(cmdKey);
  if (fields.length === 0) return new Uint8Array(0);

  const parts = [];
  for (const field of fields) {
    if (field.type === "pad") {
      parts.push(new Uint8Array(field.size));
      continue;
    }
    const el = mboxFormFields.querySelector(`[data-field-name="${field.name}"]`);
    if (!el) throw new Error(`Form field not found: ${field.name}`);

    if (field.type === "u32" || field.type === "enum") {
      const val = (parseInt(el.value, 10) || 0) >>> 0;
      const buf = new Uint8Array(4);
      writeU32LE(buf, 0, val);
      parts.push(buf);
    } else if (field.type === "hex") {
      const hexStr = (el.value || "").trim();
      const bytes = hexStr.length > 0 ? parseHexPayload(hexStr) : new Uint8Array(0);
      const buf = new Uint8Array(field.size);
      buf.set(bytes.slice(0, field.size));
      parts.push(buf);
    }
  }
  const totalLen = parts.reduce((s, p) => s + p.length, 0);
  const result = new Uint8Array(totalLen);
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

function calcChecksum(cmdId, payloadAfterChecksum) {
  let sum = 0;
  for (let i = 0; i < 4; i++) {
    sum = (sum + ((cmdId >>> (i * 8)) & 0xff)) >>> 0;
  }
  for (const b of payloadAfterChecksum) {
    sum = (sum + b) >>> 0;
  }
  return (0x100000000 - sum) >>> 0;
}

function makeHeaderOnlyRequest(cmdId) {
  const buf = new Uint8Array(4);
  writeU32LE(buf, 0, calcChecksum(cmdId, new Uint8Array(0)));
  return buf;
}

function makeChecksummedRequest(cmdId, payloadAfterChecksum) {
  const buf = new Uint8Array(4 + payloadAfterChecksum.length);
  buf.set(payloadAfterChecksum, 4);
  writeU32LE(buf, 0, calcChecksum(cmdId, payloadAfterChecksum));
  return buf;
}

function formatRespHeader(buf) {
  const chksum = readU32LE(buf, 0);
  const fipsStatus = readU32LE(buf, 4);
  return (
    `  chksum:      0x${chksum.toString(16).padStart(8, "0")}\n` +
    `  fips_status: ${fipsStatus === 0 ? "APPROVED (0)" : fipsStatus}\n`
  );
}

function formatFwInfoResp(buf) {
  if (buf.length < 8) return "Error: response too short";
  let s = "FwInfoResp:\n" + formatRespHeader(buf);
  if (buf.length < 196) {
    s += `  (truncated — got ${buf.length} bytes, expected ≥196)\n`;
    s += `  raw: ${hexBytes(buf, 8, buf.length - 8)}\n`;
    return s;
  }
  let off = 8;
  s += `  pl0_pauser:                    ${readU32LE(buf, off)}\n`; off += 4;
  s += `  fw_svn:                        ${readU32LE(buf, off)}\n`; off += 4;
  s += `  min_fw_svn:                    ${readU32LE(buf, off)}\n`; off += 4;
  s += `  cold_boot_fw_svn:              ${readU32LE(buf, off)}\n`; off += 4;
  s += `  attestation_disabled:          ${readU32LE(buf, off)}\n`; off += 4;
  s += `  rom_revision:                  ${hexBytes(buf, off, 20)}\n`; off += 20;
  s += `  fmc_revision:                  ${hexBytes(buf, off, 20)}\n`; off += 20;
  s += `  runtime_revision:              ${hexBytes(buf, off, 20)}\n`; off += 20;
  const romDigest = readU32LEArray(buf, off, 8); off += 32;
  s += `  rom_sha256_digest:             ${hexU32BE(romDigest, 0, 8)}\n`;
  const fmcDigest = readU32LEArray(buf, off, 12); off += 48;
  s += `  fmc_sha384_digest:             ${hexU32BE(fmcDigest, 0, 12)}\n`;
  const rtDigest = readU32LEArray(buf, off, 12); off += 48;
  s += `  runtime_sha384_digest:         ${hexU32BE(rtDigest, 0, 12)}\n`;
  const ownerPk = readU32LEArray(buf, off, 12); off += 48;
  s += `  owner_pub_key_hash:            ${hexU32BE(ownerPk, 0, 12)}\n`;
  const authmanDigest = readU32LEArray(buf, off, 12); off += 48;
  s += `  authman_sha384_digest:         ${hexU32BE(authmanDigest, 0, 12)}\n`;
  s += `  most_recent_fw_error:          0x${readU32LE(buf, off).toString(16).padStart(8, "0")}\n`; off += 4;
  if (buf.length >= 396) {
    const vendorPk = readU32LEArray(buf, off, 12); off += 48;
    s += `  vendor_pub_key_hash:           ${hexU32BE(vendorPk, 0, 12)}\n`;
    const pqcType = readU32LE(buf, off); off += 4;
    const pqcLabel = pqcType === 1 ? "ML-DSA-87 (1)" : pqcType === 3 ? "LMS (3)" : String(pqcType);
    s += `  image_manifest_pqc_type:       ${pqcLabel}\n`;
    s += `  vendor_ecc384_pub_key_index:   ${readU32LE(buf, off)}\n`; off += 4;
    s += `  vendor_pqc_pub_key_index:      ${readU32LE(buf, off)}\n`; off += 4;
    s += `  soc_manifest_current_svn:      ${readU32LE(buf, off)}\n`; off += 4;
    s += `  soc_manifest_min_svn:          ${readU32LE(buf, off)}\n`; off += 4;
    s += `  owner_auth_manifest_curr_svn:  ${readU32LE(buf, off)}\n`; off += 4;
    s += `  owner_auth_manifest_min_svn:   ${readU32LE(buf, off)}\n`; off += 4;
    s += `  debug_policy:                  0x${readU32LE(buf, off).toString(16).padStart(8, "0")}\n`;
  }
  return s;
}

function formatFipsVersionResp(buf) {
  if (buf.length < 8) return "Error: response too short";
  let s = "FipsVersionResp:\n" + formatRespHeader(buf);
  if (buf.length < 32) {
    s += `  (truncated — got ${buf.length} bytes)\n`;
    return s;
  }
  let off = 8;
  s += `  mode:     0x${readU32LE(buf, off).toString(16).padStart(8, "0")}\n`; off += 4;
  const rev0 = readU32LE(buf, off); off += 4;
  const rev1 = readU32LE(buf, off); off += 4;
  const rev2 = readU32LE(buf, off); off += 4;
  s += `  fips_rev: [0x${rev0.toString(16)}, ${rev1}, ${rev2}]\n`;
  const nameBytes = buf.slice(off, off + 12);
  const name = new TextDecoder().decode(nameBytes).replace(/\0+$/, "");
  s += `  name:     "${name}"\n`;
  return s;
}

function formatCapabilitiesResp(buf) {
  if (buf.length < 8) return "Error: response too short";
  let s = "CapabilitiesResp:\n" + formatRespHeader(buf);
  if (buf.length < 24) {
    s += `  (truncated — got ${buf.length} bytes)\n`;
    return s;
  }
  s += `  capabilities: ${hexBytes(buf, 8, 16)}\n`;
  return s;
}

function sizedData(buf) {
  if (buf.length < 12) return null;
  const size = readU32LE(buf, 8);
  return buf.slice(12, 12 + Math.min(size, buf.length - 12));
}

function toPem(label, der) {
  if (!der || der.length === 0) return `(empty ${label})\n`;
  let b64 = "";
  for (let i = 0; i < der.length; i += 0x8000) {
    b64 += String.fromCharCode(...der.slice(i, i + 0x8000));
  }
  const wrapped = btoa(b64).match(/.{1,64}/g)?.join("\n") || "";
  return `-----BEGIN ${label}-----\n${wrapped}\n-----END ${label}-----\n`;
}

function makeDerDecoder(title, pemLabel, filename) {
  return (buf) => {
    const der = sizedData(buf);
    if (!der) return { text: "Error: response too short\n", downloads: [] };
    return {
      text: `${title} (${der.length} bytes, DER):\n${toPem(pemLabel, der)}`,
      downloads: [{ name: filename, bytes: der }],
    };
  };
}

const NAMED_FORMATTERS = {
  GET_IDEV_ECC384_CERT: makeDerDecoder("IDevID ECC-384 Certificate", "CERTIFICATE", "idevid-ecc384.crt.der"),
  GET_LDEV_ECC384_CERT: makeDerDecoder("LDevID ECC-384 Certificate", "CERTIFICATE", "ldevid-ecc384.crt.der"),
  GET_FMC_ALIAS_ECC384_CERT: makeDerDecoder("FMC Alias ECC-384 Certificate", "CERTIFICATE", "fmc-alias-ecc384.crt.der"),
  GET_RT_ALIAS_ECC384_CERT: makeDerDecoder("RT Alias ECC-384 Certificate", "CERTIFICATE", "rt-alias-ecc384.crt.der"),
  GET_IDEV_ECC384_CSR: makeDerDecoder("IDevID ECC-384 CSR", "CERTIFICATE REQUEST", "idevid-ecc384.csr.der"),
  GET_FMC_ALIAS_ECC384_CSR: makeDerDecoder("FMC Alias ECC-384 CSR", "CERTIFICATE REQUEST", "fmc-alias-ecc384.csr.der"),
  GET_IDEV_MLDSA87_CERT: makeDerDecoder("IDevID ML-DSA-87 Certificate", "CERTIFICATE", "idevid-mldsa87.crt.der"),
  GET_LDEV_MLDSA87_CERT: makeDerDecoder("LDevID ML-DSA-87 Certificate", "CERTIFICATE", "ldevid-mldsa87.crt.der"),
  GET_FMC_ALIAS_MLDSA87_CERT: makeDerDecoder("FMC Alias ML-DSA-87 Certificate", "CERTIFICATE", "fmc-alias-mldsa87.crt.der"),
  GET_RT_ALIAS_MLDSA87_CERT: makeDerDecoder("RT Alias ML-DSA-87 Certificate", "CERTIFICATE", "rt-alias-mldsa87.crt.der"),
  GET_IDEV_MLDSA87_CSR: makeDerDecoder("IDevID ML-DSA-87 CSR", "CERTIFICATE REQUEST", "idevid-mldsa87.csr.der"),
  GET_FMC_ALIAS_MLDSA87_CSR: makeDerDecoder("FMC Alias ML-DSA-87 CSR", "CERTIFICATE REQUEST", "fmc-alias-mldsa87.csr.der"),
  GET_IDEV_ECC384_INFO: (buf) => {
    if (buf.length < 104) return { text: "Error: response too short\n", downloads: [] };
    const x = buf.slice(8, 56);
    const y = buf.slice(56, 104);
    return {
      text: `IDevID ECC-384 Public Key:\n  X (48B): ${toHex(x)}\n  Y (48B): ${toHex(y)}\n`,
      downloads: [{ name: "idevid-ecc384-pubkey.bin", bytes: buf.slice(8, 104) }],
    };
  },
  GET_IDEV_MLDSA87_INFO: (buf) => {
    const pk = buf.slice(8, 8 + 2592);
    return {
      text: `IDevID ML-DSA-87 Public Key (${pk.length} bytes):\n${toHex(pk)}\n`,
      downloads: [{ name: "idevid-mldsa87-pubkey.bin", bytes: pk }],
    };
  },
};

const CUSTOM_FORMATTERS = {
  0x494e464f: formatFwInfoResp,
  0x46505652: formatFipsVersionResp,
  0x43415053: formatCapabilitiesResp,
};

function showDownloads(container, downloads) {
  container.replaceChildren();
  for (const d of downloads || []) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([d.bytes], { type: "application/octet-stream" }));
    a.download = d.name;
    a.textContent = `Download ${d.name}`;
    a.className = "download";
    container.appendChild(a);
  }
}

function formatRawRequest(reqBuf) {
  const n = reqBuf.length;
  let s = `Request (${n} bytes):\n`;
  if (n >= 4) {
    s += `  chksum: 0x${readU32LE(reqBuf, 0).toString(16).padStart(8, "0")}\n`;
  }
  if (n > 4) {
    s += `  payload: ${hexBytes(reqBuf, 4, n - 4)}\n`;
  }
  return s;
}

function formatRawResponse(respBuf) {
  if (!respBuf || respBuf.length === 0) return "Response: (empty — CMD_COMPLETE)\n";
  const n = respBuf.length;
  let s = `Response (${n} bytes):\n`;
  if (n >= 4) {
    s += `  chksum: 0x${readU32LE(respBuf, 0).toString(16).padStart(8, "0")}\n`;
  }
  if (n >= 8) {
    const fips = readU32LE(respBuf, 4);
    s += `  fips_status: ${fips === 0 ? "APPROVED (0)" : `0x${fips.toString(16).padStart(8, "0")} (${fips})`}\n`;
  }
  if (n > 8) {
    s += `  data: ${hexBytes(respBuf, 8, n - 8)}\n`;
  }
  return s;
}

// ============================================================================
// Async Mailbox Execution (including Composite CM_SHA_HASH)
// ============================================================================

async function sendMailbox(cmdId, reqData, onProgress) {
  mboxProgressHandler = onProgress || null;
  const reqCopy = reqData.slice().buffer;
  try {
    const res = await callWorker(
      "mailboxExecute",
      { cmdId: cmdId >>> 0, reqBytes: reqCopy },
      [reqCopy]
    );
    appendConsoleOutput(res.uart, res.log);
    if (res.status) applyStatus(res.status);
    if (res.inspectors) applyInspectors(res.inspectors);
    updateStatsDisplay(res.status?.total_cycles ?? 0);
    return res.respBytes ? new Uint8Array(res.respBytes) : new Uint8Array(0);
  } catch (err) {
    if (err.workerMsg) {
      appendConsoleOutput(err.workerMsg.uart, err.workerMsg.log);
      if (err.workerMsg.status) applyStatus(err.workerMsg.status);
      if (err.workerMsg.inspectors) applyInspectors(err.workerMsg.inspectors);
    }
    throw err;
  } finally {
    mboxProgressHandler = null;
  }
}

const CM_SHA_CONTEXT_SIZE = 200;
const CM_SHA_MAX_INPUT = 4096;
const CMD_CM_SHA_INIT = 0x434d5349;
const CMD_CM_SHA_UPDATE = 0x434d5355;
const CMD_CM_SHA_FINAL = 0x434d5346;

function makeCmShaInitReq(hashAlgo, inputBytes) {
  const payload = new Uint8Array(8 + inputBytes.length);
  writeU32LE(payload, 0, hashAlgo);
  writeU32LE(payload, 4, inputBytes.length);
  payload.set(inputBytes, 8);
  return makeChecksummedRequest(CMD_CM_SHA_INIT, payload);
}

function makeCmShaStepReq(cmdId, context, inputBytes) {
  const payload = new Uint8Array(CM_SHA_CONTEXT_SIZE + 4 + inputBytes.length);
  payload.set(context, 0);
  writeU32LE(payload, CM_SHA_CONTEXT_SIZE, inputBytes.length);
  payload.set(inputBytes, CM_SHA_CONTEXT_SIZE + 4);
  return makeChecksummedRequest(cmdId, payload);
}

async function executeCmShaHash() {
  const hashAlgo = parseInt(mboxShaAlgo.value, 10);
  const algoName = hashAlgo === 1 ? "SHA-384" : "SHA-512";
  const digestLen = hashAlgo === 1 ? 48 : 64;
  const inputText = mboxShaInput.value;
  const inputBytes = new TextEncoder().encode(inputText);

  let s = `CM SHA Hash (${algoName})\n  Input: "${inputText}" (${inputBytes.length} bytes)\n\n`;
  mboxResponse.textContent = s;

  const chunks = [];
  for (let i = 0; i < inputBytes.length; i += CM_SHA_MAX_INPUT) {
    chunks.push(inputBytes.slice(i, i + CM_SHA_MAX_INPUT));
  }

  const firstChunk = chunks.length > 0 ? chunks[0] : new Uint8Array(0);
  s += `  → CM_SHA_INIT (${firstChunk.length} bytes)...\n`;
  const initReq = makeCmShaInitReq(hashAlgo, firstChunk);
  s += formatRawRequest(initReq);
  mboxResponse.textContent = s;

  const initBuf = await sendMailbox(CMD_CM_SHA_INIT, initReq, (cyc) => {
    mboxResponse.textContent = s + `  Executing CM_SHA_INIT… ${cyc.toLocaleString()} cycles\n`;
  });
  if (initBuf.length < 8 + CM_SHA_CONTEXT_SIZE) {
    s += `  ✗ INIT failed (got ${initBuf.length} bytes)\n` + formatRawResponse(initBuf);
    return s;
  }
  s += formatRawResponse(initBuf);
  if (readU32LE(initBuf, 4) !== 0) {
    s += `  ✗ INIT fips_status: ${readU32LE(initBuf, 4)}\n`;
    return s;
  }
  let context = initBuf.slice(8, 8 + CM_SHA_CONTEXT_SIZE);
  s += `  ✓ INIT OK\n\n`;

  for (let i = 1; i < chunks.length - 1; i++) {
    s += `  → CM_SHA_UPDATE chunk ${i} (${chunks[i].length} bytes)...\n`;
    const updateReq = makeCmShaStepReq(CMD_CM_SHA_UPDATE, context, chunks[i]);
    s += formatRawRequest(updateReq);
    mboxResponse.textContent = s;
    const updateBuf = await sendMailbox(CMD_CM_SHA_UPDATE, updateReq, (cyc) => {
      mboxResponse.textContent = s + `  Executing CM_SHA_UPDATE… ${cyc.toLocaleString()} cycles\n`;
    });
    if (updateBuf.length < 8 + CM_SHA_CONTEXT_SIZE) {
      s += `  ✗ UPDATE failed\n` + formatRawResponse(updateBuf);
      return s;
    }
    s += formatRawResponse(updateBuf);
    context = updateBuf.slice(8, 8 + CM_SHA_CONTEXT_SIZE);
    s += `  ✓ UPDATE OK\n\n`;
  }

  const lastChunk = chunks.length > 1 ? chunks[chunks.length - 1] : new Uint8Array(0);
  s += `  → CM_SHA_FINAL (${lastChunk.length} bytes)...\n`;
  const finalReq = makeCmShaStepReq(CMD_CM_SHA_FINAL, context, lastChunk);
  s += formatRawRequest(finalReq);
  mboxResponse.textContent = s;

  const finalBuf = await sendMailbox(CMD_CM_SHA_FINAL, finalReq, (cyc) => {
    mboxResponse.textContent = s + `  Executing CM_SHA_FINAL… ${cyc.toLocaleString()} cycles\n`;
  });
  if (finalBuf.length < 12) {
    s += `  ✗ FINAL failed (got ${finalBuf.length} bytes)\n` + formatRawResponse(finalBuf);
    return s;
  }
  s += formatRawResponse(finalBuf);
  if (readU32LE(finalBuf, 4) !== 0) {
    s += `  ✗ FINAL fips_status: ${readU32LE(finalBuf, 4)}\n`;
    return s;
  }
  const dataLen = readU32LE(finalBuf, 8);
  const hash = finalBuf.slice(12, 12 + Math.min(dataLen, digestLen));
  s += `  ✓ FINAL OK\n\n  ${algoName} digest (${hash.length} bytes):\n  ${toHex(hash)}\n`;
  return s;
}

btnMboxSend.addEventListener("click", async () => {
  if (!simInitialized || mailboxBusy) return;
  const cmdKey = mboxCmdSelect.value;
  showDownloads(mboxDownloads, []);

  const wasRunning = simRunning;
  if (wasRunning) {
    await callWorker("pause");
    simRunning = false;
  }

  mailboxBusy = true;
  syncMailboxControls();
  btnRun.disabled = true;
  btnStop.disabled = true;
  setStepButtonsDisabled(true);
  setStatus(`Executing mailbox ${cmdKey}…`, "running");

  try {
    if (cmdKey === "CM_SHA_HASH") {
      mboxResponse.textContent = await executeCmShaHash();
    } else {
      const cmd = COMMAND_INFO[cmdKey];
      if (!cmd) {
        mboxResponse.textContent = `Unknown command: ${cmdKey}`;
        return;
      }
      const id = cmd.id >>> 0;
      let output = `Sending ${cmdKey} (0x${id.toString(16).toUpperCase().padStart(8, "0")})...\n\n`;

      let reqData;
      const inputMode = getInputMode();
      const fields = fieldsFor(cmdKey);
      if (inputMode === "form" && fields.length > 0) {
        reqData = makeChecksummedRequest(id, serializeFormFields(cmdKey));
      } else if (cmd.hasInput || fields.length > 0) {
        reqData = makeChecksummedRequest(id, parseHexPayload(mboxPayload.value.trim()));
      } else {
        reqData = makeHeaderOnlyRequest(id);
      }
      output += formatRawRequest(reqData) + "\n";
      mboxResponse.textContent = output;

      if (id === 0x50445552 || id === 0x50445554) {
        await callWorker("setDbgUnlockReq", { kind: "prod", enable: true });
      } else if (id === 0x4d445554) {
        await callWorker("setDbgUnlockReq", { kind: "manuf", enable: true });
      }

      const buf = await sendMailbox(id, reqData, (cycles) => {
        mboxResponse.textContent =
          output + `Clocking AXI4-Lite mailbox… ${cycles.toLocaleString()} cycles\n`;
      });

      output += formatRawResponse(buf);
      if (buf && buf.length > 0) {
        const named = NAMED_FORMATTERS[cmdKey];
        const formatter = CUSTOM_FORMATTERS[id];
        if (named) {
          const r = named(buf);
          output += "\n--- Decoded ---\n" + r.text;
          showDownloads(mboxDownloads, r.downloads);
        } else if (formatter) {
          output += "\n--- Decoded ---\n" + formatter(buf);
        }
      }
      mboxResponse.textContent = output;
    }
  } catch (err) {
    mboxResponse.textContent += `\nError: ${err.message}\n`;
  } finally {
    mailboxBusy = false;
    if (wasRunning && lastStatus.phase !== "EXITED" && lastStatus.phase !== "FATAL_ERROR") {
      simRunning = true;
      setStatus("Running RTL clock", "running");
      btnRun.disabled = true;
      btnStop.disabled = false;
      setStepButtonsDisabled(true);
      await callWorker("run", { pauseOnReady: pauseOnReadyInput.checked });
    } else {
      const readyLabel =
        lastStatus.phase === "RUNTIME_READY"
          ? "Ready (Runtime mailbox)"
          : lastStatus.phase === "ROM_IDLE"
            ? "Ready (ROM mailbox)"
            : "Paused";
      setStatus(
        readyLabel,
        lastStatus.phase === "RUNTIME_READY" || lastStatus.phase === "ROM_IDLE"
          ? "passed"
          : "stopped"
      );
      btnRun.disabled = false;
      btnStop.disabled = true;
      setStepButtonsDisabled(false);
    }
    syncMailboxControls();
  }
});

// ============================================================================
// Startup Initialization
// ============================================================================

async function startup() {
  updateInputSection(mboxCmdSelect.value, getInputMode());
  applyStatus(lastStatus);

  const qPreset = new URLSearchParams(location.search).get("preset");
  if (qPreset && PRESETS[qPreset]) {
    imagePresetSelect.value = qPreset;
  }

  try {
    setStatus("Loading WebAssembly RTL…", "");
    const [, defaultsResp] = await Promise.all([
      workerReady,
      fetch("defaults.json").catch(() => null),
      computeDefaultManufTokenHash(),
    ]);

    if (defaultsResp && defaultsResp.ok) {
      const defaults = await defaultsResp.json();
      if (defaults.vendor_pk_hash) {
        vendorPkInput.value = defaults.vendor_pk_hash;
        autoPk.vendor = defaults.vendor_pk_hash;
      }
      if (defaults.owner_pk_hash) {
        ownerPkInput.value = defaults.owner_pk_hash;
        autoPk.owner = defaults.owner_pk_hash;
      }
    }

    await loadSelectedPreset(imagePresetSelect.value);

    setStatus("Ready", "");
    btnRun.disabled = false;
    btnReset.disabled = false;
  } catch (err) {
    setStatus(`Failed to load WebAssembly: ${err.message || err}`, "exited");
    console.error("WASM startup error:", err);
  }
}

startup();
