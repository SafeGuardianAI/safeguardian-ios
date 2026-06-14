// gguf.h — minimal self-contained stub. Replaced by fetch_whisper.sh.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>

#define GGML_API

// Minimal forward declarations only — enough for gguf_type_size.
enum ggml_type { GGML_TYPE_F32 = 0 };
struct ggml_tensor;
struct ggml_context;

enum gguf_type {
    GGUF_TYPE_UINT8 = 0, GGUF_TYPE_INT8, GGUF_TYPE_UINT16, GGUF_TYPE_INT16,
    GGUF_TYPE_UINT32, GGUF_TYPE_INT32, GGUF_TYPE_FLOAT32, GGUF_TYPE_BOOL,
    GGUF_TYPE_STRING, GGUF_TYPE_ARRAY, GGUF_TYPE_UINT64, GGUF_TYPE_INT64,
    GGUF_TYPE_FLOAT64, GGUF_TYPE_COUNT,
};
struct gguf_context;
struct gguf_init_params { bool no_alloc; struct ggml_context ** ctx; };

GGML_API size_t gguf_type_size(enum gguf_type type);
GGML_API struct gguf_context * gguf_init_from_file_impl(FILE * file, struct gguf_init_params params);
GGML_API void gguf_free(struct gguf_context * ctx);
GGML_API enum ggml_type gguf_get_tensor_type(const struct gguf_context * ctx, int i);
GGML_API struct ggml_tensor * gguf_get_tensor(const struct gguf_context * ctx, int i);
