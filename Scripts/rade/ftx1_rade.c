// ftx1_rade.c — see ftx1_rade.h. Built by Scripts/build-rade.sh, not by SwiftPM.
//
// Follows freedv-backend's RADEReceiveStep: real audio in as I/Q with
// imag = 0 at full scale ±1, FARGAN primed once with zero features and then
// fed every 10 ms feature frame, end-of-over bits handed to rade_text_rx
// (whose features are not speech, so they're not synthesised).

#include "ftx1_rade.h"

#include <stdlib.h>
#include <string.h>

#include "rade_api.h"
#include "fargan.h"
#include "lpcnet.h"
#include "rade_text.h"

#define FTX1_RADE_WRAPPER_VERSION 1

struct ftx1_rade_rx {
    struct rade *rade;
    FARGANState fargan;
    rade_text_t text;
    RADE_COMP *iq;
    float *features;
    float *eoo;
    int n_features;         // per rade_rx call (several 10 ms frames)
    float pending[NB_TOTAL_FEATURES];
    int pending_count;
    int callsign_valid;     // set by on_text during rade_text_rx
    char callsign[FTX1_RADE_CALLSIGN_MAX + 1];
};

static void on_text(rade_text_t t, const char *txt, int length, void *state) {
    (void)t;
    struct ftx1_rade_rx *rx = (struct ftx1_rade_rx *)state;
    if (length > FTX1_RADE_CALLSIGN_MAX) length = FTX1_RADE_CALLSIGN_MAX;
    memcpy(rx->callsign, txt, (size_t)length);
    rx->callsign[length] = '\0';
    rx->callsign_valid = 1;
}

ftx1_rade_rx *ftx1_rade_rx_open(void) {
    struct ftx1_rade_rx *rx = calloc(1, sizeof(*rx));
    if (!rx) return NULL;
    rade_initialize();
    // model_file is ignored: the weights are compiled in.
    rx->rade = rade_open("", RADE_VERBOSE_0);
    if (!rx->rade) { free(rx); return NULL; }
    rx->n_features = rade_n_features_in_out(rx->rade);
    rx->iq = malloc(sizeof(RADE_COMP) * (size_t)rade_nin_max(rx->rade));
    rx->features = malloc(sizeof(float) * (size_t)rx->n_features);
    rx->eoo = malloc(sizeof(float) * (size_t)rade_n_eoo_bits(rx->rade));
    rx->text = rade_text_create();
    if (!rx->iq || !rx->features || !rx->eoo || !rx->text) {
        ftx1_rade_rx_close(rx);
        return NULL;
    }
    rade_text_set_rx_callback(rx->text, on_text, rx);

    float zeros[FARGAN_CONT_SAMPLES] = {0};
    float primer[5 * NB_TOTAL_FEATURES] = {0};
    fargan_init(&rx->fargan);
    fargan_cont(&rx->fargan, zeros, primer);
    return rx;
}

void ftx1_rade_rx_close(ftx1_rade_rx *rx) {
    if (!rx) return;
    if (rx->text) rade_text_destroy(rx->text);
    if (rx->rade) rade_close(rx->rade);
    free(rx->iq);
    free(rx->features);
    free(rx->eoo);
    free(rx);
}

int ftx1_rade_rx_nin(ftx1_rade_rx *rx) { return rade_nin(rx->rade); }
int ftx1_rade_rx_nin_max(ftx1_rade_rx *rx) { return rade_nin_max(rx->rade); }

int ftx1_rade_rx_speech_max(ftx1_rade_rx *rx) {
    // Every feature frame of one call, plus the one carried over.
    return (rx->n_features / NB_TOTAL_FEATURES + 1) * LPCNET_FRAME_SIZE;
}

int ftx1_rade_rx_process(ftx1_rade_rx *rx, const float *modem, float *speech,
                         ftx1_rade_rx_status *status) {
    int nin = rade_nin(rx->rade);
    for (int i = 0; i < nin; i++) {
        rx->iq[i].real = modem[i];
        rx->iq[i].imag = 0.0f;
    }

    int has_eoo = 0;
    int n_out = rade_rx(rx->rade, rx->features, &has_eoo, rx->eoo, rx->iq);

    rx->callsign_valid = 0;
    rx->callsign[0] = '\0';
    int written = 0;
    if (has_eoo) {
        rade_text_rx(rx->text, rx->eoo, rade_n_eoo_bits(rx->rade) / 2);
    } else {
        for (int i = 0; i < n_out; i++) {
            rx->pending[rx->pending_count++] = rx->features[i];
            if (rx->pending_count == NB_TOTAL_FEATURES) {
                rx->pending_count = 0;
                fargan_synthesize(&rx->fargan, &speech[written], rx->pending);
                for (int s = 0; s < LPCNET_FRAME_SIZE; s++) {
                    float v = speech[written + s];
                    speech[written + s] = v > 1.0f ? 1.0f : (v < -1.0f ? -1.0f : v);
                }
                written += LPCNET_FRAME_SIZE;
            }
        }
    }

    if (status) {
        status->sync = rade_sync(rx->rade);
        status->freq_offset_hz = rade_freq_offset(rx->rade);
        status->snr_db = rade_snrdB_3k_est(rx->rade);
        status->end_of_over = has_eoo;
        status->callsign_valid = rx->callsign_valid;
        memcpy(status->callsign, rx->callsign, sizeof(status->callsign));
    }
    return written;
}

int ftx1_rade_rade_version(void) { return rade_version(); }
int ftx1_rade_wrapper_version(void) { return FTX1_RADE_WRAPPER_VERSION; }
