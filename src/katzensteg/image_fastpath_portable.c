#include <stdint.h>
#include <stddef.h>
#include <libyuv.h>

int ks_fast_i420_to_rgba(uint8_t *dst_rgba,
                         int width,
                         int height,
                         const uint8_t *yplane,
                         int ypitch,
                         const uint8_t *uplane,
                         int upitch,
                         const uint8_t *vplane,
                         int vpitch) {
    if (!dst_rgba || !yplane || !uplane || !vplane ||
        width <= 0 || height <= 0 || ypitch <= 0 || upitch <= 0 || vpitch <= 0 ||
        (width & 1) || (height & 1)) {
        return 0;
    }

    return I420ToABGR(yplane,
                      ypitch,
                      uplane,
                      upitch,
                      vplane,
                      vpitch,
                      dst_rgba,
                      width * 4,
                      width,
                      height) == 0;
}

int ks_fast_nv12_to_rgba(uint8_t *dst_rgba,
                         int width,
                         int height,
                         const uint8_t *yplane,
                         int ypitch,
                         const uint8_t *uvplane,
                         int uvpitch) {
    if (!dst_rgba || !yplane || !uvplane ||
        width <= 0 || height <= 0 || ypitch <= 0 || uvpitch <= 0 ||
        (width & 1) || (height & 1)) {
        return 0;
    }

    return NV12ToABGR(yplane,
                      ypitch,
                      uvplane,
                      uvpitch,
                      dst_rgba,
                      width * 4,
                      width,
                      height) == 0;
}

int ks_fast_bgra_to_rgba(uint8_t *dst_rgba,
                         int width,
                         int height,
                         const uint8_t *src_bgra) {
    if (!dst_rgba || !src_bgra || width <= 0 || height <= 0) {
        return 0;
    }

    return ARGBToABGR(src_bgra,
                      width * 4,
                      dst_rgba,
                      width * 4,
                      width,
                      height) == 0;
}

int ks_fast_scale_rgba(uint8_t *dst_rgba,
                       int dst_width,
                       int dst_height,
                       const uint8_t *src_rgba,
                       int src_width,
                       int src_height) {
    if (!dst_rgba || !src_rgba ||
        dst_width <= 0 || dst_height <= 0 || src_width <= 0 || src_height <= 0) {
        return 0;
    }

    return ARGBScale(src_rgba,
                     src_width * 4,
                     src_width,
                     src_height,
                     dst_rgba,
                     dst_width * 4,
                     dst_width,
                     dst_height,
                     kFilterNone) == 0;
}
