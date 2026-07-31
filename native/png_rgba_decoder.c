#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#pragma comment(lib, "bcrypt.lib")

/*
 * Exact, dependency-bounded PNG-to-RGBA decoder for SketchUp 2017.
 *
 * The importer already ships libpng16.dll and zlib.dll with Poppler. This
 * helper dynamically loads libpng's stable simplified API, writes decoded
 * pixels directly into a disk-backed mapping, and calculates the same
 * premultiplied visual SHA-256 used by the Ruby compatibility path.
 */

typedef uint32_t png_uint_32;
typedef int32_t png_int_32;

typedef struct png_image {
  void *opaque;
  png_uint_32 version;
  png_uint_32 width;
  png_uint_32 height;
  png_uint_32 format;
  png_uint_32 flags;
  png_uint_32 colormap_entries;
  png_uint_32 warning_or_error;
  char message[64];
} png_image;

typedef int (__cdecl *png_begin_memory_fn)(
  png_image *, const void *, size_t
);
typedef int (__cdecl *png_finish_read_fn)(
  png_image *, const void *, void *, png_int_32, void *
);
typedef void (__cdecl *png_image_free_fn)(png_image *);

#define PNG_IMAGE_VERSION 1U
#define PNG_FORMAT_RGBA 3U
#define CANONICAL_CHUNK_BYTES (1024U * 1024U)
#define Z_NO_FLUSH 0
#define Z_OK 0
#define Z_STREAM_END 1

typedef unsigned char Bytef;
typedef unsigned int uInt;
typedef unsigned long uLong;
typedef void *voidpf;
typedef voidpf (__cdecl *z_alloc_func)(voidpf, uInt, uInt);
typedef void (__cdecl *z_free_func)(voidpf, voidpf);
struct internal_state;
typedef struct z_stream_s {
  Bytef *next_in;
  uInt avail_in;
  uLong total_in;
  Bytef *next_out;
  uInt avail_out;
  uLong total_out;
  char *msg;
  struct internal_state *state;
  z_alloc_func zalloc;
  z_free_func zfree;
  voidpf opaque;
  int data_type;
  uLong adler;
  uLong reserved;
} z_stream;
typedef const char *(__cdecl *zlib_version_fn)(void);
typedef int (__cdecl *inflate_init_fn)(z_stream *, const char *, int);
typedef int (__cdecl *inflate_fn)(z_stream *, int);
typedef int (__cdecl *inflate_end_fn)(z_stream *);
typedef uLong (__cdecl *crc32_fn)(uLong, const Bytef *, uInt);

typedef struct visual_hash_state {
  BCRYPT_ALG_HANDLE algorithm;
  BCRYPT_HASH_HANDLE hash;
  unsigned char *hash_object;
  unsigned char *canonical;
  DWORD object_size;
  int transparent;
  int visible;
} visual_hash_state;

static uint32_t read_be32(const unsigned char *bytes) {
  return ((uint32_t)bytes[0] << 24) |
         ((uint32_t)bytes[1] << 16) |
         ((uint32_t)bytes[2] << 8) |
         (uint32_t)bytes[3];
}

static int validate_png_header(
  const unsigned char *bytes, uint64_t size, int require_alpha
) {
  static const unsigned char signature[8] = {
    0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'
  };
  if (size < 33 || memcmp(bytes, signature, 8) != 0) {
    fwprintf(stderr, L"PNG signature is invalid\n");
    return 0;
  }
  if (read_be32(bytes + 8) != 13 || memcmp(bytes + 12, "IHDR", 4) != 0) {
    fwprintf(stderr, L"PNG IHDR is missing or invalid\n");
    return 0;
  }
  if (read_be32(bytes + 16) == 0 || read_be32(bytes + 20) == 0 ||
      bytes[24] != 8 ||
      (bytes[25] != 6 && (require_alpha || bytes[25] != 2)) ||
      bytes[26] != 0 ||
      bytes[27] != 0 || bytes[28] != 0) {
    fwprintf(
      stderr,
      require_alpha ?
        L"item Raster page must be a noninterlaced 8-bit RGBA PNG\n" :
        L"texture export must be a noninterlaced 8-bit RGB/RGBA PNG\n"
    );
    return 0;
  }
  return 1;
}

