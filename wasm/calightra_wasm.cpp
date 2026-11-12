// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Calightra Contributors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "Vcalightra_verilated_wasm.h"
#include "Vcalightra_verilated_wasm__Dpi.h"
#include "svdpi.h"
#include "verilated.h"
#include "caliptra_reg.h"

#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#else
#define EMSCRIPTEN_KEEPALIVE
#endif

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

// Required by Verilator runtime
double sc_time_stamp() {
    return 0.0;
}

namespace {

static constexpr uint32_t DEFAULT_AXI_USER  = 0x1u;
static constexpr uint32_t CMD_FIRMWARE_LOAD = 0x46574C44u; // "FWLD"
static constexpr uint32_t MANIFEST_MARKER_2X = 0x324E4D43u; // "CMN2"

// ============================================================================
// Self-contained FIPS 180-4 SHA-384 implementation for manifest PK hashing
// ============================================================================

static inline uint64_t rotr64(uint64_t x, unsigned n) {
    return (x >> n) | (x << (64 - n));
}

static inline uint64_t load_be64(const uint8_t* p) {
    return (uint64_t(p[0]) << 56) | (uint64_t(p[1]) << 48) |
           (uint64_t(p[2]) << 40) | (uint64_t(p[3]) << 32) |
           (uint64_t(p[4]) << 24) | (uint64_t(p[5]) << 16) |
           (uint64_t(p[6]) << 8)  |  uint64_t(p[7]);
}

static inline void store_be64(uint8_t* p, uint64_t v) {
    for (int i = 0; i < 8; ++i) {
        p[i] = static_cast<uint8_t>((v >> (56 - i * 8)) & 0xffu);
    }
}

static const uint64_t SHA512_K[80] = {
    0x428a2f98d728ae22ULL, 0x7137449123ef65cdULL, 0xb5c0fbcfec4d3b2fULL, 0xe9b5dba58189dbbcULL,
    0x3956c25bf348b538ULL, 0x59f111f1b605d019ULL, 0x923f82a4af194f9bULL, 0xab1c5ed5da6d8118ULL,
    0xd807aa98a3030242ULL, 0x12835b0145706fbeULL, 0x243185be4ee4b28cULL, 0x550c7dc3d5ffb4e2ULL,
    0x72be5d74f27b896fULL, 0x80deb1fe3b1696b1ULL, 0x9bdc06a725c71235ULL, 0xc19bf174cf692694ULL,
    0xe49b69c19ef14ad2ULL, 0xefbe4786384f25e3ULL, 0x0fc19dc68b8cd5b5ULL, 0x240ca1cc77ac9c65ULL,
    0x2de92c6f592b0275ULL, 0x4a7484aa6ea6e483ULL, 0x5cb0a9dcbd41fbd4ULL, 0x76f988da831153b5ULL,
    0x983e5152ee66dfabULL, 0xa831c66d2db43210ULL, 0xb00327c898fb213fULL, 0xbf597fc7beef0ee4ULL,
    0xc6e00bf33da88fc2ULL, 0xd5a79147930aa725ULL, 0x06ca6351e003826fULL, 0x142929670a0e6e70ULL,
    0x27b70a8546d22ffcULL, 0x2e1b21385c26c926ULL, 0x4d2c6dfc5ac42aedULL, 0x53380d139d95b3dfULL,
    0x650a73548baf63deULL, 0x766a0abb3c77b2a8ULL, 0x81c2c92e47edaee6ULL, 0x92722c851482353bULL,
    0xa2bfe8a14cf10364ULL, 0xa81a664bbc423001ULL, 0xc24b8b70d0f89791ULL, 0xc76c51a30654be30ULL,
    0xd192e819d6ef5218ULL, 0xd69906245565a910ULL, 0xf40e35855771202aULL, 0x106aa07032bbd1b8ULL,
    0x19a4c116b8d2d0c8ULL, 0x1e376c085141ab53ULL, 0x2748774cdf8eeb99ULL, 0x34b0bcb5e19b48a8ULL,
    0x391c0cb3c5c95a63ULL, 0x4ed8aa4ae3418acbULL, 0x5b9cca4f7763e373ULL, 0x682e6ff3d6b2b8a3ULL,
    0x748f82ee5defb2fcULL, 0x78a5636f43172f60ULL, 0x84c87814a1f0ab72ULL, 0x8cc702081a6439ecULL,
    0x90befffa23631e28ULL, 0xa4506cebde82bde9ULL, 0xbef9a3f7b2c67915ULL, 0xc67178f2e372532bULL,
    0xca273eceea26619cULL, 0xd186b8c721c0c207ULL, 0xeada7dd6cde0eb1eULL, 0xf57d4f7fee6ed178ULL,
    0x06f067aa72176fbaULL, 0x0a637dc5a2c898a6ULL, 0x113f9804bef90daeULL, 0x1b710b35131c471bULL,
    0x28db77f523047d84ULL, 0x32caab7b40c72493ULL, 0x3c9ebe0a15c9bebcULL, 0x431d67c49c100d4cULL,
    0x4cc5d4becb3e42b6ULL, 0x597f299cfc657e2aULL, 0x5fcb6fab3ad6faecULL, 0x6c44198c4a475817ULL
};

static void sha512_compress(uint64_t state[8], const uint8_t block[128]) {
    uint64_t w[80];
    for (int i = 0; i < 16; ++i) {
        w[i] = load_be64(block + i * 8);
    }
    for (int i = 16; i < 80; ++i) {
        uint64_t s0 = rotr64(w[i - 15], 1) ^ rotr64(w[i - 15], 8) ^ (w[i - 15] >> 7);
        uint64_t s1 = rotr64(w[i - 2], 19) ^ rotr64(w[i - 2], 61) ^ (w[i - 2] >> 6);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    uint64_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint64_t e = state[4], f = state[5], g = state[6], h = state[7];

    for (int i = 0; i < 80; ++i) {
        uint64_t S1 = rotr64(e, 14) ^ rotr64(e, 18) ^ rotr64(e, 41);
        uint64_t ch = (e & f) ^ ((~e) & g);
        uint64_t temp1 = h + S1 + ch + SHA512_K[i] + w[i];
        uint64_t S0 = rotr64(a, 28) ^ rotr64(a, 34) ^ rotr64(a, 39);
        uint64_t maj = (a & b) ^ (a & c) ^ (b & c);
        uint64_t temp2 = S0 + maj;

        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static void sha384_digest(const uint8_t* data, size_t len, uint8_t out[48]) {
    uint64_t state[8] = {
        0xcbbb9d5dc1059ed8ULL, 0x629a292a367cd507ULL,
        0x9159015a3070dd17ULL, 0x152fecd8f70e5939ULL,
        0x67332667ffc00b31ULL, 0x8eb44a8768581511ULL,
        0xdb0c2e0d64f98fa7ULL, 0x47b5481dbefa4fa4ULL
    };

    size_t offset = 0;
    while (offset + 128 <= len) {
        sha512_compress(state, data + offset);
        offset += 128;
    }

    uint8_t pad[256];
    std::memset(pad, 0, sizeof(pad));
    size_t rem = len - offset;
    if (rem > 0) {
        std::memcpy(pad, data + offset, rem);
    }
    pad[rem] = 0x80u;
    size_t pad_blocks = (rem >= 112) ? 2 : 1;
    uint64_t bit_len = uint64_t(len) * 8ULL;
    store_be64(pad + pad_blocks * 128 - 8, bit_len);

    for (size_t b = 0; b < pad_blocks; ++b) {
        sha512_compress(state, pad + b * 128);
    }

    for (int i = 0; i < 6; ++i) {
        store_be64(out + i * 8, state[i]);
    }
}

// ============================================================================
// Hex & Minimal FuseConfig JSON Helpers
// ============================================================================

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static bool parse_hex_bytes(const std::string& raw, std::vector<uint8_t>& out, std::string& err) {
    out.clear();
    size_t start = 0;
    while (start < raw.size() && std::isspace(static_cast<unsigned char>(raw[start]))) start++;
    if (start + 2 <= raw.size() && raw[start] == '0' && (raw[start + 1] == 'x' || raw[start + 1] == 'X')) {
        start += 2;
    }
    std::string cleaned;
    cleaned.reserve(raw.size() - start);
    for (size_t i = start; i < raw.size(); ++i) {
        char c = raw[i];
        if (std::isspace(static_cast<unsigned char>(c))) continue;
        if (hex_nibble(c) < 0) {
            err = "Invalid hex character in input";
            return false;
        }
        cleaned.push_back(c);
    }
    if (cleaned.size() % 2 != 0) {
        err = "Hex string has odd length";
        return false;
    }
    out.resize(cleaned.size() / 2);
    for (size_t i = 0; i < out.size(); ++i) {
        out[i] = static_cast<uint8_t>((hex_nibble(cleaned[i * 2]) << 4) | hex_nibble(cleaned[i * 2 + 1]));
    }
    return true;
}

static bool parse_pk_hash_words(const char* hex_str, uint32_t words[12], std::string& err) {
    std::memset(words, 0, sizeof(uint32_t) * 12);
    if (!hex_str) return true;
    std::string s(hex_str);
    bool all_ws = true;
    for (char c : s) {
        if (!std::isspace(static_cast<unsigned char>(c))) { all_ws = false; break; }
    }
    if (all_ws) return true;

    std::vector<uint8_t> bytes;
    if (!parse_hex_bytes(s, bytes, err)) return false;
    if (bytes.size() != 48) {
        err = "PK hash must be 96 hex characters (48 bytes)";
        return false;
    }
    for (int i = 0; i < 12; ++i) {
        words[i] = (uint32_t(bytes[i * 4 + 0]) << 24) |
                   (uint32_t(bytes[i * 4 + 1]) << 16) |
                   (uint32_t(bytes[i * 4 + 2]) << 8)  |
                    uint32_t(bytes[i * 4 + 3]);
    }
    return true;
}

static std::string bytes_to_hex(const uint8_t* data, size_t len) {
    static const char* lut = "0123456789abcdef";
    std::string s;
    s.resize(len * 2);
    for (size_t i = 0; i < len; ++i) {
        s[i * 2]     = lut[(data[i] >> 4) & 0xf];
        s[i * 2 + 1] = lut[data[i] & 0xf];
    }
    return s;
}

static std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

struct FuseConfig {
    uint32_t fuse_pqc_key_type = 1; // Default 1 = ML-DSA
    uint32_t fuse_ecc_revocation = 0;
    uint32_t fuse_lms_revocation = 0;
    uint32_t fuse_mldsa_revocation = 0;
    bool anti_rollback_disable = false;
    uint16_t soc_stepping_id = 0;
    uint8_t soc_manifest_max_svn = 0;
    uint32_t soc_manifest_svn[4] = {0, 0, 0, 0};
    uint32_t fw_svn[4] = {0, 0, 0, 0};
    uint32_t idevid_cert_attr[24] = {0};
    uint32_t idevid_manuf_hsm_id[4] = {0};
    uint32_t manuf_dbg_unlock_token[16] = {0};
};

// Lightweight JSON key extractor tailored to FuseConfig's flat schema
static size_t find_json_value_pos(const std::string& json, const char* key) {
    std::string pat = std::string("\"") + key + "\"";
    size_t pos = json.find(pat);
    if (pos == std::string::npos) return std::string::npos;
    pos += pat.size();
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) pos++;
    if (pos >= json.size() || json[pos] != ':') return std::string::npos;
    pos++;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) pos++;
    return pos < json.size() ? pos : std::string::npos;
}

static bool json_get_u32(const std::string& json, const char* key, uint32_t& out) {
    size_t p = find_json_value_pos(json, key);
    if (p == std::string::npos || json.compare(p, 4, "null") == 0) return false;
    if (json[p] == '"') p++;
    char* endp = nullptr;
    unsigned long val = std::strtoul(json.c_str() + p, &endp, 0);
    if (endp == json.c_str() + p) return false;
    out = static_cast<uint32_t>(val);
    return true;
}

static bool json_get_bool(const std::string& json, const char* key, bool& out) {
    size_t p = find_json_value_pos(json, key);
    if (p == std::string::npos) return false;
    if (json.compare(p, 4, "true") == 0)  { out = true;  return true; }
    if (json.compare(p, 5, "false") == 0) { out = false; return true; }
    return false;
}

static bool json_get_u32_array4(const std::string& json, const char* key, uint32_t out[4]) {
    size_t p = find_json_value_pos(json, key);
    if (p == std::string::npos || json[p] != '[') return false;
    p++;
    for (int i = 0; i < 4; ++i) {
        while (p < json.size() && (std::isspace(static_cast<unsigned char>(json[p])) || json[p] == ',')) p++;
        if (p >= json.size()) return false;
        char* endp = nullptr;
        unsigned long v = std::strtoul(json.c_str() + p, &endp, 0);
        if (endp == json.c_str() + p) return false;
        out[i] = static_cast<uint32_t>(v);
        p = static_cast<size_t>(endp - json.c_str());
    }
    return true;
}

static bool json_get_string(const std::string& json, const char* key, std::string& out) {
    size_t p = find_json_value_pos(json, key);
    if (p == std::string::npos || json[p] != '"') return false;
    p++;
    out.clear();
    while (p < json.size() && json[p] != '"') {
        if (json[p] == '\\' && p + 1 < json.size()) p++;
        out.push_back(json[p++]);
    }
    return true;
}

static bool parse_fuse_config(const char* fuses_json_str, FuseConfig& cfg, std::string& err) {
    if (!fuses_json_str || fuses_json_str[0] == '\0') return true;
    std::string j(fuses_json_str);
    uint32_t tmp = 0;
    if (json_get_u32(j, "fuse_pqc_key_type", tmp)) cfg.fuse_pqc_key_type = tmp & 0x3u;
    if (json_get_u32(j, "fuse_ecc_revocation", tmp)) cfg.fuse_ecc_revocation = tmp & 0xfu;
    if (json_get_u32(j, "fuse_lms_revocation", tmp)) cfg.fuse_lms_revocation = tmp;
    if (json_get_u32(j, "fuse_mldsa_revocation", tmp)) cfg.fuse_mldsa_revocation = tmp & 0xfu;
    if (json_get_u32(j, "soc_stepping_id", tmp)) cfg.soc_stepping_id = static_cast<uint16_t>(tmp & 0xffffu);
    if (json_get_u32(j, "soc_manifest_max_svn", tmp)) cfg.soc_manifest_max_svn = static_cast<uint8_t>(tmp & 0xffu);
    json_get_bool(j, "anti_rollback_disable", cfg.anti_rollback_disable);
    json_get_u32_array4(j, "soc_manifest_svn", cfg.soc_manifest_svn);
    json_get_u32_array4(j, "fw_svn", cfg.fw_svn);

    std::string hex_s;
    if (json_get_string(j, "idevid_cert_attr", hex_s) && !hex_s.empty()) {
        std::vector<uint8_t> b;
        if (!parse_hex_bytes(hex_s, b, err)) return false;
        if (b.size() != 96) { err = "idevid_cert_attr must be 96 bytes (192 hex chars)"; return false; }
        for (int i = 0; i < 24; ++i) {
            cfg.idevid_cert_attr[i] = (uint32_t(b[i * 4]) << 24) | (uint32_t(b[i * 4 + 1]) << 16) |
                                      (uint32_t(b[i * 4 + 2]) << 8) | uint32_t(b[i * 4 + 3]);
        }
    }
    if (json_get_string(j, "idevid_manuf_hsm_id", hex_s) && !hex_s.empty()) {
        std::vector<uint8_t> b;
        if (!parse_hex_bytes(hex_s, b, err)) return false;
        if (b.size() != 16) { err = "idevid_manuf_hsm_id must be 16 bytes (32 hex chars)"; return false; }
        for (int i = 0; i < 4; ++i) {
            cfg.idevid_manuf_hsm_id[i] = (uint32_t(b[i * 4]) << 24) | (uint32_t(b[i * 4 + 1]) << 16) |
                                         (uint32_t(b[i * 4 + 2]) << 8) | uint32_t(b[i * 4 + 3]);
        }
    }
    if (json_get_string(j, "manuf_dbg_unlock_token", hex_s) && !hex_s.empty()) {
        std::vector<uint8_t> b;
        if (!parse_hex_bytes(hex_s, b, err)) return false;
        if (b.size() != 64) { err = "manuf_dbg_unlock_token must be 64 bytes (128 hex chars)"; return false; }
        for (int i = 0; i < 16; ++i) {
            cfg.manuf_dbg_unlock_token[i] = (uint32_t(b[i * 4]) << 24) | (uint32_t(b[i * 4 + 1]) << 16) |
                                            (uint32_t(b[i * 4 + 2]) << 8) | uint32_t(b[i * 4 + 3]);
        }
    }
    return true;
}

// ============================================================================
// Calightra Verilated RTL Simulation Engine
// ============================================================================

enum class BootPhase : int {
    UNINIT = 0,
    RESET = 1,
    FUSES = 2,
    ROM_BOOT = 3,
    ROM_IDLE = 4,
    FW_UPLOAD = 5,
    FW_VERIFY_AND_RT = 6,
    RUNTIME_READY = 7,
    EXITED = 8,
    FATAL_ERROR = 9
};

static const char* boot_phase_name(BootPhase p) {
    switch (p) {
        case BootPhase::UNINIT:           return "UNINIT";
        case BootPhase::RESET:            return "RESET";
        case BootPhase::FUSES:            return "FUSES";
        case BootPhase::ROM_BOOT:         return "ROM_BOOT";
        case BootPhase::ROM_IDLE:         return "ROM_IDLE";
        case BootPhase::FW_UPLOAD:        return "FW_UPLOAD";
        case BootPhase::FW_VERIFY_AND_RT: return "FW_VERIFY_AND_RT";
        case BootPhase::RUNTIME_READY:    return "RUNTIME_READY";
        case BootPhase::EXITED:           return "EXITED";
        case BootPhase::FATAL_ERROR:      return "FATAL_ERROR";
    }
    return "UNKNOWN";
}

enum class UserMboxState : int {
    IDLE = 0,
    LOCK_AND_HEADER = 1,
    WRITE_DATA = 2,
    WAIT_COMPLETE = 3,
    READ_RESP = 4,
    DONE_OK = 5,
    DONE_ERR = 6
};

struct CalightraSim {
    std::unique_ptr<VerilatedContext> ctxp;
    std::unique_ptr<Vcalightra_verilated_wasm> v;
    svScope dpi_scope = nullptr;

    BootPhase phase = BootPhase::UNINIT;
    int reset_substep = 0;

    uint64_t total_cycles = 0;
    uint64_t prev_uout = ~0ULL;
    bool prev_uout_valid = false;
    bool has_exited = false;
    bool passed = false;

    bool waiting_for_etrng_clear = false;
    uint32_t etrng_counter = 1;
    uint64_t itrng_lfsr = 0x243f6a8885a308d3ULL;

    // AXI pre-posedge sampled signals
    uint8_t pre_awready = 0;
    uint8_t pre_wready = 0;
    uint8_t pre_bvalid = 0;
    uint8_t pre_arready = 0;
    uint8_t pre_rvalid = 0;
    uint32_t pre_rdata = 0;

    // Fuse write queue (executed 1 register per loop iteration for smooth single-stepping)
    std::vector<std::pair<uint32_t, uint32_t>> fuse_queue;
    size_t fuse_queue_idx = 0;

    // Firmware bundle & chunked upload state
    std::vector<uint8_t> fw_bytes;
    int fw_upload_stage = 0;
    size_t fw_upload_word_idx = 0;
    bool fw_verify_mbox_cleared = false;
    uint32_t fw_verify_poll_countdown = 1000;

    // Debug unlock service register shadow & pending AXI write
    uint32_t dbg_service_reg_shadow = 0;
    bool has_pending_dbg_service_write = false;

    // Non-blocking user Mailbox transaction state
    UserMboxState user_mbox_state = UserMboxState::IDLE;
    uint32_t user_cmd = 0;
    std::vector<uint8_t> user_req;
    size_t user_req_word_idx = 0;
    uint32_t user_lock_retries = 0;
    uint32_t user_poll_countdown = 0;
    std::vector<uint8_t> user_resp;
    uint32_t user_resp_dlen = 0;
    size_t user_resp_word_idx = 0;

    // Output text & JSON scratch buffers
    std::string uart_delta;
    std::string uart_line_buf;
    std::string log_delta;
    std::string boot_error_msg;
    std::string last_error_msg;

    std::string out_uart_buf;
    std::string out_log_buf;
    std::string out_status_json;
    std::string out_errors_json;
    std::string out_kv_json;
    std::string out_fuses_json;

    void set_dpi_scope() {
        if (!dpi_scope) {
            dpi_scope = svGetScopeFromName("TOP.calightra_verilated_wasm");
            if (!dpi_scope) {
                dpi_scope = svGetScopeFromName("calightra_verilated_wasm");
            }
        }
        if (dpi_scope) {
            svSetScope(dpi_scope);
        }
    }

    void append_log_line(const std::string& msg) {
        char prefix[48];
        std::snprintf(prefix, sizeof(prefix), "[cyc %llu] ",
                      static_cast<unsigned long long>(total_cycles));
        log_delta += prefix;
        log_delta += msg;
        if (msg.empty() || msg.back() != '\n') {
            log_delta.push_back('\n');
        }
    }

    void raw_cycle() {
        total_cycles++;

        // Feed deterministic pseudo-random nibble to internal TRNG pins
        itrng_lfsr ^= itrng_lfsr >> 12;
        itrng_lfsr ^= itrng_lfsr << 25;
        itrng_lfsr ^= itrng_lfsr >> 27;
        uint64_t rnd = itrng_lfsr * 0x2545F4914F6CDD1DULL;
        v->itrng_data = static_cast<uint8_t>(rnd & 0xfu);
        v->itrng_valid = 1;

        v->core_clk = 0;
        v->eval();

        pre_awready = v->s_axi_awready;
        pre_wready  = v->s_axi_wready;
        pre_bvalid  = v->s_axi_bvalid;
        pre_arready = v->s_axi_arready;
        pre_rvalid  = v->s_axi_rvalid;
        pre_rdata   = v->s_axi_rdata;

        v->core_clk = 1;
        v->eval();

        // Monitor generic_output_wires[8:0] for UART TX and test exit codes
        uint64_t uout = v->generic_output_wires & 0x1ffULL;
        if (!prev_uout_valid || uout != prev_uout) {
            if (prev_uout_valid) {
                uint8_t byte = static_cast<uint8_t>(uout & 0xffu);
                if (byte == 0xffu) {
                    has_exited = true;
                    passed = true;
                    append_log_line("[RTL] Firmware signaled TEST_EXIT PASS (0xff)");
                } else if (byte == 0x01u) {
                    has_exited = true;
                    passed = false;
                    append_log_line("[RTL] Firmware signaled TEST_EXIT FAIL (0x01)");
                } else if (byte != 0x00u) {
                    char c = static_cast<char>(byte);
                    uart_delta.push_back(c);
                    if (c == '\n') {
                        append_log_line("[UART] " + uart_line_buf);
                        uart_line_buf.clear();
                    } else if (c != '\r') {
                        uart_line_buf.push_back(c);
                    }
                }
            }
            prev_uout = uout;
            prev_uout_valid = true;
        }
    }

    uint32_t axi_read_u32(uint32_t addr, uint32_t user = DEFAULT_AXI_USER) {
        v->s_axi_araddr  = addr;
        v->s_axi_aruser  = user;
        v->s_axi_arid    = 0;
        v->s_axi_arlen   = 0;
        v->s_axi_arsize  = 2;
        v->s_axi_arburst = 1;
        v->s_axi_arlock  = 0;
        v->s_axi_arvalid = 1;
        v->s_axi_rready  = 1;

        for (int guard = 0; guard < 4096; ++guard) {
            raw_cycle();
            if (pre_arready) break;
        }
        v->s_axi_arvalid = 0;

        for (int guard = 0; guard < 4096 && !pre_rvalid; ++guard) {
            raw_cycle();
        }
        uint32_t rdata = pre_rdata;
        v->s_axi_rready = 0;
        return rdata;
    }

    void axi_write_u32(uint32_t addr, uint32_t data, uint32_t user = DEFAULT_AXI_USER) {
        v->s_axi_awaddr  = addr;
        v->s_axi_awuser  = user;
        v->s_axi_awid    = 0;
        v->s_axi_awlen   = 0;
        v->s_axi_awsize  = 2;
        v->s_axi_awburst = 1;
        v->s_axi_awlock  = 0;
        v->s_axi_awvalid = 1;

        v->s_axi_wdata  = data;
        v->s_axi_wstrb  = 0xf;
        v->s_axi_wvalid = 1;
        v->s_axi_wlast  = 1;
        v->s_axi_bready = 1;

        bool aw_done = false;
        bool w_done = false;
        for (int guard = 0; guard < 4096; ++guard) {
            raw_cycle();
            if (!aw_done && pre_awready) {
                aw_done = true;
                v->s_axi_awvalid = 0;
            }
            if (!w_done && pre_wready) {
                w_done = true;
                v->s_axi_wvalid = 0;
            }
            if (aw_done && w_done) break;
        }

        for (int guard = 0; guard < 4096 && !pre_bvalid; ++guard) {
            raw_cycle();
        }
        v->s_axi_bready = 0;
    }

    void process_etrng() {
        if (waiting_for_etrng_clear && !v->etrng_req) {
            waiting_for_etrng_clear = false;
        }
        if (v->etrng_req && !waiting_for_etrng_clear) {
            waiting_for_etrng_clear = true;
            for (uint32_t i = 0; i < 12; ++i) {
                uint32_t val = (0x9e3779b9u * (etrng_counter * 13u + i + 1u)) ^ (0x6a09e667u + i);
                axi_write_u32(CLP_SOC_IFC_REG_CPTRA_TRNG_DATA_0 + i * 4, val);
            }
            uint32_t req_num = etrng_counter++;
            axi_write_u32(CLP_SOC_IFC_REG_CPTRA_TRNG_STATUS, 0x2u);
            char msg[96];
            std::snprintf(msg, sizeof(msg), "[ETRNG] Serviced entropy request #%u", req_num);
            append_log_line(msg);
        }
    }

    void step_one() {
        raw_cycle();
        process_etrng();
    }

    void build_fuse_queue(const uint32_t vendor_pk[12], const uint32_t owner_pk[12], const FuseConfig& cfg) {
        fuse_queue.clear();
        fuse_queue_idx = 0;

        // Watchdog timeout configuration
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_WDT_CFG_0, 0x0FFFFFFFu);
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_WDT_CFG_1, 0x00000000u);

        // Mailbox valid AXI users (0..4) + lock
        for (uint32_t i = 0; i < 5; ++i) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_MBOX_VALID_AXI_USER_0 + i * 4, i);
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_MBOX_AXI_USER_LOCK_0 + i * 4, 1u);
        }

        // Fuse valid AXI user + lock
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_FUSE_VALID_AXI_USER, DEFAULT_AXI_USER);
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_FUSE_AXI_USER_LOCK, 1u);

        // Deterministic UDS Seed & Field Entropy
        static const uint32_t default_uds_seed[16] = {
            0x00010203u, 0x04050607u, 0x08090a0bu, 0x0c0d0e0fu,
            0x10111213u, 0x14151617u, 0x18191a1bu, 0x1c1d1e1fu,
            0x20212223u, 0x24252627u, 0x28292a2bu, 0x2c2d2e2fu,
            0x30313233u, 0x34353637u, 0x38393a3bu, 0x3c3d3e3fu
        };
        static const uint32_t default_field_entropy[8] = {
            0x80818283u, 0x84858687u, 0x88898a8bu, 0x8c8d8e8fu,
            0x90919293u, 0x94959697u, 0x98999a9bu, 0x9c9d9e9fu
        };
        for (uint32_t i = 0; i < 16; ++i) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_UDS_SEED_0 + i * 4, default_uds_seed[i]);
        }
        for (uint32_t i = 0; i < 8; ++i) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_FIELD_ENTROPY_0 + i * 4, default_field_entropy[i]);
        }

        // Vendor & Owner PK hashes
        for (uint32_t i = 0; i < 12; ++i) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_VENDOR_PK_HASH_0 + i * 4, vendor_pk[i]);
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_OWNER_PK_HASH_0 + i * 4, owner_pk[i]);
        }

        // User-configurable fuses
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_PQC_KEY_TYPE, cfg.fuse_pqc_key_type);
        if (cfg.fuse_ecc_revocation != 0) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_ECC_REVOCATION, cfg.fuse_ecc_revocation);
        }
        if (cfg.fuse_lms_revocation != 0) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_LMS_REVOCATION, cfg.fuse_lms_revocation);
        }
        if (cfg.fuse_mldsa_revocation != 0) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_MLDSA_REVOCATION, cfg.fuse_mldsa_revocation);
        }
        if (cfg.anti_rollback_disable) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_ANTI_ROLLBACK_DISABLE, 1u);
        }
        if (cfg.soc_stepping_id != 0) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_SOC_STEPPING_ID, cfg.soc_stepping_id);
        }
        if (cfg.soc_manifest_max_svn != 0) {
            fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_SOC_MANIFEST_MAX_SVN, cfg.soc_manifest_max_svn);
        }
        for (uint32_t i = 0; i < 4; ++i) {
            if (cfg.soc_manifest_svn[i] != 0) {
                fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_SOC_MANIFEST_SVN_0 + i * 4, cfg.soc_manifest_svn[i]);
            }
            if (cfg.fw_svn[i] != 0) {
                fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_RUNTIME_SVN_0 + i * 4, cfg.fw_svn[i]);
            }
            if (cfg.idevid_manuf_hsm_id[i] != 0) {
                fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_IDEVID_MANUF_HSM_ID_0 + i * 4, cfg.idevid_manuf_hsm_id[i]);
            }
        }
        for (uint32_t i = 0; i < 24; ++i) {
            if (cfg.idevid_cert_attr[i] != 0) {
                fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_IDEVID_CERT_ATTR_0 + i * 4, cfg.idevid_cert_attr[i]);
            }
        }
        for (uint32_t i = 0; i < 16; ++i) {
            if (cfg.manuf_dbg_unlock_token[i] != 0) {
                fuse_queue.emplace_back(CLP_SOC_IFC_REG_FUSE_MANUF_DBG_UNLOCK_TOKEN_0 + i * 4, cfg.manuf_dbg_unlock_token[i]);
            }
        }

        // Complete fuse programming & trigger BootFSM
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_FUSE_WR_DONE, 1u);
        fuse_queue.emplace_back(CLP_SOC_IFC_REG_CPTRA_BOOTFSM_GO, 1u);
    }

    int init(const uint8_t* rom_ptr, uint32_t rom_len,
             const uint8_t* fw_ptr, uint32_t fw_len,
             const char* vendor_pk_hex, const char* owner_pk_hex,
             const char* lifecycle_str, int debug_intent,
             const char* fuses_json) {
        last_error_msg.clear();
        boot_error_msg.clear();

        if (!rom_ptr || rom_len == 0) {
            last_error_msg = "ROM image is empty";
            return -1;
        }

        uint32_t vendor_pk[12] = {0};
        uint32_t owner_pk[12] = {0};
        if (!parse_pk_hash_words(vendor_pk_hex, vendor_pk, last_error_msg)) return -1;
        if (!parse_pk_hash_words(owner_pk_hex, owner_pk, last_error_msg)) return -1;

        FuseConfig fuse_cfg;
        if (!parse_fuse_config(fuses_json, fuse_cfg, last_error_msg)) return -1;

        uint8_t lc_bits = 1u; // Default Manufacturing
        if (lifecycle_str) {
            std::string lc(lifecycle_str);
            for (char& c : lc) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            if (lc == "unprovisioned") lc_bits = 0u;
            else if (lc == "manufacturing") lc_bits = 1u;
            else if (lc == "production") lc_bits = 3u;
        }
        // security_state_t: bit [2] = debug_locked, bits [1:0] = device_lifecycle.
        // Matching caliptra-wasm, enabling debug_intent sets both debug_locked and ss_debug_intent
        // straps so debug unlock flows can be exercised.
        uint8_t sec_state = static_cast<uint8_t>(((debug_intent ? 1u : 0u) << 2) | (lc_bits & 0x3u));

        // Reset all state before instantiating fresh Verilator model
        v.reset();
        ctxp = std::make_unique<VerilatedContext>();
        ctxp->randReset(0);
        v = std::make_unique<Vcalightra_verilated_wasm>(ctxp.get());
        dpi_scope = nullptr;

        v->core_clk = 0;
        v->cptra_pwrgood = 0;
        v->cptra_rst_b = 0;
        v->security_state = sec_state;
        v->ss_debug_intent = debug_intent ? 1 : 0;
        v->sram_error_injection_mode = 0;
        v->ext_imem_we = 0;
        v->ext_iccm_we = 0;
        v->ext_dccm_we = 0;
        v->ext_mbox_we = 0;

        for (int i = 0; i < 8; ++i) {
            v->cptra_obf_key[i] = 0xdeadbeefu;
        }
        for (int i = 0; i < 16; ++i) {
            v->cptra_csr_hmac_key[i] = 0x11111111u * static_cast<uint32_t>(i + 1);
        }

        v->eval();

        // Clock 16 cold-reset cycles with cptra_pwrgood=0 and cptra_rst_b=0 so all
        // synchronous/asynchronous reset trees (cptra_pwrgood and cptra_noncore_rst_b)
        // settle to their true RTL reset values (e.g. WDT timeout periods = 0xFFFFFFFF)
        // rather than Verilator randReset(0) zeros before cptra_pwrgood rises.
        for (int i = 0; i < 16; ++i) {
            v->core_clk = 0;
            v->eval();
            v->core_clk = 1;
            v->eval();
        }
        v->core_clk = 0;
        v->eval();
        set_dpi_scope();

        // Zero-cycle ROM preload into IMEM via DPI backdoor
        uint32_t padded_words = (rom_len + 7u) / 8u;
        for (uint32_t w = 0; w < padded_words; ++w) {
            uint64_t word = 0;
            size_t base = size_t(w) * 8u;
            for (size_t b = 0; b < 8 && (base + b) < rom_len; ++b) {
                word |= uint64_t(rom_ptr[base + b]) << (b * 8);
            }
            wasm_write_rom_u64(static_cast<int>(w),
                               static_cast<uint32_t>(word & 0xffffffffULL),
                               static_cast<uint32_t>(word >> 32));
        }

        if (fw_ptr && fw_len > 0) {
            fw_bytes.assign(fw_ptr, fw_ptr + fw_len);
        } else {
            fw_bytes.clear();
        }

        build_fuse_queue(vendor_pk, owner_pk, fuse_cfg);

        phase = BootPhase::RESET;
        reset_substep = 0;
        total_cycles = 0;
        prev_uout = ~0ULL;
        prev_uout_valid = false;
        has_exited = false;
        passed = false;
        waiting_for_etrng_clear = false;
        etrng_counter = 1;
        itrng_lfsr = 0x243f6a8885a308d3ULL;

        fw_upload_stage = 0;
        fw_upload_word_idx = 0;
        fw_verify_mbox_cleared = false;
        fw_verify_poll_countdown = 1000;

        dbg_service_reg_shadow = 0;
        has_pending_dbg_service_write = false;
        user_mbox_state = UserMboxState::IDLE;
        user_resp.clear();

        uart_delta.clear();
        uart_line_buf.clear();
        log_delta.clear();

        char init_msg[192];
        std::snprintf(init_msg, sizeof(init_msg),
                      "[RTL] Initialized Verilated Calightra Core (stripped Caliptra 2.1 RTL, ROM=%u B, FW=%zu B, security_state=0x%x)",
                      rom_len, fw_bytes.size(), unsigned(sec_state));
        append_log_line(init_msg);
        return 0;
    }

    void step_user_mailbox(uint64_t target_cycles) {
        switch (user_mbox_state) {
            case UserMboxState::LOCK_AND_HEADER: {
                uint32_t lock_val = axi_read_u32(CLP_MBOX_CSR_MBOX_LOCK);
                if (lock_val != 0) {
                    user_lock_retries++;
                    if (user_lock_retries > 50000) {
                        last_error_msg = "Timed out waiting to acquire MBOX_LOCK";
                        user_mbox_state = UserMboxState::DONE_ERR;
                        return;
                    }
                    step_one();
                    return;
                }
                axi_write_u32(CLP_MBOX_CSR_MBOX_CMD, user_cmd);
                axi_write_u32(CLP_MBOX_CSR_MBOX_DLEN, static_cast<uint32_t>(user_req.size()));
                user_req_word_idx = 0;
                user_mbox_state = UserMboxState::WRITE_DATA;
                break;
            }
            case UserMboxState::WRITE_DATA: {
                size_t num_words = (user_req.size() + 3u) / 4u;
                while (user_req_word_idx < num_words && total_cycles < target_cycles) {
                    uint32_t word = 0;
                    size_t base = user_req_word_idx * 4u;
                    for (size_t b = 0; b < 4 && (base + b) < user_req.size(); ++b) {
                        word |= uint32_t(user_req[base + b]) << (b * 8);
                    }
                    axi_write_u32(CLP_MBOX_CSR_MBOX_DATAIN, word);
                    process_etrng();
                    user_req_word_idx++;
                }
                if (user_req_word_idx >= num_words) {
                    axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 1u);
                    user_poll_countdown = 64;
                    user_mbox_state = UserMboxState::WAIT_COMPLETE;
                }
                break;
            }
            case UserMboxState::WAIT_COMPLETE: {
                step_one();
                if (user_poll_countdown > 0) user_poll_countdown--;
                if (user_poll_countdown == 0 || v->mailbox_data_avail) {
                    uint32_t st = axi_read_u32(CLP_MBOX_CSR_MBOX_STATUS) & 0xfu;
                    if (st == 0u) { // CMD_BUSY
                        user_poll_countdown = 128;
                    } else if (st == 1u) { // DATA_READY
                        user_resp_dlen = axi_read_u32(CLP_MBOX_CSR_MBOX_DLEN);
                        user_resp.assign(user_resp_dlen, 0);
                        user_resp_word_idx = 0;
                        user_mbox_state = UserMboxState::READ_RESP;
                    } else if (st == 2u) { // CMD_COMPLETE (no response payload)
                        user_resp.clear();
                        user_resp_dlen = 0;
                        axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                        step_one();
                        user_mbox_state = UserMboxState::DONE_OK;
                    } else { // CMD_FAILURE or unexpected
                        axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                        step_one();
                        char buf[96];
                        std::snprintf(buf, sizeof(buf), "Mailbox command 0x%08x failed (MBOX_STATUS=0x%x)", user_cmd, st);
                        last_error_msg = buf;
                        user_mbox_state = UserMboxState::DONE_ERR;
                    }
                }
                break;
            }
            case UserMboxState::READ_RESP: {
                size_t num_words = (size_t(user_resp_dlen) + 3u) / 4u;
                while (user_resp_word_idx < num_words && total_cycles < target_cycles) {
                    uint32_t w = axi_read_u32(CLP_MBOX_CSR_MBOX_DATAOUT);
                    size_t base = user_resp_word_idx * 4u;
                    for (size_t b = 0; b < 4 && (base + b) < user_resp.size(); ++b) {
                        user_resp[base + b] = static_cast<uint8_t>((w >> (b * 8)) & 0xffu);
                    }
                    process_etrng();
                    user_resp_word_idx++;
                }
                if (user_resp_word_idx >= num_words) {
                    axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                    step_one();
                    user_mbox_state = UserMboxState::DONE_OK;
                }
                break;
            }
            default:
                break;
        }
    }

    int step(uint32_t max_cycles) {
        if (!v || phase == BootPhase::UNINIT) return 0;
        if (has_exited || phase == BootPhase::FATAL_ERROR) return 0;
        if (max_cycles == 0) return 1;

        uint64_t target_cycles = total_cycles + max_cycles;

        while (total_cycles < target_cycles) {
            if (has_exited) {
                phase = BootPhase::EXITED;
                return 0;
            }

            if (v->cptra_error_fatal) {
                set_dpi_scope();
                uint32_t hw_err = wasm_peek_status_reg(2);
                uint32_t fw_err = wasm_peek_status_reg(4);
                uint32_t bst    = wasm_peek_status_reg(0);
                char msg[160];
                std::snprintf(msg, sizeof(msg),
                              "Hardware fatal error asserted (HW_ERR=0x%08x, FW_ERR=0x%08x, BOOT_STATUS=0x%08x)",
                              hw_err, fw_err, bst);
                boot_error_msg = msg;
                last_error_msg = msg;
                append_log_line(std::string("[FATAL] ") + msg);
                if (user_mbox_state != UserMboxState::IDLE &&
                    user_mbox_state != UserMboxState::DONE_OK &&
                    user_mbox_state != UserMboxState::DONE_ERR) {
                    user_mbox_state = UserMboxState::DONE_ERR;
                }
                phase = BootPhase::FATAL_ERROR;
                return 0;
            }

            // Flush any pending debug unlock service register write before mailbox ops
            if (has_pending_dbg_service_write && phase >= BootPhase::ROM_BOOT) {
                has_pending_dbg_service_write = false;
                axi_write_u32(CLP_SOC_IFC_REG_SS_DBG_SERVICE_REG_REQ, dbg_service_reg_shadow);
                continue;
            }

            // Active user mailbox command takes priority over idle stepping
            if (user_mbox_state == UserMboxState::LOCK_AND_HEADER ||
                user_mbox_state == UserMboxState::WRITE_DATA ||
                user_mbox_state == UserMboxState::WAIT_COMPLETE ||
                user_mbox_state == UserMboxState::READ_RESP) {
                step_user_mailbox(target_cycles);
                if (v->ready_for_runtime && phase == BootPhase::ROM_IDLE) {
                    phase = BootPhase::RUNTIME_READY;
                }
                continue;
            }

            switch (phase) {
                case BootPhase::RESET: {
                    if (reset_substep < 8) {
                        v->cptra_pwrgood = 1;
                        v->cptra_rst_b = 0;
                        raw_cycle();
                        reset_substep++;
                    } else if (reset_substep == 8) {
                        v->cptra_rst_b = 1;
                        raw_cycle();
                        reset_substep = 9;
                    } else {
                        if (v->ready_for_fuses) {
                            append_log_line("[RTL] ready_for_fuses asserted; programming fuses over AXI");
                            phase = BootPhase::FUSES;
                        } else {
                            raw_cycle();
                        }
                    }
                    break;
                }

                case BootPhase::FUSES: {
                    if (fuse_queue_idx < fuse_queue.size()) {
                        auto kv = fuse_queue[fuse_queue_idx++];
                        axi_write_u32(kv.first, kv.second);
                    }
                    if (fuse_queue_idx >= fuse_queue.size()) {
                        append_log_line("[RTL] Fuses locked & CPTRA_BOOTFSM_GO=1; booting Caliptra 2.1 ROM");
                        phase = BootPhase::ROM_BOOT;
                    }
                    break;
                }

                case BootPhase::ROM_BOOT: {
                    if (v->ready_for_mb_processing) {
                        if (fw_bytes.empty()) {
                            append_log_line("[RTL] ready_for_mb_processing asserted (ROM-only mode; mailbox ready)");
                            phase = BootPhase::ROM_IDLE;
                            return 1; // Yield immediately on milestone transition
                        } else {
                            char msg[128];
                            std::snprintf(msg, sizeof(msg),
                                          "[RTL] ready_for_mb_processing asserted; uploading FW_LOAD (%zu bytes)",
                                          fw_bytes.size());
                            append_log_line(msg);
                            fw_upload_stage = 0;
                            fw_upload_word_idx = 0;
                            phase = BootPhase::FW_UPLOAD;
                        }
                    } else {
                        step_one();
                    }
                    break;
                }

                case BootPhase::FW_UPLOAD: {
                    if (fw_upload_stage == 0) {
                        uint32_t lock_val = axi_read_u32(CLP_MBOX_CSR_MBOX_LOCK);
                        if (lock_val == 0) {
                            axi_write_u32(CLP_MBOX_CSR_MBOX_CMD, CMD_FIRMWARE_LOAD);
                            axi_write_u32(CLP_MBOX_CSR_MBOX_DLEN, static_cast<uint32_t>(fw_bytes.size()));
                            fw_upload_stage = 1;
                        } else {
                            step_one();
                        }
                    } else {
                        size_t num_words = (fw_bytes.size() + 3u) / 4u;
                        while (fw_upload_word_idx < num_words && total_cycles < target_cycles) {
                            uint32_t word = 0;
                            size_t base = fw_upload_word_idx * 4u;
                            for (size_t b = 0; b < 4 && (base + b) < fw_bytes.size(); ++b) {
                                word |= uint32_t(fw_bytes[base + b]) << (b * 8);
                            }
                            axi_write_u32(CLP_MBOX_CSR_MBOX_DATAIN, word);
                            process_etrng();
                            fw_upload_word_idx++;
                        }
                        if (fw_upload_word_idx >= num_words) {
                            axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 1u);
                            fw_verify_mbox_cleared = false;
                            fw_verify_poll_countdown = 1000;
                            append_log_line("[RTL] FW_LOAD uploaded to Mailbox SRAM; MBOX_EXECUTE=1");
                            phase = BootPhase::FW_VERIFY_AND_RT;
                        }
                    }
                    break;
                }

                case BootPhase::FW_VERIFY_AND_RT: {
                    if (v->ready_for_runtime) {
                        if (!fw_verify_mbox_cleared) {
                            axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                            fw_verify_mbox_cleared = true;
                        }
                        append_log_line("[RTL] ready_for_runtime asserted — Caliptra 2.1 Runtime is live!");
                        phase = BootPhase::RUNTIME_READY;
                        return 1; // Yield immediately on milestone transition
                    }
                    step_one();
                    if (!fw_verify_mbox_cleared) {
                        if (fw_verify_poll_countdown > 0) fw_verify_poll_countdown--;
                        if (fw_verify_poll_countdown == 0) {
                            fw_verify_poll_countdown = 1000;
                            uint32_t st = axi_read_u32(CLP_MBOX_CSR_MBOX_STATUS) & 0xfu;
                            if (st == 2u || st == 1u) {
                                axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                                fw_verify_mbox_cleared = true;
                                append_log_line("[RTL] ROM completed FW_LOAD (MBOX_STATUS=CMD_COMPLETE); booting FMC & Runtime");
                            } else if (st != 0u) {
                                axi_write_u32(CLP_MBOX_CSR_MBOX_EXECUTE, 0u);
                                fw_verify_mbox_cleared = true;
                                char msg[128];
                                std::snprintf(msg, sizeof(msg),
                                              "ROM rejected FW_LOAD (MBOX_STATUS=0x%x) — check PK hashes and fuse settings",
                                              st);
                                boot_error_msg = msg;
                                append_log_line(std::string("[ERROR] ") + msg);
                                phase = BootPhase::ROM_IDLE;
                                return 1;
                            }
                        }
                    }
                    break;
                }

                case BootPhase::ROM_IDLE: {
                    step_one();
                    if (v->ready_for_runtime) {
                        append_log_line("[RTL] ready_for_runtime asserted — Caliptra 2.1 Runtime is live!");
                        phase = BootPhase::RUNTIME_READY;
                        return 1;
                    }
                    break;
                }

                case BootPhase::RUNTIME_READY: {
                    step_one();
                    break;
                }

                default:
                    return 0;
            }
        }

        return (has_exited || phase == BootPhase::FATAL_ERROR) ? 0 : 1;
    }
};

