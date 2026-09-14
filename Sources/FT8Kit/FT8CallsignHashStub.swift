import CFT8Lib

/// v1 no-op callsign hash table. `ftx_message_decode` consults this to resolve
/// hashed/compound callsigns (DXpedition mode, etc.) that the 77-bit payload
/// can't carry in full — this app has no persistent hash table yet, so those
/// messages decode with a literal `<...>` placeholder instead of a resolved
/// call, same as ft8_lib's own demo would produce for a hash it hasn't seen
/// yet. A real implementation (bounded table of recently-seen callsign
/// hashes, per ft8_lib's demo) can replace this later without touching
/// anything else in FT8Kit.
///
/// `@_cdecl` requires top-level functions (not methods), and
/// `ftx_callsign_hash_interface_t` has no userdata slot, so this has to be
/// process-global state rather than an instance closure.
@_cdecl("ft8kit_lookup_hash_noop")
func ft8kit_lookup_hash_noop(
    _ hashType: ftx_callsign_hash_type_t,
    _ hash: UInt32,
    _ callsign: UnsafeMutablePointer<CChar>?
) -> Bool {
    callsign?.pointee = 0
    return false
}

@_cdecl("ft8kit_save_hash_noop")
func ft8kit_save_hash_noop(_ callsign: UnsafePointer<CChar>?, _ n22: UInt32) {
    // No-op: nothing to remember without a persistent table.
}

enum FT8CallsignHashStub {
    static var interface = ftx_callsign_hash_interface_t(
        lookup_hash: ft8kit_lookup_hash_noop,
        save_hash: ft8kit_save_hash_noop
    )
}
