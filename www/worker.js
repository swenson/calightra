// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Calightra Contributors.
//
// Web Worker hosting the Verilated Caliptra 2.1 Core RTL WebAssembly module.
// Runs cycle-accurate RTL simulation off the main UI thread in adaptive slices
// (~80 ms per slice) and streams live hardware signals, UART TX, and logs.

import createCalightraModule from "./calightra_verilated.js";

let mod = null;
let modError = null;
let running = false;
let runLoopToken = 0;
let adaptiveSlice = 500;
let tickCounter = 0;

const modReady = createCalightraModule()
  .then((m) => {
    mod = m;
    self.postMessage({ event: "ready" });
  })
  .catch((err) => {
    modError = String(err);
    self.postMessage({ event: "init_error", error: modError });
  });

function mallocBytes(u8) {
  if (!u8 || u8.length === 0) return { ptr: 0, len: 0 };
  const ptr = mod._malloc(u8.length);
  if (!ptr) throw new Error(`WASM malloc(${u8.length}) failed`);
  mod.HEAPU8.set(u8, ptr);
  return { ptr, len: u8.length };
}

function mallocCStr(str) {
  const s = str || "";
  const len = mod.lengthBytesUTF8(s) + 1;
  const ptr = mod._malloc(len);
  if (!ptr) throw new Error(`WASM malloc(${len}) failed`);
  mod.stringToUTF8(s, ptr, len);
  return ptr;
}

function readLastError() {
  return mod.UTF8ToString(mod._calightra_last_error());
}

function readUart() {
  return mod.UTF8ToString(mod._calightra_take_uart());
}

function readLog() {
  return mod.UTF8ToString(mod._calightra_take_log());
}

function readStatus() {
  return JSON.parse(mod.UTF8ToString(mod._calightra_get_status_json()));
}

function readInspectors() {
  return {
    errors: JSON.parse(mod.UTF8ToString(mod._calightra_get_errors_json())),
    keyvault: JSON.parse(mod.UTF8ToString(mod._calightra_get_keyvault_json())),
    fuses: JSON.parse(mod.UTF8ToString(mod._calightra_get_fuses_json())),
  };
}

function updateAdaptiveSlice(cyclesRan, elapsedMs) {
  if (cyclesRan <= 0 || elapsedMs <= 0.5) return;
  const targetMs = 85;
  const rawNext = Math.round((cyclesRan * targetMs) / elapsedMs);
  const clamped = Math.max(100, Math.min(25000, rawNext));
  adaptiveSlice = Math.round(adaptiveSlice * 0.65 + clamped * 0.35);
}

function scheduleRunSlice(token, pauseOnReady) {
  setTimeout(() => {
    if (!running || token !== runLoopToken || !mod) return;

    const before = readStatus();
    if (!before.initialized) {
      running = false;
      return;
    }

    const prevCycles = before.total_cycles;
    const wasMbReady = Boolean(before.ready_for_mb_processing);
    const wasRtReady = Boolean(before.ready_for_runtime);

    const t0 = performance.now();
    const stillRunning = mod._calightra_step(adaptiveSlice);
    const elapsedMs = performance.now() - t0;

    const after = readStatus();
    const cyclesRan = Math.max(1, after.total_cycles - prevCycles);
    updateAdaptiveSlice(cyclesRan, elapsedMs);

    const uart = readUart();
    const log = readLog();
    tickCounter++;

    const hitMilestone =
      pauseOnReady &&
      ((after.fw_total_bytes === 0 && !wasMbReady && Boolean(after.ready_for_mb_processing)) ||
        (after.fw_total_bytes > 0 && !wasRtReady && Boolean(after.ready_for_runtime)));

    if (!stillRunning) {
      running = false;
      self.postMessage({
        event: "halted",
        status: after,
        uart,
        log,
        cyclesRan,
        elapsedMs,
        inspectors: readInspectors(),
      });
      return;
    }

    if (hitMilestone) {
      running = false;
      self.postMessage({
        event: "milestone_paused",
        milestone: after.ready_for_runtime ? "RUNTIME_READY" : "ROM_IDLE",
        status: after,
        uart,
        log,
        cyclesRan,
        elapsedMs,
        inspectors: readInspectors(),
      });
      return;
    }

    const includeInspectors =
      tickCounter % 12 === 0 ||
      wasMbReady !== Boolean(after.ready_for_mb_processing) ||
      wasRtReady !== Boolean(after.ready_for_runtime);

    self.postMessage({
      event: "tick",
      status: after,
      uart,
      log,
      cyclesRan,
      elapsedMs,
      inspectors: includeInspectors ? readInspectors() : null,
    });

    if (running && token === runLoopToken) {
      scheduleRunSlice(token, pauseOnReady);
    }
  }, 0);
}