static CalightraSim g_sim;
static std::string g_pk_hashes_json;

} // namespace

// ============================================================================
// Exported C API for Emscripten / Web Worker
// ============================================================================

extern "C" {

EMSCRIPTEN_KEEPALIVE
int calightra_init(const uint8_t* rom_ptr, uint32_t rom_len,
                   const uint8_t* fw_ptr, uint32_t fw_len,
                   const char* vendor_pk_hex, const char* owner_pk_hex,
                   const char* lifecycle_str, int debug_intent,
                   const char* fuses_json) {
    return g_sim.init(rom_ptr, rom_len, fw_ptr, fw_len,
                      vendor_pk_hex, owner_pk_hex,
                      lifecycle_str, debug_intent, fuses_json);
}

EMSCRIPTEN_KEEPALIVE
void calightra_destroy() {
    g_sim.v.reset();
    g_sim.ctxp.reset();
    g_sim.dpi_scope = nullptr;
    g_sim.phase = BootPhase::UNINIT;
}

EMSCRIPTEN_KEEPALIVE
int calightra_step(uint32_t max_cycles) {
    return g_sim.step(max_cycles);
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_last_error() {
    return g_sim.last_error_msg.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_take_uart() {
    g_sim.out_uart_buf.swap(g_sim.uart_delta);
    g_sim.uart_delta.clear();
    return g_sim.out_uart_buf.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_take_log() {
    g_sim.out_log_buf.swap(g_sim.log_delta);
    g_sim.log_delta.clear();
    return g_sim.out_log_buf.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_get_status_json() {
    if (!g_sim.v || g_sim.phase == BootPhase::UNINIT) {
        g_sim.out_status_json = "{\"initialized\":false}";
        return g_sim.out_status_json.c_str();
    }
    g_sim.set_dpi_scope();
    uint32_t boot_st = wasm_peek_status_reg(0);
    uint32_t flow_st = wasm_peek_status_reg(1);

    size_t uploaded_bytes = g_sim.fw_upload_word_idx * 4u;
    if (uploaded_bytes > g_sim.fw_bytes.size()) uploaded_bytes = g_sim.fw_bytes.size();
    if (g_sim.phase > BootPhase::FW_UPLOAD) uploaded_bytes = g_sim.fw_bytes.size();

    bool mbox_busy = (g_sim.user_mbox_state == UserMboxState::LOCK_AND_HEADER ||
                      g_sim.user_mbox_state == UserMboxState::WRITE_DATA ||
                      g_sim.user_mbox_state == UserMboxState::WAIT_COMPLETE ||
                      g_sim.user_mbox_state == UserMboxState::READ_RESP);

    char buf[768];
    std::snprintf(
        buf, sizeof(buf),
        "{\"initialized\":true,"
        "\"total_cycles\":%llu,"
        "\"phase\":\"%s\","
        "\"fw_upload_bytes\":%zu,"
        "\"fw_total_bytes\":%zu,"
        "\"cptra_pwrgood\":%u,"
        "\"cptra_rst_b\":%u,"
        "\"ready_for_fuses\":%u,"
        "\"ready_for_mb_processing\":%u,"
        "\"ready_for_runtime\":%u,"
        "\"mailbox_data_avail\":%u,"
        "\"mailbox_flow_done\":%u,"
        "\"cptra_error_fatal\":%u,"
        "\"cptra_error_non_fatal\":%u,"
        "\"etrng_req\":%u,"
        "\"boot_status\":\"0x%08x\","
        "\"flow_status\":\"0x%08x\","
        "\"has_exited\":%s,"
        "\"passed\":%s,"
        "\"mbox_busy\":%s,",
        static_cast<unsigned long long>(g_sim.total_cycles),
        boot_phase_name(g_sim.phase),
        uploaded_bytes,
        g_sim.fw_bytes.size(),
        unsigned(g_sim.v->cptra_pwrgood),
        unsigned(g_sim.v->cptra_rst_b),
        unsigned(g_sim.v->ready_for_fuses),
        unsigned(g_sim.v->ready_for_mb_processing),
        unsigned(g_sim.v->ready_for_runtime),
        unsigned(g_sim.v->mailbox_data_avail),
        unsigned(g_sim.v->mailbox_flow_done),
        unsigned(g_sim.v->cptra_error_fatal),
        unsigned(g_sim.v->cptra_error_non_fatal),
        unsigned(g_sim.v->etrng_req),
        boot_st,
        flow_st,
        g_sim.has_exited ? "true" : "false",
        g_sim.passed ? "true" : "false",
        mbox_busy ? "true" : "false"
    );

    g_sim.out_status_json = buf;
    g_sim.out_status_json += "\"boot_error\":\"";
    g_sim.out_status_json += json_escape(g_sim.boot_error_msg);
    g_sim.out_status_json += "\"}";
    return g_sim.out_status_json.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_get_errors_json() {
    if (!g_sim.v || g_sim.phase == BootPhase::UNINIT) {
        g_sim.out_errors_json =
            "{\"cptra_hw_error_fatal\":\"0x00000000\",\"cptra_hw_error_non_fatal\":\"0x00000000\","
            "\"cptra_fw_error_fatal\":\"0x00000000\",\"cptra_fw_error_non_fatal\":\"0x00000000\","
            "\"cptra_fw_extended_error_info\":[\"0x00000000\",\"0x00000000\",\"0x00000000\",\"0x00000000\","
            "\"0x00000000\",\"0x00000000\",\"0x00000000\",\"0x00000000\"]}";
        return g_sim.out_errors_json.c_str();
    }
    g_sim.set_dpi_scope();
    uint32_t hw_fatal     = wasm_peek_status_reg(2);
    uint32_t hw_non_fatal = wasm_peek_status_reg(3);
    uint32_t fw_fatal     = wasm_peek_status_reg(4);
    uint32_t fw_non_fatal = wasm_peek_status_reg(5);
    uint32_t ext[8];
    for (int i = 0; i < 8; ++i) {
        ext[i] = wasm_peek_status_reg(6 + i);
    }
    char buf[512];
    std::snprintf(
        buf, sizeof(buf),
        "{\"cptra_hw_error_fatal\":\"0x%08x\",\"cptra_hw_error_non_fatal\":\"0x%08x\","
        "\"cptra_fw_error_fatal\":\"0x%08x\",\"cptra_fw_error_non_fatal\":\"0x%08x\","
        "\"cptra_fw_extended_error_info\":[\"0x%08x\",\"0x%08x\",\"0x%08x\",\"0x%08x\","
        "\"0x%08x\",\"0x%08x\",\"0x%08x\",\"0x%08x\"]}",
        hw_fatal, hw_non_fatal, fw_fatal, fw_non_fatal,
        ext[0], ext[1], ext[2], ext[3], ext[4], ext[5], ext[6], ext[7]
    );
    g_sim.out_errors_json = buf;
    return g_sim.out_errors_json.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_get_keyvault_json() {
    if (!g_sim.v || g_sim.phase == BootPhase::UNINIT) {
        g_sim.out_kv_json = "{\"keys\":[],\"key_control\":[],\"pcrs\":[],\"pcr_control\":[]}";
        return g_sim.out_kv_json.c_str();
    }
    g_sim.set_dpi_scope();
    std::string& out = g_sim.out_kv_json;
    out.clear();
    out.reserve(9000);
    out += "{\"keys\":[";

    char hexbuf[16];
    for (int slot = 0; slot < 24; ++slot) {
        if (slot > 0) out.push_back(',');
        out.push_back('"');
        uint8_t key_bytes[64];
        for (int dw = 0; dw < 16; ++dw) {
            uint32_t w = wasm_peek_kv_entry(slot, dw);
            key_bytes[dw * 4 + 0] = static_cast<uint8_t>(w & 0xffu);
            key_bytes[dw * 4 + 1] = static_cast<uint8_t>((w >> 8) & 0xffu);
            key_bytes[dw * 4 + 2] = static_cast<uint8_t>((w >> 16) & 0xffu);
            key_bytes[dw * 4 + 3] = static_cast<uint8_t>((w >> 24) & 0xffu);
        }
        out += bytes_to_hex(key_bytes, 64);
        out.push_back('"');
    }

    out += "],\"key_control\":[";
    for (int slot = 0; slot < 24; ++slot) {
        if (slot > 0) out.push_back(',');
        std::snprintf(hexbuf, sizeof(hexbuf), "\"0x%08x\"", wasm_peek_kv_ctrl(slot));
        out += hexbuf;
    }

    out += "],\"pcrs\":[";
    for (int slot = 0; slot < 32; ++slot) {
        if (slot > 0) out.push_back(',');
        out.push_back('"');
        uint8_t pcr_bytes[48];
        for (int dw = 0; dw < 12; ++dw) {
            uint32_t w = wasm_peek_pcr_entry(slot, dw);
            pcr_bytes[dw * 4 + 0] = static_cast<uint8_t>(w & 0xffu);
            pcr_bytes[dw * 4 + 1] = static_cast<uint8_t>((w >> 8) & 0xffu);
            pcr_bytes[dw * 4 + 2] = static_cast<uint8_t>((w >> 16) & 0xffu);
            pcr_bytes[dw * 4 + 3] = static_cast<uint8_t>((w >> 24) & 0xffu);
        }
        out += bytes_to_hex(pcr_bytes, 48);
        out.push_back('"');
    }

    out += "],\"pcr_control\":[";
    for (int slot = 0; slot < 32; ++slot) {
        if (slot > 0) out.push_back(',');
        std::snprintf(hexbuf, sizeof(hexbuf), "\"0x%08x\"", wasm_peek_pcr_ctrl(slot));
        out += hexbuf;
    }

    out += "]}";
    return out.c_str();
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_get_fuses_json() {
    if (!g_sim.v || g_sim.phase == BootPhase::UNINIT) {
        g_sim.out_fuses_json = "{}";
        return g_sim.out_fuses_json.c_str();
    }
    g_sim.set_dpi_scope();
    std::string& json = g_sim.out_fuses_json;
    json = "{";
    bool first = true;
    char entry[96];

    auto add_arr = [&](const char* name, int id, int count) {
        for (int i = 0; i < count; ++i) {
            if (!first) json.push_back(',');
            first = false;
            std::snprintf(entry, sizeof(entry), "\"%s[%d]\":\"0x%08x\"",
                          name, i, wasm_peek_fuse_reg(id, i));
            json += entry;
        }
    };
    auto add_scalar = [&](const char* name, int id) {
        if (!first) json.push_back(',');
        first = false;
        std::snprintf(entry, sizeof(entry), "\"%s\":\"0x%08x\"",
                      name, wasm_peek_fuse_reg(id, 0));
        json += entry;
    };

    add_arr("fuse_vendor_pk_hash", 0, 12);
    add_arr("cptra_owner_pk_hash", 1, 12);
    add_scalar("fuse_ecc_revocation", 2);
    add_scalar("fuse_fmc_key_manifest_svn", 3);
    add_arr("fuse_runtime_svn", 4, 4);
    add_scalar("fuse_anti_rollback_disable", 5);
    add_arr("fuse_idevid_cert_attr", 6, 24);
    add_arr("fuse_idevid_manuf_hsm_id", 7, 4);
    add_scalar("fuse_lms_revocation", 8);
    add_scalar("fuse_mldsa_revocation", 9);
    add_scalar("fuse_soc_stepping_id", 10);
    add_arr("fuse_manuf_dbg_unlock_token", 11, 16);
    add_scalar("fuse_pqc_key_type", 12);
    add_arr("fuse_soc_manifest_svn", 13, 4);
    add_scalar("fuse_soc_manifest_max_svn", 14);

    json.push_back('}');
    return json.c_str();
}

EMSCRIPTEN_KEEPALIVE
int calightra_mailbox_start(uint32_t cmd, const uint8_t* req_ptr, uint32_t req_len) {
    if (!g_sim.v || g_sim.phase == BootPhase::UNINIT) {
        g_sim.last_error_msg = "Simulator is not initialized";
        return -1;
    }
    if (g_sim.phase != BootPhase::RUNTIME_READY && g_sim.phase != BootPhase::ROM_IDLE) {
        g_sim.last_error_msg = "Mailbox is not ready yet (wait for ready_for_mb_processing or ready_for_runtime)";
        return -1;
    }
    if (g_sim.user_mbox_state == UserMboxState::LOCK_AND_HEADER ||
        g_sim.user_mbox_state == UserMboxState::WRITE_DATA ||
        g_sim.user_mbox_state == UserMboxState::WAIT_COMPLETE ||
        g_sim.user_mbox_state == UserMboxState::READ_RESP) {
        g_sim.last_error_msg = "Another mailbox command is already in flight";
        return -1;
    }
    g_sim.user_cmd = cmd;
    if (req_ptr && req_len > 0) {
        g_sim.user_req.assign(req_ptr, req_ptr + req_len);
    } else {
        g_sim.user_req.clear();
    }
    g_sim.user_req_word_idx = 0;
    g_sim.user_lock_retries = 0;
    g_sim.user_resp.clear();
    g_sim.user_resp_dlen = 0;
    g_sim.last_error_msg.clear();
    g_sim.user_mbox_state = UserMboxState::LOCK_AND_HEADER;
    return 0;
}

EMSCRIPTEN_KEEPALIVE
int calightra_mailbox_poll() {
    switch (g_sim.user_mbox_state) {
        case UserMboxState::DONE_OK:
            g_sim.user_mbox_state = UserMboxState::IDLE;
            return 1;
        case UserMboxState::DONE_ERR:
            g_sim.user_mbox_state = UserMboxState::IDLE;
            return -1;
        case UserMboxState::IDLE:
            return 1;
        default:
            return 0; // Still executing
    }
}

EMSCRIPTEN_KEEPALIVE
const uint8_t* calightra_mailbox_resp_ptr() {
    return g_sim.user_resp.empty() ? nullptr : g_sim.user_resp.data();
}

EMSCRIPTEN_KEEPALIVE
uint32_t calightra_mailbox_resp_len() {
    return static_cast<uint32_t>(g_sim.user_resp.size());
}

EMSCRIPTEN_KEEPALIVE
void calightra_set_prod_dbg_unlock_req(int enable) {
    if (enable) g_sim.dbg_service_reg_shadow |= 0x2u;
    else        g_sim.dbg_service_reg_shadow &= ~0x2u;
    g_sim.has_pending_dbg_service_write = true;
}

EMSCRIPTEN_KEEPALIVE
void calightra_set_manuf_dbg_unlock_req(int enable) {
    if (enable) g_sim.dbg_service_reg_shadow |= 0x1u;
    else        g_sim.dbg_service_reg_shadow &= ~0x1u;
    g_sim.has_pending_dbg_service_write = true;
}

EMSCRIPTEN_KEEPALIVE
const char* calightra_fw_pk_hashes(const uint8_t* fw_ptr, uint32_t fw_len) {
    g_pk_hashes_json.clear();
    if (!fw_ptr || fw_len < 11856u) {
        return g_pk_hashes_json.c_str();
    }
    uint32_t marker = uint32_t(fw_ptr[0]) | (uint32_t(fw_ptr[1]) << 8) |
                      (uint32_t(fw_ptr[2]) << 16) | (uint32_t(fw_ptr[3]) << 24);
    if (marker != MANIFEST_MARKER_2X) {
        return g_pk_hashes_json.c_str();
    }

    uint8_t vendor_digest[48];
    uint8_t owner_digest[48];
    // Caliptra 2.x ImageManifest layout:
    //   preamble.vendor_pub_key_info : bytes [12 .. 1748] (1736 bytes)
    //   preamble.owner_pub_keys      : bytes [9168 .. 11856] (2688 bytes)
    sha384_digest(fw_ptr + 12, 1736, vendor_digest);
    sha384_digest(fw_ptr + 9168, 2688, owner_digest);

    g_pk_hashes_json = "{\"vendor_pk_hash\":\"" + bytes_to_hex(vendor_digest, 48) +
                       "\",\"owner_pk_hash\":\"" + bytes_to_hex(owner_digest, 48) + "\"}";
    return g_pk_hashes_json.c_str();
}

} // extern "C"
