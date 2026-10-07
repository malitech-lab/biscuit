#include "include/BiscuitArchive.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <zlib.h>

/* libarchive's callback types. Declared here because archive.h is absent. */
typedef int biscuit_open_cb(struct archive *, void *);
typedef la_ssize_t biscuit_read_cb(struct archive *, void *, const void **);
typedef int biscuit_close_cb(struct archive *, void *);

extern int archive_read_open(struct archive *, void *,
                             biscuit_open_cb *, biscuit_read_cb *, biscuit_close_cb *);

struct biscuit_pread_source {
    int fd;
    int64_t offset;      /* our own cursor; the descriptor is never seeked */
    size_t capacity;
    unsigned char *buffer;
};

biscuit_pread_source *biscuit_pread_source_new(int fd, size_t block_size) {
    if (block_size == 0) { block_size = 1u << 20; }
    biscuit_pread_source *s = calloc(1, sizeof *s);
    if (!s) { return NULL; }
    s->buffer = malloc(block_size);
    if (!s->buffer) { free(s); return NULL; }
    s->fd = fd;
    s->offset = 0;
    s->capacity = block_size;
    return s;
}

void biscuit_pread_source_free(biscuit_pread_source *s) {
    if (!s) { return; }
    free(s->buffer);
    free(s);
}

static int biscuit_open(struct archive *a, void *client_data) {
    (void)a; (void)client_data;
    return BISCUIT_ARCHIVE_OK;
}

static la_ssize_t biscuit_read(struct archive *a, void *client_data, const void **buffer) {
    (void)a;
    biscuit_pread_source *s = client_data;
    ssize_t n;
    do {
        n = pread(s->fd, s->buffer, s->capacity, (off_t)s->offset);
    } while (n < 0 && errno == EINTR);

    if (n < 0) { return -1; }
    s->offset += n;
    *buffer = s->buffer;
    return n;
}

static int biscuit_close(struct archive *a, void *client_data) {
    (void)a; (void)client_data;
    /* The descriptor belongs to the caller; closing it here would pull it out
       from under code that still needs it. */
    return BISCUIT_ARCHIVE_OK;
}

int biscuit_archive_open_pread(struct archive *a, biscuit_pread_source *source) {
    if (!a || !source) { return BISCUIT_ARCHIVE_FATAL; }
    return archive_read_open(a, source, biscuit_open, biscuit_read, biscuit_close);
}

uint32_t biscuit_crc32(uint32_t crc, const void *data, size_t length) {
    return (uint32_t)crc32(crc, (const Bytef *)data, (uInt)length);
}
