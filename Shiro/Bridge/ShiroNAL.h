// Annex-B (start-code delimited) → length-prefixed (AVCC/HVCC) conversion for
// VideoToolbox. Written in C because it runs on every video frame.
#ifndef SHIRO_NAL_H
#define SHIRO_NAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct shiro_frame_info_t
{
	// Parameter sets found in this access unit (pointers into the input buffer).
	const uint8_t *vps; size_t vps_len; // HEVC only
	const uint8_t *sps; size_t sps_len;
	const uint8_t *pps; size_t pps_len;
	bool is_keyframe;
	size_t nal_count;
} ShiroFrameInfo;

/**
 * Converts one Annex-B access unit into a malloc()ed buffer of 4-byte
 * big-endian length-prefixed NAL units. Parameter sets and access unit
 * delimiters are stripped from the output and reported in @p info instead.
 *
 * @return malloc()ed buffer (free with free() or hand to CoreMedia with
 *         kCFAllocatorMalloc) or NULL if the frame contained no slice data.
 */
uint8_t *shiro_annexb_to_lp(const uint8_t *in, size_t in_len, bool hevc, size_t *out_len, ShiroFrameInfo *info);

#ifdef __cplusplus
}
#endif

#endif
