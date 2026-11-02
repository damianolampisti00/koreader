/*
 * libkotts: text-to-speech for KOReader on BlackBerry 10, through the system's private TTS
 * engine (libttsengine.so.1 → Nuance Vocalizer Expressive, the voices of BB10's screen reader
 * and Assistant). There's no public API: the prototypes were reverse-engineered from
 * libasr-nuance_tts-prompt.so, the system's "prompt" service.
 *
 * ttsStartText2Speech blocks until the text is spoken, so a worker thread speaks a queue of
 * utterances. The Lua side (plugins/readaloud.koplugin) enqueues them, and polls for their
 * start/end events: no Lua ever runs on the worker thread.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Passed as-is to Nuance's ve_ttsSetParamList (VE_PARAM). */
typedef struct {
    int id;
    union {
        uint16_t u;
        char s[128];
    } v;
} tts_param_t;

/* Parameter ids, found by synthesizing to files. */
enum { TTS_VOLUME = 2, TTS_RATE = 3, TTS_PITCH = 4, TTS_VOICE = 8 };

enum { KOTTS_STARTED = 1, KOTTS_DONE = 2, KOTTS_FAILED = 3, KOTTS_CANCELED = 4 };

typedef struct {
    int id;
    int what;
} kotts_event_t;

struct item {
    int id;
    uint16_t *text;
    size_t bytes;
    struct item *next;
};

static int (*ttsInitialize)(const char *);
static int (*ttsOpenInstance)(tts_param_t *, int);
static int (*ttsSetParams)(tts_param_t *, int);
static int (*ttsStartText2Speech)(const uint16_t *, size_t, const char *, int, int);
static int (*ttsStopText2Speech)(void);
static int (*ttsUnInitialize)(void);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t wake = PTHREAD_COND_INITIALIZER;
static pthread_t worker;
static void *engine;
static int running;
static struct item *head, *tail;
static int speaking = -1;              /* id being spoken, or -1 */
static tts_param_t pending[4];         /* parameter changes, applied between utterances */
static int npending;
#define MAX_EVENTS 64
static kotts_event_t events[MAX_EVENTS];
static int nevents;

static void push_event(int id, int what)
{
    if (nevents < MAX_EVENTS) {
        events[nevents].id = id;
        events[nevents].what = what;
        nevents++;
    }
}

