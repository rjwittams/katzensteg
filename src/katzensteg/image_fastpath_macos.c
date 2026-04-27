#include <Accelerate/Accelerate.h>
#include <pthread.h>
#include <stdint.h>

static pthread_once_t ks_vimage_once = PTHREAD_ONCE_INIT;
static vImage_YpCbCrToARGB ks_vimage_planar_420;
static vImage_YpCbCrToARGB ks_vimage_biplanar_420;
static int ks_vimage_planar_ready = 0;
static int ks_vimage_biplanar_ready = 0;

static void ks_vimage_init(void) {
    const vImage_YpCbCrPixelRange pixel_range = {
        16, 128, 235, 240, 255, 0, 255, 0,
    };

    ks_vimage_planar_ready =
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &pixel_range,
            &ks_vimage_planar_420,
            kvImage420Yp8_Cb8_Cr8,
            kvImageARGB8888,
            kvImageNoFlags) == kvImageNoError;

    ks_vimage_biplanar_ready =
        vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
            &pixel_range,
            &ks_vimage_biplanar_420,
            kvImage420Yp8_CbCr8,
            kvImageARGB8888,
            kvImageNoFlags) == kvImageNoError;
}

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

    pthread_once(&ks_vimage_once, ks_vimage_init);
    if (!ks_vimage_planar_ready) {
        return 0;
    }

    vImage_Buffer src_y = {
        .data = (void *)yplane,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)ypitch,
    };
    vImage_Buffer src_u = {
        .data = (void *)uplane,
        .height = (vImagePixelCount)(height / 2),
        .width = (vImagePixelCount)(width / 2),
        .rowBytes = (size_t)upitch,
    };
    vImage_Buffer src_v = {
        .data = (void *)vplane,
        .height = (vImagePixelCount)(height / 2),
        .width = (vImagePixelCount)(width / 2),
        .rowBytes = (size_t)vpitch,
    };
    vImage_Buffer dst = {
        .data = dst_rgba,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)width * 4,
    };
    const uint8_t rgba_permute[4] = {1, 2, 3, 0};

    return vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
               &src_y,
               &src_u,
               &src_v,
               &dst,
               &ks_vimage_planar_420,
               rgba_permute,
               255,
               kvImageNoFlags) == kvImageNoError;
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

    pthread_once(&ks_vimage_once, ks_vimage_init);
    if (!ks_vimage_biplanar_ready) {
        return 0;
    }

    vImage_Buffer src_y = {
        .data = (void *)yplane,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)ypitch,
    };
    vImage_Buffer src_uv = {
        .data = (void *)uvplane,
        .height = (vImagePixelCount)(height / 2),
        .width = (vImagePixelCount)(width / 2),
        .rowBytes = (size_t)uvpitch,
    };
    vImage_Buffer dst = {
        .data = dst_rgba,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)width * 4,
    };
    const uint8_t rgba_permute[4] = {1, 2, 3, 0};

    return vImageConvert_420Yp8_CbCr8ToARGB8888(
               &src_y,
               &src_uv,
               &dst,
               &ks_vimage_biplanar_420,
               rgba_permute,
               255,
               kvImageNoFlags) == kvImageNoError;
}

int ks_fast_bgra_to_rgba(uint8_t *dst_rgba,
                         int width,
                         int height,
                         const uint8_t *src_bgra) {
    if (!dst_rgba || !src_bgra || width <= 0 || height <= 0) {
        return 0;
    }

    vImage_Buffer src = {
        .data = (void *)src_bgra,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)width * 4,
    };
    vImage_Buffer dst = {
        .data = dst_rgba,
        .height = (vImagePixelCount)height,
        .width = (vImagePixelCount)width,
        .rowBytes = (size_t)width * 4,
    };
    const uint8_t bgra_to_rgba[4] = {2, 1, 0, 3};

    return vImagePermuteChannels_ARGB8888(&src, &dst, bgra_to_rgba, kvImageNoFlags) == kvImageNoError;
}

int ks_fast_a2b10g10r10_to_rgba(uint8_t *dst_rgba,
                                int width,
                                int height,
                                const uint8_t *src_a2b10g10r10) {
    (void)dst_rgba;
    (void)width;
    (void)height;
    (void)src_a2b10g10r10;
    return 0;
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

    vImage_Buffer src = {
        .data = (void *)src_rgba,
        .height = (vImagePixelCount)src_height,
        .width = (vImagePixelCount)src_width,
        .rowBytes = (size_t)src_width * 4,
    };
    vImage_Buffer dst = {
        .data = dst_rgba,
        .height = (vImagePixelCount)dst_height,
        .width = (vImagePixelCount)dst_width,
        .rowBytes = (size_t)dst_width * 4,
    };

    return vImageScale_ARGB8888(&src, &dst, NULL, kvImageNoFlags) == kvImageNoError;
}
