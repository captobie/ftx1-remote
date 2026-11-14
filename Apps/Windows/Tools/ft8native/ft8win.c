// A flat C API over the vendored ft8_lib (Sources/CFT8Lib) for the Windows
// app's P/Invoke — the Windows counterpart of Sources/FT8Kit/FT8Decoder.swift
// (which stays the source of truth for the decode loop). Keeping the loop
// here means C# never has to marshal ft8_lib's structs.
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <ft8/constants.h>
#include <ft8/decode.h>
#include <ft8/message.h>
#include <common/monitor.h>

// POSIX stpcpy, which message.c uses and MSVC's CRT lacks.
char* stpcpy(char* dest, const char* src)
{
    size_t n = strlen(src);
    memcpy(dest, src, n + 1);
    return dest + n;
}

#define FT8W_EXPORT __declspec(dllexport)

typedef struct
{
    char text[FTX_MAX_MESSAGE_LENGTH + 13];
    int32_t types[FTX_MAX_MESSAGE_FIELDS];
    int32_t offsets[FTX_MAX_MESSAGE_FIELDS];
    double freq_hz;
    double dt_sec;
    int32_t score;
    int32_t ldpc_errors;
} ft8w_result_t;

// No hash table (same as FT8CallsignHashStub.swift): hashed calls decode
// as "<...>".
static bool lookup_hash_noop(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign)
{
    (void)hash_type; (void)hash;
    callsign[0] = 0;
    return false;
}

static void save_hash_noop(const char* callsign, uint32_t n22)
{
    (void)callsign; (void)n22;
}

static ftx_callsign_hash_interface_t g_hash_if = { lookup_hash_noop, save_hash_noop };

FT8W_EXPORT int ft8w_result_size(void) { return (int)sizeof(ft8w_result_t); }

FT8W_EXPORT void* ft8w_create(int sample_rate, int is_ft4, float f_min, float f_max)
{
    monitor_t* monitor = (monitor_t*)calloc(1, sizeof(monitor_t));
    if (!monitor) return NULL;
    monitor_config_t cfg;
    cfg.f_min = f_min;
    cfg.f_max = f_max;
    cfg.sample_rate = sample_rate;
    cfg.time_osr = 2;
    cfg.freq_osr = 2;
    cfg.protocol = is_ft4 ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8;
    monitor_init(monitor, &cfg);
    return monitor;
}

FT8W_EXPORT int ft8w_block_size(void* handle)
{
    return ((monitor_t*)handle)->block_size;
}

FT8W_EXPORT void ft8w_reset(void* handle)
{
    monitor_reset((monitor_t*)handle);
}

// Exactly ft8w_block_size() samples.
FT8W_EXPORT void ft8w_process(void* handle, const float* block)
{
    monitor_process((monitor_t*)handle, block);
}

FT8W_EXPORT void ft8w_free(void* handle)
{
    if (!handle) return;
    monitor_free((monitor_t*)handle);
    free(handle);
}

// Candidate search + LDPC decode + unpack, deduplicated by payload.
// Returns the number of results written (at most max_results).
FT8W_EXPORT int ft8w_decode(void* handle, ft8w_result_t* results, int max_results,
                            int min_score, int max_candidates, int ldpc_iterations)
{
    monitor_t* monitor = (monitor_t*)handle;
    if (max_candidates < 1) return 0;
    ftx_candidate_t* candidates = (ftx_candidate_t*)calloc((size_t)max_candidates, sizeof(ftx_candidate_t));
    uint8_t(*seen)[FTX_PAYLOAD_LENGTH_BYTES] = (uint8_t(*)[FTX_PAYLOAD_LENGTH_BYTES])calloc((size_t)max_candidates, FTX_PAYLOAD_LENGTH_BYTES);
    if (!candidates || !seen) { free(candidates); free(seen); return 0; }

    int count = 0;
    int found = ftx_find_candidates(&monitor->wf, max_candidates, candidates, min_score);
    for (int i = 0; i < found && count < max_results; i++)
    {
        ftx_message_t message;
        ftx_decode_status_t status;
        memset(&message, 0, sizeof message);
        memset(&status, 0, sizeof status);
        if (!ftx_decode_candidate(&monitor->wf, &candidates[i], ldpc_iterations, &message, &status))
            continue;

        bool duplicate = false;
        for (int s = 0; s < count; s++)
        {
            if (memcmp(seen[s], message.payload, FTX_PAYLOAD_LENGTH_BYTES) == 0) { duplicate = true; break; }
        }
        if (duplicate) continue;

        ft8w_result_t* out = &results[count];
        memset(out, 0, sizeof *out);
        char text[FTX_MAX_MESSAGE_LENGTH + 13];
        memset(text, 0, sizeof text);
        ftx_message_offsets_t offsets;
        memset(&offsets, 0, sizeof offsets);
        if (ftx_message_decode(&message, &g_hash_if, text, &offsets) != FTX_MESSAGE_RC_OK)
            continue;

        memcpy(seen[count], message.payload, FTX_PAYLOAD_LENGTH_BYTES);
        memcpy(out->text, text, sizeof out->text);
        for (int f = 0; f < FTX_MAX_MESSAGE_FIELDS; f++)
        {
            out->types[f] = (int32_t)offsets.types[f];
            out->offsets[f] = (int32_t)offsets.offsets[f];
        }
        out->freq_hz = ((double)monitor->min_bin + (double)candidates[i].freq_offset
                        + (double)candidates[i].freq_sub / (double)monitor->wf.freq_osr) / (double)monitor->symbol_period;
        out->dt_sec = ((double)candidates[i].time_offset
                       + (double)candidates[i].time_sub / (double)monitor->wf.time_osr) * (double)monitor->symbol_period;
        out->score = (int32_t)candidates[i].score;
        out->ldpc_errors = (int32_t)status.ldpc_errors;
        count++;
    }
    free(candidates);
    free(seen);
    return count;
}
