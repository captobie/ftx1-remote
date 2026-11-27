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
#include "cpu_support.h"

#define FTX1_RADE_WRAPPER_VERSION 2

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

/* ---------------------------------------------------------------- transmit */
//
// Follows freedv-backend's RADETransmitStep: 10 ms speech frames through
// lpcnet_compute_single_frame_features, rade_tx once twelve frames are in,
// and at the end rade_text_generate_tx_string + rade_tx_set_eoo_bits +
// rade_tx_eoo. Only the real part goes out (an SSB transmitter).

struct ftx1_rade_tx {
    struct rade *rade;
    LPCNetEncState *encoder;
    rade_text_t text;
    int arch;
    float *features;        // one modem frame's worth
    int n_features;
    int feature_count;      // filled so far
    RADE_COMP *iq;          // sized for the larger of a modem frame and the EOO
    int n_tx_out;
    int n_eoo_out;
    float *eoo_bits;
    int n_eoo_bits;
};

ftx1_rade_tx *ftx1_rade_tx_open(void) {
    struct ftx1_rade_tx *tx = calloc(1, sizeof(*tx));
    if (!tx) return NULL;
    rade_initialize();
    tx->rade = rade_open("", RADE_VERBOSE_0);
    tx->encoder = lpcnet_encoder_create();
    tx->text = rade_text_create();
    if (!tx->rade || !tx->encoder || !tx->text) {
        ftx1_rade_tx_close(tx);
        return NULL;
    }
    tx->arch = opus_select_arch();
    tx->n_features = rade_n_features_in_out(tx->rade);
    tx->n_tx_out = rade_n_tx_out(tx->rade);
    tx->n_eoo_out = rade_n_tx_eoo_out(tx->rade);
    tx->n_eoo_bits = rade_n_eoo_bits(tx->rade);
    int n_iq = tx->n_tx_out > tx->n_eoo_out ? tx->n_tx_out : tx->n_eoo_out;
    tx->features = calloc((size_t)tx->n_features, sizeof(float));
    tx->iq = malloc(sizeof(RADE_COMP) * (size_t)n_iq);
    tx->eoo_bits = calloc((size_t)tx->n_eoo_bits, sizeof(float));
    if (!tx->features || !tx->iq || !tx->eoo_bits) {
        ftx1_rade_tx_close(tx);
        return NULL;
    }
    return tx;
}

void ftx1_rade_tx_close(ftx1_rade_tx *tx) {
    if (!tx) return;
    if (tx->text) rade_text_destroy(tx->text);
    if (tx->encoder) lpcnet_encoder_destroy(tx->encoder);
    if (tx->rade) rade_close(tx->rade);
    free(tx->features);
    free(tx->iq);
    free(tx->eoo_bits);
    free(tx);
}

int ftx1_rade_tx_modem_max(ftx1_rade_tx *tx) { return tx->n_tx_out; }
int ftx1_rade_tx_finish_max(ftx1_rade_tx *tx) { return tx->n_tx_out + tx->n_eoo_out; }

static int modulate_frame(ftx1_rade_tx *tx, float *modem) {
    int n = rade_tx(tx->rade, tx->iq, tx->features);
    for (int i = 0; i < n; i++) modem[i] = tx->iq[i].real;
    tx->feature_count = 0;
    return n;
}

int ftx1_rade_tx_process(ftx1_rade_tx *tx, const float *speech, float *modem) {
    opus_int16 pcm[FTX1_RADE_TX_SPEECH_FRAME];
    for (int i = 0; i < FTX1_RADE_TX_SPEECH_FRAME; i++) {
        float v = speech[i] * 32768.0f;
        if (v > 32767.0f) v = 32767.0f;
        if (v < -32767.0f) v = -32767.0f;
        pcm[i] = (opus_int16)(v < 0 ? v - 0.5f : v + 0.5f);
    }
    lpcnet_compute_single_frame_features(tx->encoder, pcm,
        &tx->features[tx->feature_count], tx->arch);
    tx->feature_count += NB_TOTAL_FEATURES;
    if (tx->feature_count < tx->n_features) return 0;
    return modulate_frame(tx, modem);
}

int ftx1_rade_tx_finish(ftx1_rade_tx *tx, const char *callsign, float *modem) {
    int written = 0;
    if (tx->feature_count > 0) {
        memset(&tx->features[tx->feature_count], 0,
               sizeof(float) * (size_t)(tx->n_features - tx->feature_count));
        written += modulate_frame(tx, modem);
    }
    memset(tx->eoo_bits, 0, sizeof(float) * (size_t)tx->n_eoo_bits);
    if (callsign && callsign[0]) {
        int length = (int)strlen(callsign);
        if (length > FTX1_RADE_CALLSIGN_MAX) length = FTX1_RADE_CALLSIGN_MAX;
        rade_text_generate_tx_string(tx->text, callsign, length, tx->eoo_bits, tx->n_eoo_bits);
        rade_tx_set_eoo_bits(tx->rade, tx->eoo_bits);
    }
    int n = rade_tx_eoo(tx->rade, tx->iq);
    for (int i = 0; i < n; i++) modem[written + i] = tx->iq[i].real;
    return written + n;
}

int ftx1_rade_rade_version(void) { return rade_version(); }
int ftx1_rade_wrapper_version(void) { return FTX1_RADE_WRAPPER_VERSION; }