static void visual_hash_cleanup(visual_hash_state *state) {
  if (!state) return;
  if (state->hash) BCryptDestroyHash(state->hash);
  if (state->algorithm) BCryptCloseAlgorithmProvider(state->algorithm, 0);
  if (state->canonical) HeapFree(GetProcessHeap(), 0, state->canonical);
  if (state->hash_object) HeapFree(GetProcessHeap(), 0, state->hash_object);
  memset(state, 0, sizeof(*state));
}

static int visual_hash_begin(visual_hash_state *state) {
  DWORD object_size = 0;
  DWORD hash_size = 0;
  DWORD received = 0;
  NTSTATUS status;
  if (!state) return 0;
  memset(state, 0, sizeof(*state));
  status = BCryptOpenAlgorithmProvider(
    &state->algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0
  );
  if (status < 0) goto failure;
  status = BCryptGetProperty(
    state->algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size,
    sizeof(object_size), &received, 0
  );
  if (status < 0 || object_size == 0) goto failure;
  status = BCryptGetProperty(
    state->algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&hash_size,
    sizeof(hash_size), &received, 0
  );
  if (status < 0 || hash_size != 32) goto failure;

  state->hash_object = (unsigned char *)HeapAlloc(
    GetProcessHeap(), 0, object_size
  );
  state->canonical = (unsigned char *)HeapAlloc(
    GetProcessHeap(), 0, CANONICAL_CHUNK_BYTES
  );
  if (!state->hash_object || !state->canonical) goto failure;
  state->object_size = object_size;
  status = BCryptCreateHash(
    state->algorithm, &state->hash, state->hash_object,
    object_size, NULL, 0, 0
  );
  if (status < 0) goto failure;
  return 1;

failure:
  visual_hash_cleanup(state);
  fwprintf(stderr, L"Windows SHA-256 initialization failed\n");
  return 0;
}

static int visual_hash_update(
  visual_hash_state *state,
  const unsigned char *rgba,
  uint64_t byte_size
) {
  uint64_t offset = 0;
  NTSTATUS status;
  if (!state || !state->hash || !rgba || byte_size % 4U != 0) return 0;

  while (offset < byte_size) {
    ULONG chunk = (ULONG)(
      byte_size - offset > CANONICAL_CHUNK_BYTES ?
        CANONICAL_CHUNK_BYTES : byte_size - offset
    );
    ULONG index;
    chunk -= chunk % 4U;
    if (chunk == 0) return 0;
    for (index = 0; index < chunk; index += 4U) {
      unsigned int alpha = rgba[offset + index + 3U];
      state->canonical[index] = (unsigned char)(
        ((unsigned int)rgba[offset + index] * alpha + 127U) / 255U
      );
      state->canonical[index + 1U] = (unsigned char)(
        ((unsigned int)rgba[offset + index + 1U] * alpha + 127U) / 255U
      );
      state->canonical[index + 2U] = (unsigned char)(
        ((unsigned int)rgba[offset + index + 2U] * alpha + 127U) / 255U
      );
      state->canonical[index + 3U] = (unsigned char)alpha;
      if (alpha < 255U) state->transparent = 1;
      if (alpha > 0U) state->visible = 1;
    }
    status = BCryptHashData(state->hash, state->canonical, chunk, 0);
    if (status < 0) return 0;
    offset += chunk;
  }
  return 1;
}

static int visual_hash_finish(
  visual_hash_state *state,
  unsigned char digest[32],
  int *transparent,
  int *visible
) {
  NTSTATUS status;
  if (!state || !state->hash) return 0;
  status = BCryptFinishHash(state->hash, digest, 32, 0);
  if (status < 0) return 0;
  *transparent = state->transparent;
  *visible = state->visible;
  return 1;
}

static int sha256_visual(
  const unsigned char *rgba,
  uint64_t byte_size,
  unsigned char digest[32],
  int *transparent,
  int *visible
) {
  visual_hash_state state;
  int ok = 0;
  if (!visual_hash_begin(&state)) return 0;
  if (!visual_hash_update(&state, rgba, byte_size)) goto cleanup;
  if (!visual_hash_finish(&state, digest, transparent, visible)) goto cleanup;
  ok = 1;

cleanup:
  visual_hash_cleanup(&state);
  if (!ok) fwprintf(stderr, L"Windows SHA-256 calculation failed\n");
  return ok;
}

