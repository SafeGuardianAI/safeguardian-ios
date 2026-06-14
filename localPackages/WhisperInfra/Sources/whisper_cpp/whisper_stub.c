// whisper_stub.c — no-op stubs. fetch_whisper.sh removes this when real sources arrive.
// Completely standalone: no ggml headers needed.

#include "include/whisper.h"
#include <stdlib.h>
#include <string.h>

struct whisper_context_params whisper_context_default_params(void) {
    struct whisper_context_params p;
    memset(&p, 0, sizeof(p));
    p.use_gpu    = true;
    p.flash_attn = false;
    p.gpu_device = 0;
    return p;
}

struct whisper_context * whisper_init_from_file_with_params(
    const char * path_model, struct whisper_context_params params)
{ (void)path_model; (void)params; return NULL; }

struct whisper_context * whisper_init_from_buffer_with_params(
    void * buffer, size_t buffer_size, struct whisper_context_params params)
{ (void)buffer; (void)buffer_size; (void)params; return NULL; }

struct whisper_context * whisper_init_from_file_with_params_no_state(
    const char * path_model, struct whisper_context_params params)
{ (void)path_model; (void)params; return NULL; }

struct whisper_context * whisper_init_from_file(const char * path_model)
{ return whisper_init_from_file_with_params(path_model, whisper_context_default_params()); }

void whisper_free(struct whisper_context * ctx) { (void)ctx; }

struct whisper_full_params whisper_full_default_params(enum whisper_sampling_strategy strategy) {
    struct whisper_full_params p;
    memset(&p, 0, sizeof(p));
    p.strategy       = strategy;
    p.n_threads      = 4;
    p.language       = "en";
    p.no_context     = true;
    p.suppress_blank = true;
    p.temperature    = 0.0f;
    p.no_speech_thold= 0.6f;
    p.greedy.best_of = 1;
    return p;
}

int whisper_full(struct whisper_context * ctx, struct whisper_full_params params,
                 const float * samples, int n_samples)
{ (void)ctx; (void)params; (void)samples; (void)n_samples; return -1; }

int          whisper_full_n_segments(struct whisper_context * ctx)             { (void)ctx; return 0; }
const char * whisper_full_get_segment_text(struct whisper_context * ctx, int i){ (void)ctx; (void)i; return NULL; }
int64_t      whisper_full_get_segment_t0(struct whisper_context * ctx, int i)  { (void)ctx; (void)i; return 0; }
int64_t      whisper_full_get_segment_t1(struct whisper_context * ctx, int i)  { (void)ctx; (void)i; return 0; }
