#include "ShiroChiaki.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>

// ---------------------------------------------------------------- session

ChiakiErrorCode shiro_session_init(ChiakiSession *session, const ShiroConnectParams *p, ChiakiLog *log)
{
	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = p->ps5;
	info.host = p->host ? p->host : "";
	if(p->regist_key)
		memcpy(info.regist_key, p->regist_key, sizeof(info.regist_key));
	if(p->morning)
		memcpy(info.morning, p->morning, sizeof(info.morning));
	info.video_profile.width = p->width;
	info.video_profile.height = p->height;
	info.video_profile.max_fps = p->max_fps;
	info.video_profile.bitrate = p->bitrate;
	info.video_profile.codec = p->codec;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = p->enable_dualsense;
	info.audio_video_disabled = 0;
	info.auto_regist = p->auto_regist;
	info.holepunch_session = p->holepunch_session;
	info.rudp_sock = NULL;
	if(p->psn_account_id)
		memcpy(info.psn_account_id, p->psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.packet_loss_max = p->packet_loss_max;
	info.enable_idr_on_fec_failure = p->enable_idr_on_fec_failure;
	return chiaki_session_init(session, &info, log);
}

// ---------------------------------------------------------------- events

void shiro_event_flatten(const ChiakiEvent *e, ShiroEvent *o)
{
	memset(o, 0, sizeof(*o));
	o->type = e->type;
	switch(e->type)
	{
		case CHIAKI_EVENT_QUIT:
			o->quit_reason = e->quit.reason;
			o->quit_reason_str = e->quit.reason_str;
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			o->login_pin_incorrect = e->login_pin_request.pin_incorrect;
			break;
		case CHIAKI_EVENT_HOLEPUNCH:
			o->holepunch_finished = e->data_holepunch.finished;
			break;
		case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
		case CHIAKI_EVENT_KEYBOARD_OPEN:
			o->keyboard_text = e->keyboard.text_str;
			break;
		case CHIAKI_EVENT_RUMBLE:
			o->rumble_left = e->rumble.left;
			o->rumble_right = e->rumble.right;
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			o->trigger_type_left = e->trigger_effects.type_left;
			o->trigger_type_right = e->trigger_effects.type_right;
			o->trigger_left = e->trigger_effects.left;
			o->trigger_right = e->trigger_effects.right;
			break;
		case CHIAKI_EVENT_LED_COLOR:
			o->led_r = e->led_state[0];
			o->led_g = e->led_state[1];
			o->led_b = e->led_state[2];
			break;
		case CHIAKI_EVENT_PLAYER_INDEX:
			o->player_index = e->player_index;
			break;
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
			o->haptic_intensity = (uint8_t)e->intensity;
			break;
		case CHIAKI_EVENT_NICKNAME_RECEIVED:
			memcpy(o->nickname, e->server_nickname, sizeof(e->server_nickname));
			o->nickname[sizeof(o->nickname) - 1] = '\0';
			break;
		case CHIAKI_EVENT_REGIST:
			o->registered_host = &e->host;
			break;
		case CHIAKI_EVENT_VIDEO_FEC_FAILURE:
			o->fec_frame_index = e->video_fec_failure.frame_index;
			break;
		default:
			break;
	}
}

void shiro_registered_host_flatten(const ChiakiRegisteredHost *h, ShiroRegisteredHost *o)
{
	memset(o, 0, sizeof(*o));
	o->target = h->target;
	memcpy(o->nickname, h->server_nickname, sizeof(h->server_nickname));
	o->nickname[sizeof(o->nickname) - 1] = '\0';
	memcpy(o->mac, h->server_mac, sizeof(o->mac));
	memcpy(o->regist_key, h->rp_regist_key, sizeof(o->regist_key));
	memcpy(o->rp_key, h->rp_key, sizeof(o->rp_key));
	o->rp_key_type = h->rp_key_type;
	o->console_pin = h->console_pin;
}

// ---------------------------------------------------------------- registration

ChiakiErrorCode shiro_regist_start(ChiakiRegist *regist, ChiakiLog *log, ChiakiTarget target,
		const char *host, const uint8_t *psn_account_id, uint32_t pin,
		ChiakiRegistCb cb, void *user)
{
	ChiakiRegistInfo info;
	memset(&info, 0, sizeof(info));
	info.target = target;
	info.host = host;
	info.broadcast = false;
	info.psn_online_id = NULL;
	if(psn_account_id)
		memcpy(info.psn_account_id, psn_account_id, CHIAKI_PSN_ACCOUNT_ID_SIZE);
	info.pin = pin;
	info.console_pin = 0;
	info.holepunch_info = NULL;
	return chiaki_regist_start(regist, log, &info, cb, user);
}

// ---------------------------------------------------------------- discovery

ChiakiErrorCode shiro_discovery_service_start(ChiakiDiscoveryService *service,
		const uint32_t *ipv4_addrs, size_t count, uint64_t ping_ms,
		ChiakiDiscoveryServiceCb cb, void *user, ChiakiLog *log)
{
	ChiakiDiscoveryServiceOptions options;
	memset(&options, 0, sizeof(options));
	options.hosts_max = 32;
	options.host_drop_pings = 4;
	options.ping_ms = ping_ms;
	options.ping_initial_ms = 50;
	options.cb = cb;
	options.cb_user = user;

	struct sockaddr_in send_addr;
	memset(&send_addr, 0, sizeof(send_addr));
	send_addr.sin_family = AF_INET;
#ifdef __APPLE__
	send_addr.sin_len = sizeof(send_addr);
#endif
	send_addr.sin_addr.s_addr = 0xffffffff; // broadcast: enables the extra (unicast) address list
	options.send_addr = (struct sockaddr_storage *)&send_addr;
	options.send_addr_size = sizeof(send_addr);

	struct sockaddr_storage *addrs = NULL;
	if(count > 0)
	{
		addrs = calloc(count, sizeof(struct sockaddr_storage));
		if(!addrs)
			return CHIAKI_ERR_MEMORY;
		for(size_t i = 0; i < count; i++)
		{
			struct sockaddr_in *a = (struct sockaddr_in *)&addrs[i];
			a->sin_family = AF_INET;
#ifdef __APPLE__
			a->sin_len = sizeof(struct sockaddr_in);
#endif
			a->sin_addr.s_addr = ipv4_addrs[i];
		}
	}
	options.broadcast_addrs = addrs;
	options.broadcast_num = count;

	ChiakiErrorCode err = chiaki_discovery_service_init(service, &options, log);
	free(addrs); // copied by chiaki_discovery_service_init
	return err;
}

ChiakiErrorCode shiro_wakeup(ChiakiLog *log, const char *host, const uint8_t *regist_key, bool ps5)
{
	char key[CHIAKI_SESSION_AUTH_SIZE + 1];
	memcpy(key, regist_key, CHIAKI_SESSION_AUTH_SIZE);
	key[CHIAKI_SESSION_AUTH_SIZE] = '\0';
	uint64_t credential = strtoull(key, NULL, 16);
	return chiaki_discovery_wakeup(log, NULL, host, credential, ps5);
}

// ---------------------------------------------------------------- holepunch / PSN

size_t shiro_psn_list_devices(const char *token, bool ps5, ShiroPsnDevice *out, size_t max, ChiakiLog *log, ChiakiErrorCode *err_out)
{
	ChiakiHolepunchDeviceInfo *devices = NULL;
	size_t count = 0;
	ChiakiErrorCode err = chiaki_holepunch_list_devices(token,
			ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4,
			&devices, &count, log);
	if(err_out)
		*err_out = err;
	if(err != CHIAKI_ERR_SUCCESS || !devices)
		return 0;
	size_t n = count < max ? count : max;
	for(size_t i = 0; i < n; i++)
	{
		memset(&out[i], 0, sizeof(out[i]));
		out[i].ps5 = devices[i].type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5;
		memcpy(out[i].name, devices[i].device_name, sizeof(devices[i].device_name));
		out[i].name[sizeof(out[i].name) - 1] = '\0';
		memcpy(out[i].duid, devices[i].device_uid, sizeof(out[i].duid));
		out[i].remoteplay_enabled = devices[i].remoteplay_enabled;
	}
	chiaki_holepunch_free_device_list(&devices);
	return n;
}

ChiakiErrorCode shiro_psn_connect(ChiakiHolepunchSession session, const uint8_t *duid, size_t duid_len, bool ps5)
{
	(void)duid_len;
	ChiakiHolepunchConsoleType type = ps5 ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5 : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4;
	ChiakiErrorCode err = chiaki_holepunch_upnp_discover(session);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	err = chiaki_holepunch_session_create(session);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	err = holepunch_session_create_offer(session);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	err = chiaki_holepunch_session_start(session, duid, type);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	return chiaki_holepunch_session_punch_hole(session, CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL);
}
