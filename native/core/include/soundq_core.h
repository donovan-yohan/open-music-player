#ifndef SOUNDQ_APP_CORE_H
#define SOUNDQ_APP_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* cdecl, fixed-width handles, UTF-8 NUL-terminated inputs copied in call.
 * ABI 1. Threads may revoke while execute blocks. Serialize ordinary execute
 * calls in the platform adapter; never call from the realtime callback.
 * Returned JSON is private adapter data and may contain credentials or local
 * paths. Only snapshot is safe for presentation. Never log the raw result.
 * close revokes/removes handle admission. Existing calls retain internal core
 * lifetime until settlement; native decoder must already be stopped/closed.
 * No panic unwinds across this boundary. Version mismatch must refuse startup.
 */
uint32_t sq_core_abi_version(void);
/* client_root holds endpoint/account-scoped durable queue data plus bounded
 * immutable audio files. Supply application support/files, not purgeable cache. */
uint64_t sq_core_open(const char *endpoint, const char *client_root);
/* expected_epoch is captured when enqueueing, never when the worker dequeues. */
char *sq_core_execute(uint64_t core, uint64_t expected_epoch, const char *command_json);
uint64_t sq_core_revoke(uint64_t core);
void sq_core_close(uint64_t core);
void sq_core_string_free(char *result);
#ifdef __cplusplus
}
#endif
#endif