static HMODULE load_bundled_libpng(void) {
  wchar_t executable_path[32768];
  wchar_t relative_bin[32768];
  wchar_t bin_path[32768];
  wchar_t dll_path[32768];
  DWORD length = GetModuleFileNameW(NULL, executable_path, 32768);
  wchar_t *separator;
  HMODULE module;
  if (length == 0 || length >= 32768) return NULL;
  separator = wcsrchr(executable_path, L'\\');
  if (!separator) return NULL;
  separator[1] = L'\0';
  if (wcslen(executable_path) + wcslen(L"..\\Library\\bin") + 1 >= 32768) {
    return NULL;
  }
  wcscpy_s(relative_bin, 32768, executable_path);
  wcscat_s(relative_bin, 32768, L"..\\Library\\bin");
  if (!GetFullPathNameW(relative_bin, 32768, bin_path, NULL)) return NULL;
  if (wcslen(bin_path) + wcslen(L"\\libpng16.dll") + 1 >= 32768) {
    return NULL;
  }
  wcscpy_s(dll_path, 32768, bin_path);
  wcscat_s(dll_path, 32768, L"\\libpng16.dll");
  if (!SetDllDirectoryW(bin_path)) return NULL;
  module = LoadLibraryW(dll_path);
  SetDllDirectoryW(NULL);
  return module;
}

static HMODULE load_bundled_zlib(void) {
  wchar_t executable_path[32768];
  wchar_t relative_bin[32768];
  wchar_t bin_path[32768];
  wchar_t dll_path[32768];
  DWORD length = GetModuleFileNameW(NULL, executable_path, 32768);
  wchar_t *separator;
  HMODULE module;
  if (length == 0 || length >= 32768) return NULL;
  separator = wcsrchr(executable_path, L'\\');
  if (!separator) return NULL;
  separator[1] = L'\0';
  if (wcslen(executable_path) + wcslen(L"..\\Library\\bin") + 1 >= 32768) {
    return NULL;
  }
  wcscpy_s(relative_bin, 32768, executable_path);
  wcscat_s(relative_bin, 32768, L"..\\Library\\bin");
  if (!GetFullPathNameW(relative_bin, 32768, bin_path, NULL)) return NULL;
  if (wcslen(bin_path) + wcslen(L"\\zlib.dll") + 1 >= 32768) return NULL;
  wcscpy_s(dll_path, 32768, bin_path);
  wcscat_s(dll_path, 32768, L"\\zlib.dll");
  if (!SetDllDirectoryW(bin_path)) return NULL;
  module = LoadLibraryW(dll_path);
  SetDllDirectoryW(NULL);
  return module;
}

static unsigned char paeth_predictor(
  unsigned char left,
  unsigned char up,
  unsigned char upper_left
) {
  int estimate = (int)left + (int)up - (int)upper_left;
  int left_distance = abs(estimate - (int)left);
  int up_distance = abs(estimate - (int)up);
  int diagonal_distance = abs(estimate - (int)upper_left);
  if (left_distance <= up_distance && left_distance <= diagonal_distance) {
    return left;
  }
  if (up_distance <= diagonal_distance) return up;
  return upper_left;
}

static int unfilter_row(
  unsigned char *row,
  const unsigned char *previous,
  uint64_t row_bytes,
  unsigned int filter,
  unsigned int bytes_per_pixel
) {
  uint64_t index;
  if (filter > 4U) {
    fwprintf(stderr, L"unsupported PNG row filter %u\n", filter);
    return 0;
  }
  for (index = 0; index < row_bytes; ++index) {
    unsigned char left = index >= bytes_per_pixel ?
      row[index - bytes_per_pixel] : 0;
    unsigned char up = previous ? previous[index] : 0;
    unsigned char upper_left = previous && index >= bytes_per_pixel ?
      previous[index - bytes_per_pixel] : 0;
    unsigned char predictor = 0;
    if (filter == 1U) predictor = left;
    else if (filter == 2U) predictor = up;
    else if (filter == 3U) {
      predictor = (unsigned char)(((unsigned int)left + (unsigned int)up) / 2U);
    } else if (filter == 4U) {
      predictor = paeth_predictor(left, up, upper_left);
    }
    row[index] = (unsigned char)(row[index] + predictor);
  }
  return 1;
}

