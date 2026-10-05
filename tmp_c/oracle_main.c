/* brotli.cr C oracle: decode a .br file with the reference decoder.
 *
 * Usage:   brotli_oracle <input.br> [output]
 *          (no output arg -> stdout)
 * Exit:    0 success, 1 decode error (error code on stderr), 2 truncated
 * stderr:  "ERROR code=<N> " on failure, "OK <bytes>" on success.
 */

#include <stdio.h>
#include <stdlib.h>
#include <brotli/decode.h>

#define CHUNK (1 << 16)

static unsigned char *read_file(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(3); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *buf = malloc(n ? n : 1);
  if (n && fread(buf, 1, n, f) != (size_t)n) { perror("fread"); exit(3); }
  fclose(f);
  *size = n;
  return buf;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s <input.br> [output]\n", argv[0]); return 3; }

  size_t in_size;
  unsigned char *in = read_file(argv[1], &in_size);

  BrotliDecoderState *s = BrotliDecoderCreateInstance(NULL, NULL, NULL);
  const unsigned char *next_in = in;
  size_t avail_in = in_size;
  unsigned char *outbuf = malloc(CHUNK);
  FILE *out = (argc > 2) ? fopen(argv[2], "wb") : stdout;

  for (;;) {
    unsigned char *next_out = outbuf;
    size_t avail_out = CHUNK;
    BrotliDecoderResult r = BrotliDecoderDecompressStream(
        s, &avail_in, &next_in, &avail_out, &next_out, NULL);
    fwrite(outbuf, 1, CHUNK - avail_out, out);
    if (r == BROTLI_DECODER_RESULT_SUCCESS) {
      fprintf(stderr, "OK %zu\n", (size_t)(next_out - outbuf));
      break;
    }
    if (r == BROTLI_DECODER_RESULT_ERROR) {
      fprintf(stderr, "ERROR code=%d\n", (int)BrotliDecoderGetErrorCode(s));
      fclose(out);
      return 1;
    }
    if (r == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT) {
      fprintf(stderr, "TRUNCATED\n");
      fclose(out);
      return 2;
    }
  }

  fflush(out);
  if (out != stdout) fclose(out);
  BrotliDecoderDestroyInstance(s);
  return 0;
}
