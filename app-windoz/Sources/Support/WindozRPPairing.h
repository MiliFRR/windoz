// SPDX-License-Identifier: GPL-3.0-or-later
// Windoz Converter Exception: see LICENSE-EXCEPTION.md
//
// On-device remote pairing (iOS 27 and later): build/rppairing-ios, linked as
// libwindoz_rppairing.a. Ported from Madeira's MadeiraRPPairing.h
// (GPL-3.0-or-later, Madeira Converter Exception): only the names are
// Windoz's. Keep in step with build/rppairing-ios/src/lib.rs.

#ifndef WINDOZ_RPPAIRING_H
#define WINDOZ_RPPAIRING_H

#include <stddef.h>
#include <stdint.h>

typedef struct WindozRPPairing WindozRPPairing;
typedef void (*WindozRPPairingPinCallback)(const char *pin, void *context);

/// New host identity and a listener on all IPv4 interfaces. NULL on failure,
/// with *error set (free with windoz_rppairing_string_free).
WindozRPPairing *windoz_rppairing_new(const char *name, char **error);
uint16_t windoz_rppairing_port(const WindozRPPairing *session);
/// The Bonjour instance name to publish; owned by the session.
const char *windoz_rppairing_service_name(const WindozRPPairing *session);
size_t windoz_rppairing_txt_count(const WindozRPPairing *session);
const char *windoz_rppairing_txt_key(const WindozRPPairing *session, size_t index);
const char *windoz_rppairing_txt_value(const WindozRPPairing *session, size_t index);
/// Blocks until paired (0), failed (1, *error set) or cancelled (2). On success
/// *out_plist/*out_len hold the RPPairing plist (windoz_rppairing_bytes_free)
/// and *out_device_name the device's name (windoz_rppairing_string_free).
int32_t windoz_rppairing_accept(const WindozRPPairing *session,
                                WindozRPPairingPinCallback pin_callback, void *pin_context,
                                uint8_t **out_plist, size_t *out_len,
                                char **out_device_name, char **error);
/// Ends a running or future accept with 2. Any thread.
void windoz_rppairing_cancel(const WindozRPPairing *session);
/// Only after accept has returned (or was never called).
void windoz_rppairing_free(WindozRPPairing *session);
void windoz_rppairing_bytes_free(uint8_t *bytes, size_t len);
void windoz_rppairing_string_free(char *string);

#endif