static int validate_chunk_crc(
  crc32_fn calculate_crc,
  const unsigned char *type,
  const unsigned char *data,
  uint32_t length,
  uint32_t expected
) {
  uLong actual;
  if (!calculate_crc) return 0;
  actual = calculate_crc(0UL, NULL, 0);
  actual = calculate_crc(actual, type, 4U);
  if (length > 0U) actual = calculate_crc(actual, data, (uInt)length);
  if ((uint32_t)actual != expected) {
    fprintf(stderr, "PNG %.4s CRC is invalid\n", type);
    return 0;
  }
  return 1;
}

static int inspect_png_stream(
  const unsigned char *bytes,
  uint64_t size,
  int require_alpha,
  png_uint_32 *pixel_width,
  png_uint_32 *pixel_height,
  unsigned char digest[32],
  int *transparent,
  int *visible
) {
  HMODULE zlib = NULL;
  zlib_version_fn version_fn = NULL;
  inflate_init_fn initialize = NULL;
  inflate_fn inflate_stream = NULL;
  inflate_end_fn end_stream = NULL;
  crc32_fn calculate_crc = NULL;
  z_stream stream;
  visual_hash_state hash_state;
  unsigned char *scanline = NULL;
  unsigned char *previous = NULL;
  unsigned char *rgba_row = NULL;
  uint64_t offset = 8;
  uint64_t row_bytes = 0;
  uint64_t scanline_bytes = 0;
  uint64_t filled = 0;
  uint64_t rows = 0;
  unsigned int bytes_per_pixel = 0;
  unsigned int color_type = 0;
  int seen_ihdr = 0;
  int seen_idat = 0;
  int seen_iend = 0;
  int stream_initialized = 0;
  int stream_ended = 0;
  int hash_initialized = 0;
  int ok = 0;

  memset(&stream, 0, sizeof(stream));
  memset(&hash_state, 0, sizeof(hash_state));
  zlib = load_bundled_zlib();
  if (!zlib) {
    fwprintf(stderr, L"bundled zlib.dll could not be loaded\n");
    goto cleanup;
  }
  version_fn = (zlib_version_fn)GetProcAddress(zlib, "zlibVersion");
  initialize = (inflate_init_fn)GetProcAddress(zlib, "inflateInit_");
  inflate_stream = (inflate_fn)GetProcAddress(zlib, "inflate");
  end_stream = (inflate_end_fn)GetProcAddress(zlib, "inflateEnd");
  calculate_crc = (crc32_fn)GetProcAddress(zlib, "crc32");
  if (!version_fn || !initialize || !inflate_stream || !end_stream ||
      !calculate_crc) {
    fwprintf(stderr, L"bundled zlib streaming API is unavailable\n");
    goto cleanup;
  }

  while (offset + 12U <= size) {
    uint32_t length = read_be32(bytes + offset);
    const unsigned char *type = bytes + offset + 4U;
    const unsigned char *data = bytes + offset + 8U;
    uint64_t next = offset + 12U + (uint64_t)length;
    uint32_t expected_crc;
    if (length > 268435456U || next > size) {
      fwprintf(stderr, L"PNG chunk is truncated or unreasonably large\n");
      goto cleanup;
    }
    expected_crc = read_be32(data + length);
    if (!validate_chunk_crc(
          calculate_crc, type, data, length, expected_crc
        )) goto cleanup;

    if (memcmp(type, "IHDR", 4) == 0) {
      if (seen_ihdr || offset != 8U || length != 13U) {
        fwprintf(stderr, L"PNG IHDR ordering or size is invalid\n");
        goto cleanup;
      }
      *pixel_width = read_be32(data);
      *pixel_height = read_be32(data + 4U);
      color_type = data[9];
      bytes_per_pixel = color_type == 6U ? 4U : 3U;
      row_bytes = (uint64_t)(*pixel_width) * bytes_per_pixel;
      scanline_bytes = row_bytes + 1U;
      if (*pixel_width == 0U || *pixel_height == 0U ||
          row_bytes == 0U || scanline_bytes > (uint64_t)SIZE_MAX ||
          scanline_bytes > (uint64_t)UINT_MAX) {
        fwprintf(stderr, L"decoded PNG dimensions are invalid or too large\n");
        goto cleanup;
      }
      scanline = (unsigned char *)HeapAlloc(
        GetProcessHeap(), 0, (SIZE_T)scanline_bytes
      );
      previous = (unsigned char *)HeapAlloc(
        GetProcessHeap(), HEAP_ZERO_MEMORY, (SIZE_T)row_bytes
      );
      rgba_row = (unsigned char *)HeapAlloc(
        GetProcessHeap(), 0, (SIZE_T)(*pixel_width) * 4U
      );
      if (!scanline || !previous || !rgba_row ||
          !visual_hash_begin(&hash_state)) {
        fwprintf(stderr, L"streaming PNG row allocation failed\n");
        goto cleanup;
      }
      hash_initialized = 1;
      seen_ihdr = 1;
    } else if (memcmp(type, "IDAT", 4) == 0) {
      if (!seen_ihdr || seen_iend || stream_ended) {
        fwprintf(stderr, L"PNG IDAT ordering is invalid\n");
        goto cleanup;
      }
      if (!stream_initialized) {
        if (initialize(&stream, version_fn(), (int)sizeof(stream)) != Z_OK) {
          fwprintf(stderr, L"zlib PNG stream initialization failed\n");
          goto cleanup;
        }
        stream_initialized = 1;
      }
      seen_idat = 1;
      stream.next_in = (Bytef *)data;
      stream.avail_in = (uInt)length;
      while (stream.avail_in > 0U) {
        uInt input_before = stream.avail_in;
        uLong output_before = stream.total_out;
        int status;
        stream.next_out = scanline + filled;
        stream.avail_out = (uInt)(scanline_bytes - filled);
        status = inflate_stream(&stream, Z_NO_FLUSH);
        filled += (uint64_t)(stream.total_out - output_before);
        if (filled == scanline_bytes) {
          uint64_t index;
          unsigned char *row = scanline + 1U;
          if (rows >= *pixel_height ||
              !unfilter_row(
                row, rows > 0U ? previous : NULL, row_bytes,
                scanline[0], bytes_per_pixel
              )) goto cleanup;
          if (color_type == 6U) {
            if (!visual_hash_update(&hash_state, row, row_bytes)) goto cleanup;
          } else {
            for (index = 0; index < *pixel_width; ++index) {
              rgba_row[index * 4U] = row[index * 3U];
              rgba_row[index * 4U + 1U] = row[index * 3U + 1U];
              rgba_row[index * 4U + 2U] = row[index * 3U + 2U];
              rgba_row[index * 4U + 3U] = 255U;
            }
            if (!visual_hash_update(
                  &hash_state, rgba_row, (uint64_t)(*pixel_width) * 4U
                )) goto cleanup;
          }
          memcpy(previous, row, (SIZE_T)row_bytes);
          rows += 1U;
          filled = 0U;
        }
        if (status == Z_STREAM_END) {
          stream_ended = 1;
          if (stream.avail_in != 0U) {
            fwprintf(stderr, L"PNG compressed stream has trailing data\n");
            goto cleanup;
          }
          break;
        }
        if (status != Z_OK ||
            (input_before == stream.avail_in && output_before == stream.total_out)) {
          fwprintf(stderr, L"PNG compressed stream is invalid\n");
          goto cleanup;
        }
      }
    } else if (memcmp(type, "IEND", 4) == 0) {
      if (!seen_ihdr || !seen_idat || seen_iend || length != 0U ||
          !stream_ended || filled != 0U || rows != *pixel_height) {
        fwprintf(stderr, L"PNG scanline stream is incomplete or oversized\n");
        goto cleanup;
      }
      seen_iend = 1;
      offset = next;
      break;
    }
    offset = next;
  }
  if (!seen_iend || !hash_initialized ||
      !visual_hash_finish(&hash_state, digest, transparent, visible)) {
    fwprintf(stderr, L"PNG pixel inspection did not complete\n");
    goto cleanup;
  }
  if (require_alpha && color_type != 6U) {
    fwprintf(stderr, L"item Raster page must be a noninterlaced 8-bit RGBA PNG\n");
    goto cleanup;
  }
  ok = 1;

cleanup:
  if (stream_initialized && end_stream) end_stream(&stream);
  if (hash_initialized) visual_hash_cleanup(&hash_state);
  if (rgba_row) HeapFree(GetProcessHeap(), 0, rgba_row);
  if (previous) HeapFree(GetProcessHeap(), 0, previous);
  if (scanline) HeapFree(GetProcessHeap(), 0, scanline);
  if (zlib) FreeLibrary(zlib);
  return ok;
}

