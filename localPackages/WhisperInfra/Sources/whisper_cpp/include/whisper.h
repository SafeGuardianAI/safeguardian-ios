// whisper.h — minimal self-contained stub declarations for WhisperInfra.
// fetch_whisper.sh replaces this with the real whisper.cpp header.
// Stub mode: all functions compile; init returns NULL; inference is a no-op.

#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#define WHISPER_API
#define WHISPER_SAMPLE_RATE 16000

struct whisper_context;
struct whisper_state;

typedef int32_t whisper_token;
typedef int32_t whisper_pos;

enum whisper_sampling_strategy {
    WHISPER_SAMPLING_GREEDY      = 0,
    WHISPER_SAMPLING_BEAM_SEARCH = 1,
};

typedef void (*whisper_new_segment_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef void (*whisper_progress_callback)(struct whisper_context *, struct whisper_state *, int, void *);
typedef bool (*whisper_encoder_begin_callback)(struct whisper_context *, struct whisper_state *, void *);

struct whisper_context_params {
    bool use_gpu;
    bool flash_attn;
    int  gpu_device;
    bool dtw_token_timestamps;
    int  dtw_n_top;
};

struct whisper_full_params {
    enum whisper_sampling_strategy strategy;
    int   n_threads;
    int   offset_ms;
    int   duration_ms;
    bool  translate;
    bool  no_context;
    bool  single_segment;
    bool  print_special;
    bool  print_progress;
    bool  print_realtime;
    bool  print_timestamps;
    const char * language;
    bool  detect_language;
    bool  suppress_blank;
    float temperature;
    float no_speech_thold;
    struct { int best_of; } greedy;
    struct { int beam_size; float patience; } beam_search;
    whisper_new_segment_callback   new_segment_callback;
    void *                         new_segment_callback_user_data;
    whisper_progress_callback      progress_callback;
    void *                         progress_callback_user_data;
    whisper_encoder_begin_callback encoder_begin_callback;
    void *                         encoder_begin_callback_user_data;
};

struct whisper_model_loader {
    void * context;
    size_t (*read)(void * ctx, void * output, size_t read_size);
    bool   (*eof)(void * ctx);
    void   (*close)(void * ctx);
};

WHISPER_API struct whisper_context_params whisper_context_default_params(void);
WHISPER_API struct whisper_context * whisper_init_from_file_with_params(const char * path_model, struct whisper_context_params params);
WHISPER_API struct whisper_context * whisper_init_from_buffer_with_params(void * buffer, size_t buffer_size, struct whisper_context_params params);
WHISPER_API struct whisper_context * whisper_init_from_file_with_params_no_state(const char * path_model, struct whisper_context_params params);

WHISPER_API void whisper_free(struct whisper_context * ctx);

WHISPER_API struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy);
WHISPER_API int  whisper_full(struct whisper_context * ctx, struct whisper_full_params params, const float * samples, int n_samples);
WHISPER_API int  whisper_full_n_segments(struct whisper_context * ctx);
WHISPER_API const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i_segment);
WHISPER_API int64_t      whisper_full_get_segment_t0(struct whisper_context * ctx, int i_segment);
WHISPER_API int64_t      whisper_full_get_segment_t1(struct whisper_context * ctx, int i_segment);

// Deprecated — kept so WhisperContext.swift compiles against either header
WHISPER_API struct whisper_context * whisper_init_from_file(const char * path_model);
