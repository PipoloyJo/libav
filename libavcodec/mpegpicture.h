/*
 * Mpeg video formats-related defines and utility functions
 *
 * This file is part of Libav.
 *
 * Libav is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * Libav is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with Libav; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef AVCODEC_MPEGPICTURE_H
#define AVCODEC_MPEGPICTURE_H

#include <stdint.h>

#include "libavutil/frame.h"

#include "avcodec.h"
#include "thread.h"

#define MAX_PICTURE_COUNT 32

/**
 * Picture.
 */
typedef struct Picture {
    struct AVFrame *f;
    ThreadFrame tf;

    AVBufferRef *qscale_table_buf;
    int8_t *qscale_table;

    AVBufferRef *motion_val_buf[2];
    int16_t (*motion_val[2])[2];

    AVBufferRef *mb_type_buf;
    uint32_t *mb_type;          ///< types and macros are defined in mpegutils.h

    AVBufferRef *mbskip_table_buf;
    uint8_t *mbskip_table;

    AVBufferRef *ref_index_buf[2];
    int8_t *ref_index[2];

    AVBufferRef *mb_var_buf;
    uint16_t *mb_var;           ///< Table for MB variances

    AVBufferRef *mc_mb_var_buf;
    uint16_t *mc_mb_var;        ///< Table for motion compensated MB variances

    AVBufferRef *mb_mean_buf;
    uint8_t *mb_mean;           ///< Table for MB luminance

    AVBufferRef *hwaccel_priv_buf;
    void *hwaccel_picture_private; ///< Hardware accelerator private data

    int field_picture;          ///< whether or not the picture was encoded in separate fields

    int mb_var_sum;             ///< sum of MB variance for current frame
    int mc_mb_var_sum;          ///< motion compensated MB variance for current frame

    int b_frame_score;          /* */
    int needs_realloc;          ///< Picture needs to be reallocated (eg due to a frame size change)

    int reference;
    int shared;
} Picture;

int ff_mpeg_ref_picture(AVCodecContext *avctx, Picture *dst, Picture *src);
void ff_mpeg_unref_picture(AVCodecContext *avctx, Picture *picture);

void ff_free_picture_tables(Picture *pic);
int ff_update_picture_tables(Picture *dst, Picture *src);

int ff_find_unused_picture(AVCodecContext *avctx, Picture *picture, int shared);

#endif /* AVCODEC_MPEGPICTURE_H */
