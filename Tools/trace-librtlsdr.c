// Logs libusb control transfers in the same format as RTLSDRKit's TracingTransport. Loaded via DYLD_INSERT_LIBRARIES.
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#define DYLD_INTERPOSE(_replacement,_replacee) \
  __attribute__((used)) static struct { const void* replacement; const void* replacee; } _interpose_##_replacee \
  __attribute__((section("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static FILE *out(void) { static FILE *f; if (!f) { const char *p = getenv("TRACE_OUT"); f = p ? fopen(p, "w") : stderr; } return f; }

static int my_control_transfer(libusb_device_handle *h, uint8_t rt, uint8_t req, uint16_t value, uint16_t index,
                               unsigned char *data, uint16_t len, unsigned int timeout) {
  int isRead = (rt & 0x80) != 0;
  if (!isRead) {
    fprintf(out(), "W 0x%04x 0x%04x", value, index);
    for (int i = 0; i < len; i++) fprintf(out(), "%s%02x", i ? " " : " ", data[i]);
    fprintf(out(), "\n");
  }
  int r = libusb_control_transfer(h, rt, req, value, index, data, len, timeout);
  if (isRead) {
    fprintf(out(), "R 0x%04x 0x%04x %d -> ", value, index, len);
    for (int i = 0; i < (r > 0 ? r : 0); i++) fprintf(out(), "%s%02x", i ? " " : "", data[i]);
    fprintf(out(), "\n");
  }
  fflush(out());
  return r;
}
DYLD_INTERPOSE(my_control_transfer, libusb_control_transfer)