int wmain(int argc, wchar_t **argv) {
  HANDLE input_file = INVALID_HANDLE_VALUE;
  HANDLE input_mapping = NULL;
  HANDLE output_file = INVALID_HANDLE_VALUE;
  HANDLE output_mapping = NULL;
  unsigned char *input_bytes = NULL;
  unsigned char *rgba = NULL;
  LARGE_INTEGER input_size;
  LARGE_INTEGER output_size;
  HMODULE libpng = NULL;
  png_begin_memory_fn begin_read = NULL;
  png_finish_read_fn finish_read = NULL;
  png_image_free_fn free_image = NULL;
  png_image image;
  unsigned char visual_digest[32];
  char visual_hex[65];
  int transparent = 0;
  int visible = 0;
  int image_started = 0;
  int exit_code = 1;
  int require_alpha = 1;
  int inspect_only = 0;
  unsigned int index;

  memset(&image, 0, sizeof(image));
  if (argc != 3 && argc != 4) {
    fwprintf(
      stderr,
      L"usage: png_rgba_decoder.exe input.png "
      L"(output.rgba|--inspect-only) [--allow-rgb]\n"
    );
    return 2;
  }
  inspect_only = wcscmp(argv[2], L"--inspect-only") == 0;
  if (argc == 4) {
    if (wcscmp(argv[3], L"--allow-rgb") != 0) {
      fwprintf(stderr, L"unsupported decoder option\n");
      return 2;
    }
    require_alpha = 0;
  }

  input_file = CreateFileW(
    argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, NULL
  );
  if (input_file == INVALID_HANDLE_VALUE ||
      !GetFileSizeEx(input_file, &input_size) ||
      input_size.QuadPart <= 0 ||
      (uint64_t)input_size.QuadPart > (uint64_t)SIZE_MAX) {
    fwprintf(stderr, L"PNG source is missing, empty, or too large\n");
    goto cleanup;
  }
  input_mapping = CreateFileMappingW(
    input_file, NULL, PAGE_READONLY, 0, 0, NULL
  );
  if (!input_mapping) {
    fwprintf(stderr, L"PNG source mapping failed\n");
    goto cleanup;
  }
  input_bytes = (unsigned char *)MapViewOfFile(
    input_mapping, FILE_MAP_READ, 0, 0, 0
  );
  if (!input_bytes ||
      !validate_png_header(
        input_bytes, (uint64_t)input_size.QuadPart, require_alpha
      )) {
    goto cleanup;
  }

  if (inspect_only) {
    png_uint_32 inspected_width = 0;
    png_uint_32 inspected_height = 0;
    if (!inspect_png_stream(
          input_bytes, (uint64_t)input_size.QuadPart, require_alpha,
          &inspected_width, &inspected_height, visual_digest,
          &transparent, &visible
        )) {
      goto cleanup;
    }
    for (index = 0; index < 32; ++index) {
      static const char digits[] = "0123456789abcdef";
      visual_hex[index * 2U] = digits[(visual_digest[index] >> 4) & 0x0f];
      visual_hex[index * 2U + 1U] = digits[visual_digest[index] & 0x0f];
    }
    visual_hex[64] = '\0';
    printf(
      "{\"pixel_width\":%u,\"pixel_height\":%u,"
      "\"row_bytes\":%u,\"alpha_channel_verified\":%s,"
      "\"transparent_pixel_present\":%s,"
      "\"visible_pixel_present\":%s,\"visual_pixel_sha256\":\"%s\"}\n",
      inspected_width, inspected_height, inspected_width * 4U,
      input_bytes[25] == 6U ? "true" : "false",
      transparent ? "true" : "false",
      visible ? "true" : "false",
      visual_hex
    );
    exit_code = 0;
    goto cleanup;
  }

  libpng = load_bundled_libpng();
  if (!libpng) {
    fwprintf(stderr, L"bundled libpng16.dll could not be loaded\n");
    goto cleanup;
  }
  begin_read = (png_begin_memory_fn)GetProcAddress(
    libpng, "png_image_begin_read_from_memory"
  );
  finish_read = (png_finish_read_fn)GetProcAddress(
    libpng, "png_image_finish_read"
  );
  free_image = (png_image_free_fn)GetProcAddress(
    libpng, "png_image_free"
  );
  if (!begin_read || !finish_read || !free_image) {
    fwprintf(stderr, L"bundled libpng simplified API is unavailable\n");
    goto cleanup;
  }

  image.version = PNG_IMAGE_VERSION;
  if (!begin_read(
        &image, input_bytes, (size_t)input_size.QuadPart
      )) {
    fprintf(stderr, "libpng begin read failed: %s\n", image.message);
    goto cleanup;
  }
  image_started = 1;
  image.format = PNG_FORMAT_RGBA;
  output_size.QuadPart =
    (LONGLONG)image.width * (LONGLONG)image.height * 4LL;
  if (image.width == 0 || image.height == 0 ||
      output_size.QuadPart <= 0 ||
      (uint64_t)output_size.QuadPart > (uint64_t)SIZE_MAX) {
    fwprintf(stderr, L"decoded RGBA dimensions are invalid or too large\n");
    goto cleanup;
  }

  output_file = CreateFileW(
    argv[2], GENERIC_READ | GENERIC_WRITE, 0, NULL, CREATE_ALWAYS,
    FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_SEQUENTIAL_SCAN, NULL
  );
  if (output_file == INVALID_HANDLE_VALUE ||
      !SetFilePointerEx(output_file, output_size, NULL, FILE_BEGIN) ||
      !SetEndOfFile(output_file)) {
    fwprintf(stderr, L"RGBA output allocation failed\n");
    goto cleanup;
  }
  output_mapping = CreateFileMappingW(
    output_file, NULL, PAGE_READWRITE,
    (DWORD)(((uint64_t)output_size.QuadPart) >> 32),
    (DWORD)(((uint64_t)output_size.QuadPart) & 0xffffffffU),
    NULL
  );
  if (!output_mapping) {
    fwprintf(stderr, L"RGBA output mapping failed\n");
    goto cleanup;
  }
  rgba = (unsigned char *)MapViewOfFile(
    output_mapping, FILE_MAP_ALL_ACCESS, 0, 0,
    (SIZE_T)output_size.QuadPart
  );
  if (!rgba) {
    fwprintf(stderr, L"RGBA output view failed\n");
    goto cleanup;
  }

  if (!finish_read(&image, NULL, rgba, 0, NULL)) {
    fprintf(stderr, "libpng finish read failed: %s\n", image.message);
    goto cleanup;
  }
  if (!sha256_visual(
        rgba, (uint64_t)output_size.QuadPart, visual_digest,
        &transparent, &visible
      )) {
    goto cleanup;
  }
  for (index = 0; index < 32; ++index) {
    static const char digits[] = "0123456789abcdef";
    visual_hex[index * 2U] = digits[(visual_digest[index] >> 4) & 0x0f];
    visual_hex[index * 2U + 1U] = digits[visual_digest[index] & 0x0f];
  }
  visual_hex[64] = '\0';
  if (!FlushViewOfFile(rgba, (SIZE_T)output_size.QuadPart) ||
      !FlushFileBuffers(output_file)) {
    fwprintf(stderr, L"RGBA output flush failed\n");
    goto cleanup;
  }

  printf(
    "{\"pixel_width\":%u,\"pixel_height\":%u,"
    "\"row_bytes\":%u,\"alpha_channel_verified\":%s,"
    "\"transparent_pixel_present\":%s,"
    "\"visible_pixel_present\":%s,\"visual_pixel_sha256\":\"%s\"}\n",
    image.width, image.height, image.width * 4U,
    input_bytes[25] == 6U ? "true" : "false",
    transparent ? "true" : "false",
    visible ? "true" : "false",
    visual_hex
  );
  exit_code = 0;

cleanup:
  if (image_started && free_image) free_image(&image);
  if (rgba) UnmapViewOfFile(rgba);
  if (output_mapping) CloseHandle(output_mapping);
  if (output_file != INVALID_HANDLE_VALUE) CloseHandle(output_file);
  if (libpng) FreeLibrary(libpng);
  if (input_bytes) UnmapViewOfFile(input_bytes);
  if (input_mapping) CloseHandle(input_mapping);
  if (input_file != INVALID_HANDLE_VALUE) CloseHandle(input_file);
  if (exit_code != 0 && argc >= 3 && !inspect_only) DeleteFileW(argv[2]);
  return exit_code;
}
