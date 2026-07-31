#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <stdint.h>
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

static int sha256_visual(
  const unsigned char *rgba,
  uint64_t byte_size,
  unsigned char digest[32],
  int *transparent,
  int *visible
) {
  BCRYPT_ALG_HANDLE algorithm = NULL;
  BCRYPT_HASH_HANDLE hash = NULL;
  unsigned char *hash_object = NULL;
  unsigned char *canonical = NULL;
  DWORD object_size = 0;
  DWORD hash_size = 0;
  DWORD received = 0;
  NTSTATUS status;
  uint64_t offset = 0;
  int ok = 0;

  *transparent = 0;
  *visible = 0;
  status = BCryptOpenAlgorithmProvider(
    &algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0
  );
  if (status < 0) goto cleanup;
  status = BCryptGetProperty(
    algorithm, BCRYPT_OBJECT_LENGTH, (PUCHAR)&object_size,
    sizeof(object_size), &received, 0
  );
  if (status < 0 || object_size == 0) goto cleanup;
  status = BCryptGetProperty(
    algorithm, BCRYPT_HASH_LENGTH, (PUCHAR)&hash_size,
    sizeof(hash_size), &received, 0
  );
  if (status < 0 || hash_size != 32) goto cleanup;

  hash_object = (unsigned char *)HeapAlloc(
    GetProcessHeap(), 0, object_size
  );
  canonical = (unsigned char *)HeapAlloc(
    GetProcessHeap(), 0, CANONICAL_CHUNK_BYTES
  );
  if (!hash_object || !canonical) goto cleanup;
  status = BCryptCreateHash(
    algorithm, &hash, hash_object, object_size, NULL, 0, 0
  );
  if (status < 0) goto cleanup;

  while (offset < byte_size) {
    ULONG chunk = (ULONG)(
      byte_size - offset > CANONICAL_CHUNK_BYTES ?
        CANONICAL_CHUNK_BYTES : byte_size - offset
    );
    ULONG index;
    chunk -= chunk % 4U;
    if (chunk == 0) goto cleanup;
    for (index = 0; index < chunk; index += 4U) {
      unsigned int alpha = rgba[offset + index + 3U];
      canonical[index] = (unsigned char)(
        ((unsigned int)rgba[offset + index] * alpha + 127U) / 255U
      );
      canonical[index + 1U] = (unsigned char)(
        ((unsigned int)rgba[offset + index + 1U] * alpha + 127U) / 255U
      );
      canonical[index + 2U] = (unsigned char)(
        ((unsigned int)rgba[offset + index + 2U] * alpha + 127U) / 255U
      );
      canonical[index + 3U] = (unsigned char)alpha;
      if (alpha < 255U) *transparent = 1;
      if (alpha > 0U) *visible = 1;
    }
    status = BCryptHashData(hash, canonical, chunk, 0);
    if (status < 0) goto cleanup;
    offset += chunk;
  }
  status = BCryptFinishHash(hash, digest, 32, 0);
  if (status < 0) goto cleanup;
  ok = 1;

cleanup:
  if (hash) BCryptDestroyHash(hash);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  if (canonical) HeapFree(GetProcessHeap(), 0, canonical);
  if (hash_object) HeapFree(GetProcessHeap(), 0, hash_object);
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
  unsigned int index;

  memset(&image, 0, sizeof(image));
  if (argc != 3 && argc != 4) {
    fwprintf(
      stderr,
      L"usage: png_rgba_decoder.exe input.png output.rgba [--allow-rgb]\n"
    );
    return 2;
  }
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
    "\"row_bytes\":%u,\"transparent_pixel_present\":%s,"
    "\"visible_pixel_present\":%s,\"visual_pixel_sha256\":\"%s\"}\n",
    image.width, image.height, image.width * 4U,
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
  if (exit_code != 0 && argc >= 3) DeleteFileW(argv[2]);
  return exit_code;
}
