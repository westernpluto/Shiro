// Thin C helpers around chiaki-ng so Swift never has to touch fixed-size C
// arrays or anonymous unions directly.
#ifndef SHIRO_CHIAKI_H
#define SHIRO_CHIAKI_H

#include <chiaki/session.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/regist.h>
#include <chiaki/remote/holepunch.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------- session

typedef struct shiro_connect_params_t
{
	bool ps5;
	const char *host;                 // IP / hostname (ignored for PSN connections)
	const uint8_t *regist_key;        // 16 bytes, may be NULL for PSN connections
	const uint8_t *morning;           // 16 bytes, may be NULL for PSN connections
	unsigned int width;
	unsigned int height;
	unsigned int max_fps;
	unsigned int bitrate;             // kbit/s
	ChiakiCodec codec;
	bool enable_dualsense;
	bool auto_regist;
	ChiakiHolepunchSession holepunch_session; // NULL for local connections
	const uint8_t *psn_account_id;    // 8 bytes, may be NULL
	double packet_loss_max;
	bool enable_idr_on_fec_failure;
} ShiroConnectParams;

ChiakiErrorCode shiro_session_init(ChiakiSession *session, const ShiroConnectParams *params, ChiakiLog *log);

// ---------------------------------------------------------------- events

typedef struct shiro_event_t
{
	ChiakiEventType type;
	ChiakiQuitReason quit_reason;
	const char *quit_reason_str;
	bool login_pin_incorrect;
	bool holepunch_finished;
	const char *keyboard_text;
	uint8_t rumble_left;
	uint8_t rumble_right;
	uint8_t trigger_type_left;
	uint8_t trigger_type_right;
	const uint8_t *trigger_left;   // 10 bytes
	const uint8_t *trigger_right;  // 10 bytes
	uint8_t led_r, led_g, led_b;
	uint8_t player_index;
	uint8_t haptic_intensity;      // ChiakiDualSenseEffectIntensity
	char nickname[0x21];
	const ChiakiRegisteredHost *registered_host;
	int32_t fec_frame_index;
} ShiroEvent;

void shiro_event_flatten(const ChiakiEvent *event, ShiroEvent *out);

// ---------------------------------------------------------------- registered hosts

typedef struct shiro_registered_host_t
{
	ChiakiTarget target;
	char nickname[0x21];
	uint8_t mac[6];
	uint8_t regist_key[CHIAKI_SESSION_AUTH_SIZE];
	uint8_t rp_key[0x10];
	uint32_t rp_key_type;
	uint32_t console_pin;
} ShiroRegisteredHost;

void shiro_registered_host_flatten(const ChiakiRegisteredHost *host, ShiroRegisteredHost *out);

// ---------------------------------------------------------------- registration

ChiakiErrorCode shiro_regist_start(ChiakiRegist *regist, ChiakiLog *log, ChiakiTarget target,
		const char *host, const uint8_t *psn_account_id, uint32_t pin,
		ChiakiRegistCb cb, void *user);

// ---------------------------------------------------------------- discovery

/**
 * Starts a discovery service that pings every address in @p ipv4_addrs
 * (network byte order) on both the PS4 and PS5 discovery ports, plus the
 * global broadcast address. Unicast sweeping keeps discovery working on iOS
 * without the restricted multicast entitlement.
 */
ChiakiErrorCode shiro_discovery_service_start(ChiakiDiscoveryService *service,
		const uint32_t *ipv4_addrs, size_t count, uint64_t ping_ms,
		ChiakiDiscoveryServiceCb cb, void *user, ChiakiLog *log);

ChiakiErrorCode shiro_wakeup(ChiakiLog *log, const char *host, const uint8_t *regist_key, bool ps5);

// ---------------------------------------------------------------- holepunch / PSN

typedef struct shiro_psn_device_t
{
	bool ps5;
	char name[33];
	uint8_t duid[32];
	bool remoteplay_enabled;
} ShiroPsnDevice;

/** Lists the consoles linked to the PSN account. Returns number of devices written. */
size_t shiro_psn_list_devices(const char *token, bool ps5, ShiroPsnDevice *out, size_t max, ChiakiLog *log, ChiakiErrorCode *err);

/** Runs the full PSN hole-punching handshake for the control connection (blocking). */
ChiakiErrorCode shiro_psn_connect(ChiakiHolepunchSession session, const uint8_t *duid, size_t duid_len, bool ps5);

#ifdef __cplusplus
}
#endif

#endif