self.addEventListener("message", async (ev) => {
  const msg = ev.data;
  const { reqId, type } = msg;

  await modReady;
  if (!mod) {
    if (reqId !== undefined) {
      self.postMessage({ reqId, ok: false, error: modError || "WASM module failed to load" });
    }
    return;
  }

  try {
    switch (type) {
      case "ping": {
        self.postMessage({ reqId, ok: true });
        break;
      }

      case "fwPkHashes": {
        const fw = msg.fw ? new Uint8Array(msg.fw) : new Uint8Array(0);
        const fwBuf = mallocBytes(fw);
        try {
          const jsonPtr = mod._calightra_fw_pk_hashes(fwBuf.ptr, fwBuf.len);
          const hashesJson = mod.UTF8ToString(jsonPtr);
          self.postMessage({ reqId, ok: true, hashesJson });
        } finally {
          if (fwBuf.ptr) mod._free(fwBuf.ptr);
        }
        break;
      }

      case "init": {
        running = false;
        runLoopToken++;
        tickCounter = 0;
        adaptiveSlice = 500;

        const rom = msg.rom ? new Uint8Array(msg.rom) : new Uint8Array(0);
        const fw = msg.fw ? new Uint8Array(msg.fw) : new Uint8Array(0);
        const romBuf = mallocBytes(rom);
        const fwBuf = mallocBytes(fw);
        const vpkPtr = mallocCStr(msg.vendorPk || "");
        const opkPtr = mallocCStr(msg.ownerPk || "");
        const lcPtr = mallocCStr(msg.lifecycle || "manufacturing");
        const fusesPtr = mallocCStr(msg.fusesJson || "");

        try {
          const rc = mod._calightra_init(
            romBuf.ptr,
            romBuf.len,
            fwBuf.ptr,
            fwBuf.len,
            vpkPtr,
            opkPtr,
            lcPtr,
            msg.debugIntent ? 1 : 0,
            fusesPtr
          );
          if (rc !== 0) {
            self.postMessage({ reqId, ok: false, error: readLastError() || "calightra_init failed" });
            return;
          }
          self.postMessage({
            reqId,
            ok: true,
            status: readStatus(),
            uart: readUart(),
            log: readLog(),
            inspectors: readInspectors(),
          });
        } finally {
          if (romBuf.ptr) mod._free(romBuf.ptr);
          if (fwBuf.ptr) mod._free(fwBuf.ptr);
          mod._free(vpkPtr);
          mod._free(opkPtr);
          mod._free(lcPtr);
          mod._free(fusesPtr);
        }
        break;
      }

      case "destroy": {
        running = false;
        runLoopToken++;
        mod._calightra_destroy();
        self.postMessage({ reqId, ok: true });
        break;
      }

      case "run": {
        running = true;
        const token = ++runLoopToken;
        scheduleRunSlice(token, Boolean(msg.pauseOnReady));
        self.postMessage({ reqId, ok: true });
        break;
      }

      case "pause": {
        running = false;
        runLoopToken++;
        self.postMessage({
          reqId,
          ok: true,
          status: readStatus(),
          uart: readUart(),
          log: readLog(),
          inspectors: readInspectors(),
        });
        break;
      }

      case "step": {
        running = false;
        runLoopToken++;
        let remaining = Math.max(0, Number(msg.cycles) || 0);
        let stillRunning = 1;
        const chunkLimit = Math.max(500, Math.min(5000, adaptiveSlice));

        while (remaining > 0) {
          const take = Math.min(remaining, chunkLimit);
          const before = readStatus();
          const t0 = performance.now();
          stillRunning = mod._calightra_step(take);
          const elapsedMs = performance.now() - t0;
          const after = readStatus();
          const ran = Math.max(1, after.total_cycles - before.total_cycles);
          updateAdaptiveSlice(ran, elapsedMs);
          remaining -= take;

          if (!stillRunning) break;
          if (remaining > 0) {
            self.postMessage({
              event: "tick",
              status: after,
              uart: readUart(),
              log: readLog(),
              cyclesRan: ran,
              elapsedMs,
              inspectors: null,
            });
            await new Promise((r) => setTimeout(r, 0));
          }
        }

        self.postMessage({
          reqId,
          ok: true,
          stillRunning: Boolean(stillRunning),
          status: readStatus(),
          uart: readUart(),
          log: readLog(),
          inspectors: readInspectors(),
        });
        break;
      }

      case "getInspectors": {
        self.postMessage({
          reqId,
          ok: true,
          status: readStatus(),
          inspectors: readInspectors(),
        });
        break;
      }

      case "setDbgUnlockReq": {
        const enable = msg.enable ? 1 : 0;
        if (msg.kind === "prod") {
          mod._calightra_set_prod_dbg_unlock_req(enable);
        } else {
          mod._calightra_set_manuf_dbg_unlock_req(enable);
        }
        self.postMessage({ reqId, ok: true });
        break;
      }

      case "mailboxExecute": {
        running = false;
        runLoopToken++;

        const cmdId = msg.cmdId >>> 0;
        const reqU8 = msg.reqBytes ? new Uint8Array(msg.reqBytes) : new Uint8Array(0);
        const reqBuf = mallocBytes(reqU8);
        let startRc = 0;
        try {
          startRc = mod._calightra_mailbox_start(cmdId, reqBuf.ptr, reqBuf.len);
        } finally {
          if (reqBuf.ptr) mod._free(reqBuf.ptr);
        }

        if (startRc !== 0) {
          self.postMessage({
            reqId,
            ok: false,
            error: readLastError() || "Failed to start mailbox command",
            status: readStatus(),
          });
          return;
        }

        const startCycles = readStatus().total_cycles;
        const maxCycles = 200_000_000;
        let poll = 0;

        while ((poll = mod._calightra_mailbox_poll()) === 0) {
          const before = readStatus();
          if (before.total_cycles - startCycles > maxCycles) {
            self.postMessage({
              reqId,
              ok: false,
              error: `Mailbox command timed out after ${maxCycles.toLocaleString()} cycles`,
              status: before,
              inspectors: readInspectors(),
            });
            return;
          }

          const t0 = performance.now();
          const stillRunning = mod._calightra_step(adaptiveSlice);
          const elapsedMs = performance.now() - t0;
          const after = readStatus();
          const ran = Math.max(1, after.total_cycles - before.total_cycles);
          updateAdaptiveSlice(ran, elapsedMs);

          const uart = readUart();
          const log = readLog();
          self.postMessage({
            event: "mbox_progress",
            reqId,
            cycles: after.total_cycles - startCycles,
            status: after,
            uart,
            log,
            cyclesRan: ran,
            elapsedMs,
          });

          if (!stillRunning) {
            poll = mod._calightra_mailbox_poll();
            break;
          }
          await new Promise((r) => setTimeout(r, 0));
        }

        if (poll < 0) {
          self.postMessage({
            reqId,
            ok: false,
            error: readLastError() || "Mailbox command failed",
            status: readStatus(),
            uart: readUart(),
            log: readLog(),
            inspectors: readInspectors(),
          });
          return;
        }

        const respLen = mod._calightra_mailbox_resp_len() >>> 0;
        const respPtr = mod._calightra_mailbox_resp_ptr() >>> 0;
        const respCopy = respLen > 0 && respPtr ? mod.HEAPU8.slice(respPtr, respPtr + respLen) : new Uint8Array(0);

        self.postMessage(
          {
            reqId,
            ok: true,
            respBytes: respCopy.buffer,
            status: readStatus(),
            uart: readUart(),
            log: readLog(),
            inspectors: readInspectors(),
          },
          [respCopy.buffer]
        );
        break;
      }

      default:
        if (reqId !== undefined) {
          self.postMessage({ reqId, ok: false, error: `Unknown worker message type: ${type}` });
        }
    }
  } catch (err) {
    if (reqId !== undefined) {
      self.postMessage({ reqId, ok: false, error: err?.message || String(err) });
    }
  }
});
