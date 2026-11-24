#include "ShiroNAL.h"

#include <stdlib.h>
#include <string.h>

// Returns the offset of the first byte after the next start code at or after
// @p pos, and stores the start code length. Returns len if none.
static size_t next_start_code(const uint8_t *buf, size_t len, size_t pos, size_t *sc_len)
{
	while(pos + 3 <= len)
	{
		// Fast skip: a start code requires buf[pos+2] <= 1.
		if(buf[pos + 2] > 1)
		{
			pos += 3;
			continue;
		}
		if(buf[pos] == 0 && buf[pos + 1] == 0 && buf[pos + 2] == 1)
		{
			if(pos > 0 && buf[pos - 1] == 0)
			{
				*sc_len = 4;
				return pos + 3;
			}
			*sc_len = 3;
			return pos + 3;
		}
		pos++;
	}
	*sc_len = 0;
	return len;
}

uint8_t *shiro_annexb_to_lp(const uint8_t *in, size_t in_len, bool hevc, size_t *out_len, ShiroFrameInfo *info)
{
	memset(info, 0, sizeof(*info));
	*out_len = 0;
	if(!in || in_len < 4)
		return NULL;

	// Worst case: every 3-byte start code becomes a 4-byte length.
	size_t cap = in_len + in_len / 3 + 16;
	uint8_t *out = malloc(cap);
	if(!out)
		return NULL;
	size_t o = 0;

	size_t sc_len = 0;
	size_t nal_start = next_start_code(in, in_len, 0, &sc_len);
	if(sc_len == 0)
	{
		// No start code: treat the whole buffer as a single NAL unit.
		nal_start = 0;
	}

	while(nal_start < in_len)
	{
		size_t next_sc_len = 0;
		size_t next = next_start_code(in, in_len, nal_start, &next_sc_len);
		size_t nal_end = next_sc_len ? next - next_sc_len : in_len;
		// Trim trailing zero bytes (they belong to the next 4-byte start code / padding).
		while(nal_end > nal_start && in[nal_end - 1] == 0 && next_sc_len)
			nal_end--;

		size_t nal_len = nal_end - nal_start;
		if(nal_len > 0)
		{
			const uint8_t *nal = in + nal_start;
			bool keep = true;
			if(hevc)
			{
				uint8_t type = (nal[0] >> 1) & 0x3f;
				switch(type)
				{
					case 32: info->vps = nal; info->vps_len = nal_len; keep = false; break;
					case 33: info->sps = nal; info->sps_len = nal_len; keep = false; break;
					case 34: info->pps = nal; info->pps_len = nal_len; keep = false; break;
					case 35: keep = false; break; // AUD
					default:
						if(type >= 16 && type <= 21)
							info->is_keyframe = true;
						break;
				}
			}
			else
			{
				uint8_t type = nal[0] & 0x1f;
				switch(type)
				{
					case 7: info->sps = nal; info->sps_len = nal_len; keep = false; break;
					case 8: info->pps = nal; info->pps_len = nal_len; keep = false; break;
					case 9: keep = false; break; // AUD
					case 5: info->is_keyframe = true; break;
					default: break;
				}
			}
			if(keep)
			{
				if(o + 4 + nal_len > cap)
				{
					cap = (o + 4 + nal_len) * 2;
					uint8_t *n = realloc(out, cap);
					if(!n)
					{
						free(out);
						return NULL;
					}
					out = n;
				}
				out[o++] = (uint8_t)(nal_len >> 24);
				out[o++] = (uint8_t)(nal_len >> 16);
				out[o++] = (uint8_t)(nal_len >> 8);
				out[o++] = (uint8_t)(nal_len);
				memcpy(out + o, nal, nal_len);
				o += nal_len;
				info->nal_count++;
			}
		}
		if(!next_sc_len)
			break;
		nal_start = next;
	}

	if(o == 0)
	{
		free(out);
		return NULL;
	}
	*out_len = o;
	return out;
}
