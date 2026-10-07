/*
 * Minimal declarations for the libarchive that ships with macOS, plus a
 * pread-based source so Biscuit never disturbs the caller's file offset.
 *
 * `archive.h` is not part of the Command Line Tools SDK, but the library lives
 * in the dyld shared cache and links fine. It reports itself as
 * "libarchive 3.7.4 zlib/1.2.12 liblzma/5.4.3 bz2lib/1.0.8".
 *
 * Declaring the API by hand is safe here precisely because every libarchive
 * type is an opaque pointer: there is no struct layout that could drift between
 * versions. The same trick would be reckless with, say, `lzma_stream`, whose
 * fields are part of the ABI.
 *
 * Note which filters are *built in*: gzip, xz and bzip2 are. zstd is not —
 * libarchive shells out to a `zstd` program for it, which the privileged
 * helper's deliberately minimal PATH does not contain. Biscuit therefore
 * refuses .zst rather than depending on whatever happens to be installed.
 */

#ifndef BISCUIT_ARCHIVE_H
#define BISCUIT_ARCHIVE_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef ssize_t la_ssize_t;

struct archive;
struct archive_entry;

#define BISCUIT_ARCHIVE_EOF     1
#define BISCUIT_ARCHIVE_OK      0
#define BISCUIT_ARCHIVE_RETRY (-10)
#define BISCUIT_ARCHIVE_WARN  (-20)
#define BISCUIT_ARCHIVE_FAILED (-25)
#define BISCUIT_ARCHIVE_FATAL (-30)

struct archive *archive_read_new(void);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_xz(struct archive *);
int archive_read_support_filter_bzip2(struct archive *);
int archive_read_support_filter_none(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_support_format_zip(struct archive *);

int archive_read_next_header(struct archive *, struct archive_entry **);
la_ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_free(struct archive *);

const char *archive_filter_name(struct archive *, int);
int64_t archive_filter_bytes(struct archive *, int);
const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);

/*
 * A source that reads with pread(2).
 *
 * Neither dup(2) nor opening /dev/fd/N gives an independent file offset on
 * macOS — both share the underlying open file description, so seeking in the
 * copy moves the original too. That was measured, not assumed. Since the image
 * descriptor arrives from the app over SCM_RIGHTS and the caller still needs it
 * afterwards (for verification, among other things), the only correct answer is
 * to never seek it at all and track the offset ourselves.
 */
typedef struct biscuit_pread_source biscuit_pread_source;

biscuit_pread_source *biscuit_pread_source_new(int fd, size_t block_size);
void biscuit_pread_source_free(biscuit_pread_source *);

/* Attaches the source to `a`. On success libarchive owns the read loop; the
   source must outlive the archive handle. Returns a BISCUIT_ARCHIVE_* code. */
int biscuit_archive_open_pread(struct archive *a, biscuit_pread_source *source);

/* CRC-32 as used by gzip, from the system zlib. Hardware-accelerated, which
   matters for a 9 GB image. */
uint32_t biscuit_crc32(uint32_t crc, const void *data, size_t length);

#endif /* BISCUIT_ARCHIVE_H */