static uint16_t *utf8_to_utf16(const char *in, size_t *bytes)
{
    const unsigned char *p = (const unsigned char *)in;
    uint16_t *out = malloc((strlen(in) + 1) * 2 * sizeof *out), *o = out;
    if (!out)
        return NULL;
    while (*p) {
        uint32_t c = *p++;
        if (c >= 0xC0 && c < 0xE0 && (p[0] & 0xC0) == 0x80) {
            c = ((c & 0x1F) << 6) | (p[0] & 0x3F);
            p += 1;
        } else if (c >= 0xE0 && c < 0xF0 && (p[0] & 0xC0) == 0x80 && (p[1] & 0xC0) == 0x80) {
            c = ((c & 0x0F) << 12) | ((p[0] & 0x3F) << 6) | (p[1] & 0x3F);
            p += 2;
        } else if (c >= 0xF0 && c < 0xF8 && (p[0] & 0xC0) == 0x80 && (p[1] & 0xC0) == 0x80 && (p[2] & 0xC0) == 0x80) {
            c = ((c & 0x07) << 18) | ((p[0] & 0x3F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
            p += 3;
        } else if (c >= 0x80) {
            c = 0xFFFD;
        }
        if (c >= 0x10000) {
            c -= 0x10000;
            *o++ = (uint16_t)(0xD800 | (c >> 10));
            *o++ = (uint16_t)(0xDC00 | (c & 0x3FF));
        } else {
            *o++ = (uint16_t)c;
        }
    }
    *o = 0;
    *bytes = (size_t)(o - out) * 2;
    return out;
}

static void *work(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&lock);
    while (running) {
        if (npending) {
            tts_param_t p[4];
            int n = npending;
            memcpy(p, pending, sizeof p);
            npending = 0;
            pthread_mutex_unlock(&lock);
            ttsSetParams(p, n);
            pthread_mutex_lock(&lock);
            continue;
        }
        if (!head) {
            pthread_cond_wait(&wake, &lock);
            continue;
        }
        struct item *it = head;
        head = it->next;
        if (!head)
            tail = NULL;
        speaking = it->id;
        push_event(it->id, KOTTS_STARTED);
        pthread_mutex_unlock(&lock);

        int ret = ttsStartText2Speech(it->text, it->bytes, NULL, 0, 0);

        pthread_mutex_lock(&lock);
        /* kotts_stop() sets speaking to -1 when it interrupts us. */
        push_event(it->id, speaking == -1 ? KOTTS_CANCELED : ret == 0 ? KOTTS_DONE : KOTTS_FAILED);
        speaking = -1;
        free(it->text);
        free(it);
    }
    pthread_mutex_unlock(&lock);
    return NULL;
}

static void set_param(tts_param_t *p, int id, int value)
{
    memset(p, 0, sizeof *p);
    p->id = id;
    p->v.u = (uint16_t)value;
}

/* data: the voices' directory (NULL: /usr/tts/nuance/ve/data). voice: e.g. "alice".
 * rate (50–400), pitch (50–200), volume (0–100): percents, 100 = default.
 * Returns 0, or a negative error (-1: no engine, -2: init, -3: voice, -4: thread). */
int kotts_init(const char *data, const char *voice, int rate, int pitch, int volume)
{
    if (running)
        return 0;
    if (!engine) {
        engine = dlopen("libttsengine.so.1", RTLD_NOW | RTLD_LOCAL);
        if (!engine)
            return -1;
        ttsInitialize = (int (*)(const char *))dlsym(engine, "ttsInitialize");
        ttsOpenInstance = (int (*)(tts_param_t *, int))dlsym(engine, "ttsOpenInstance");
        ttsSetParams = (int (*)(tts_param_t *, int))dlsym(engine, "ttsSetParams");
        ttsStartText2Speech = (int (*)(const uint16_t *, size_t, const char *, int, int))dlsym(engine, "ttsStartText2Speech");
        ttsStopText2Speech = (int (*)(void))dlsym(engine, "ttsStopText2Speech");
        ttsUnInitialize = (int (*)(void))dlsym(engine, "ttsUnInitialize");
        if (!ttsInitialize || !ttsOpenInstance || !ttsSetParams || !ttsStartText2Speech
                || !ttsStopText2Speech || !ttsUnInitialize) {
            dlclose(engine);
            engine = NULL;
            return -1;
        }
    }
    if (ttsInitialize(data ? data : "/usr/tts/nuance/ve/data") != 0)
        return -2;
    tts_param_t p[4];
    memset(p, 0, sizeof p);
    p[0].id = TTS_VOICE;
    strncpy(p[0].v.s, voice && *voice ? voice : "alice", sizeof p[0].v.s - 1);
    set_param(&p[1], TTS_RATE, rate);
    set_param(&p[2], TTS_PITCH, pitch);
    set_param(&p[3], TTS_VOLUME, volume);
    if (ttsOpenInstance(p, 4) != 0) {
        ttsUnInitialize();
        return -3;
    }
    running = 1;
    nevents = 0;
    if (pthread_create(&worker, NULL, work, NULL) != 0) {
        running = 0;
        ttsUnInitialize();
        return -4;
    }
    return 0;
}

static int pending_index(int id)
{
    for (int i = 0; i < npending; i++)
        if (pending[i].id == id)
            return i;
    return npending++;
}

/* Change the rate/pitch/volume (percents, 0 = unchanged), from the next utterance. */
void kotts_set_params(int rate, int pitch, int volume)
{
    pthread_mutex_lock(&lock);
    if (rate)
        set_param(&pending[pending_index(TTS_RATE)], TTS_RATE, rate);
    if (pitch)
        set_param(&pending[pending_index(TTS_PITCH)], TTS_PITCH, pitch);
    if (volume)
        set_param(&pending[pending_index(TTS_VOLUME)], TTS_VOLUME, volume);
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
}

/* Change the voice (e.g. "ava": its data must be mounted), from the next utterance. */
void kotts_set_voice(const char *voice)
{
    pthread_mutex_lock(&lock);
    tts_param_t *p = &pending[pending_index(TTS_VOICE)];
    memset(p, 0, sizeof *p);
    p->id = TTS_VOICE;
    strncpy(p->v.s, voice, sizeof p->v.s - 1);
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
}

/* Queue an utterance (UTF-8). Returns 0, or -1. */
int kotts_speak(int id, const char *text)
{
    struct item *it = calloc(1, sizeof *it);
    if (!it)
        return -1;
    it->id = id;
    it->text = utf8_to_utf16(text, &it->bytes);
    if (!it->text) {
        free(it);
        return -1;
    }
    pthread_mutex_lock(&lock);
    if (!running) {
        pthread_mutex_unlock(&lock);
        free(it->text);
        free(it);
        return -1;
    }
    if (tail)
        tail->next = it;
    else
        head = it;
    tail = it;
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
    return 0;
}

/* Drop the queue and interrupt the current utterance (its event is KOTTS_CANCELED). */
void kotts_stop(void)
{
    pthread_mutex_lock(&lock);
    while (head) {
        struct item *it = head;
        head = it->next;
        push_event(it->id, KOTTS_CANCELED);
        free(it->text);
        free(it);
    }
    tail = NULL;
    int interrupt = speaking != -1;
    speaking = -1;
    pthread_mutex_unlock(&lock);
    if (interrupt)
        ttsStopText2Speech();
}

/* Events since the last call (up to max), oldest first. Returns their number. */
int kotts_poll(kotts_event_t *out, int max)
{
    pthread_mutex_lock(&lock);
    int n = nevents < max ? nevents : max;
    memcpy(out, events, n * sizeof *out);
    memmove(events, events + n, (nevents - n) * sizeof *events);
    nevents -= n;
    pthread_mutex_unlock(&lock);
    return n;
}

/* Whether something is being spoken or queued. */
int kotts_busy(void)
{
    pthread_mutex_lock(&lock);
    int busy = speaking != -1 || head != NULL;
    pthread_mutex_unlock(&lock);
    return busy;
}

void kotts_shutdown(void)
{
    if (!running)
        return;
    kotts_stop();
    pthread_mutex_lock(&lock);
    running = 0;
    pthread_cond_signal(&wake);
    pthread_mutex_unlock(&lock);
    pthread_join(worker, NULL);
    ttsUnInitialize();
}
