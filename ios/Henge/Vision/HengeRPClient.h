/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Pairing with an Apple Vision Pro as the host that starts it: xros/tools/henge-pair, linked into the visionOS app as
 * libhenge_rpclient.a (xros/scripts/build_stikjit_xros.sh). Keep in step with xros/tools/henge-pair/src/lib.rs.
 */
#ifndef HENGE_RPCLIENT_H
#define HENGE_RPCLIENT_H

#include <stddef.h>
#include <stdint.h>

/* The code the device shows, as a C string made with malloc (the library frees it), or NULL to cancel. Called on the
   thread that called henge_rpclient_pair once the device shows its code, and may block until the person has typed it. */
typedef char *(*HengeRPClientCode)(void *context);

/* Connects to the device's _remotepairing-manual-pairing._tcp service at address:port and pairs as host_name.
   Blocks until paired (0: *out_plist and *out_len hold the RPPairing plist, henge_rpclient_bytes_free), failed
   (1: *error set, henge_rpclient_string_free) or cancelled (2). */
int32_t henge_rpclient_pair(const char *address, uint16_t port, const char *host_name,
                            HengeRPClientCode code, void *context,
                            uint8_t **out_plist, size_t *out_len, char **error);
void henge_rpclient_bytes_free(uint8_t *bytes, size_t len);
void henge_rpclient_string_free(char *string);

#endif /* HENGE_RPCLIENT_H */
