// RADE V2 entry points rade_api.c references. The app only ever opens V1
// (no RADE_MODE_V2 flag), so rade_c's V2 sources and their ~12 MB of
// weights are left out of the library and these stand in for them. Each
// aborts if reached, which would mean V2 was opened by mistake. Declared
// without prototypes on purpose: they're never called.
#include <stdlib.h>
#define FTX1_RADE_V2_STUB(name) void name(void); void name(void) { abort(); }
FTX1_RADE_V2_STUB(rade_rx_v2_clock_offset_ppm)
FTX1_RADE_V2_STUB(rade_rx_v2_get_data_symbol)
FTX1_RADE_V2_STUB(rade_rx_v2_init)
FTX1_RADE_V2_STUB(rade_rx_v2_mistune)
FTX1_RADE_V2_STUB(rade_rx_v2_n_features_out)
FTX1_RADE_V2_STUB(rade_rx_v2_nin)
FTX1_RADE_V2_STUB(rade_rx_v2_nin_max)
FTX1_RADE_V2_STUB(rade_rx_v2_process)
FTX1_RADE_V2_STUB(rade_tx_v2_eoo)
FTX1_RADE_V2_STUB(rade_tx_v2_init)
FTX1_RADE_V2_STUB(rade_tx_v2_n_eoo_out)
FTX1_RADE_V2_STUB(rade_tx_v2_n_features_in)
FTX1_RADE_V2_STUB(rade_tx_v2_n_samples_out)
FTX1_RADE_V2_STUB(rade_tx_v2_process)
FTX1_RADE_V2_STUB(rade_tx_v2_set_data_symbol)
