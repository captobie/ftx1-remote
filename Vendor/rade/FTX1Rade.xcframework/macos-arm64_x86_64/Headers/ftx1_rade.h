// ftx1_rade.h — the FTX1Remote app's C interface to FreeDV RADE V1 (receive
// and transmit).
//
// Wraps rade_c (BSD-2, freedv/rade_c), Opus's FARGAN vocoder (BSD-3) and
// freedv-backend's end-of-over callsign decoder (BSD-2), all compiled into
// Vendor/rade/FTX1Rade.xcframework by Scripts/build-rade.sh. This header is
// the only one Swift sees; nothing from rade_c or Opus is exposed.
//
// Not thread-safe: one receiver per caller-owned serial queue.

#ifndef FTX1_RADE_H
#define FTX1_RADE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Modem audio rate in (real samples, not I/Q).
#define FTX1_RADE_MODEM_RATE 8000
/// Decoded speech rate out.
#define FTX1_RADE_SPEECH_RATE 16000
/// Longest callsign the end-of-over carries.
#define FTX1_RADE_CALLSIGN_MAX 8

typedef struct ftx1_rade_rx ftx1_rade_rx;

typedef struct {
    /// 1 while the demodulator is in sync with a RADE signal.
    int sync;
    /// Estimated tuning error of the received signal, Hz.
    float freq_offset_hz;
    /// Estimated SNR in a 3 kHz bandwidth, dB (meaningful while in sync).
    float snr_db;
    /// 1 if this block ended a transmission (end-of-over).
    int end_of_over;
    /// 1 if that end-of-over carried a callsign whose CRC checked out.
    int callsign_valid;
    /// The callsign, NUL-terminated (empty unless callsign_valid).
    char callsign[FTX1_RADE_CALLSIGN_MAX + 1];
} ftx1_rade_rx_status;

/// A new RADE V1 receiver with FARGAN primed. NULL if allocation failed.
ftx1_rade_rx *ftx1_rade_rx_open(void);
void ftx1_rade_rx_close(ftx1_rade_rx *rx);

/// Modem samples the next ftx1_rade_rx_process call needs (varies with timing).
int ftx1_rade_rx_nin(ftx1_rade_rx *rx);
/// Largest value ftx1_rade_rx_nin can return.
int ftx1_rade_rx_nin_max(ftx1_rade_rx *rx);
/// Largest number of speech samples one ftx1_rade_rx_process call writes.
int ftx1_rade_rx_speech_max(ftx1_rade_rx *rx);

/// Demodulates exactly ftx1_rade_rx_nin(rx) samples of real 8 kHz audio
/// (float, full scale ±1) and writes the decoded 16 kHz speech (float, ±1)
/// to `speech`, which must hold ftx1_rade_rx_speech_max(rx) samples.
/// Returns the number of speech samples written (often 0). `status` may be NULL.
int ftx1_rade_rx_process(ftx1_rade_rx *rx, const float *modem, float *speech,
                         ftx1_rade_rx_status *status);

/* ---------------------------------------------------------------- transmit */

typedef struct ftx1_rade_tx ftx1_rade_tx;

/// Speech samples per ftx1_rade_tx_process call (10 ms at 16 kHz).
#define FTX1_RADE_TX_SPEECH_FRAME 160

/// A new RADE V1 transmitter (FARGAN feature encoder + RADE encoder and
/// modulator). One per over: open at key-up, finish, close. NULL if
/// allocation failed.
ftx1_rade_tx *ftx1_rade_tx_open(void);
void ftx1_rade_tx_close(ftx1_rade_tx *tx);

/// Largest number of modem samples one ftx1_rade_tx_process call writes.
int ftx1_rade_tx_modem_max(ftx1_rade_tx *tx);
/// Largest number ftx1_rade_tx_finish writes (the last frame + end-of-over).
int ftx1_rade_tx_finish_max(ftx1_rade_tx *tx);

/// Encodes one 10 ms frame of 16 kHz speech (FTX1_RADE_TX_SPEECH_FRAME
/// samples, float ±1). Every twelfth call (120 ms) writes a modem frame to
/// `modem`: real 8 kHz samples at the modem's nominal amplitude 1.0 (the
/// FreeDV app sends them at 16383/32767, i.e. half of full scale). Returns
/// the number of samples written (0 or ftx1_rade_tx_modem_max).
int ftx1_rade_tx_process(ftx1_rade_tx *tx, const float *speech, float *modem);

/// Ends the over: encodes any speech still buffered (zero-padded to a
/// whole modem frame), then the end-of-over frame carrying `callsign`
/// (up to 8 characters; NULL or "" sends none — receivers show nothing).
/// Writes up to ftx1_rade_tx_finish_max samples; returns the count.
int ftx1_rade_tx_finish(ftx1_rade_tx *tx, const char *callsign, float *modem);

/// Library versions, for logging: rade_c's API version and this wrapper's.
int ftx1_rade_rade_version(void);
int ftx1_rade_wrapper_version(void);

#ifdef __cplusplus
}
#endif

#endif /* FTX1_RADE_H */
