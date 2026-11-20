#ifndef OPENCLIPBOARD_BRIDGE_H
#define OPENCLIPBOARD_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    size_t item;
    const char *type;
    const uint8_t *data;
    size_t length;
} OCPart;

typedef struct {
    uint8_t *data;
    size_t length;
    size_t width;
    size_t height;
} OCThumbnail;

void oc_install_delegate(void);
int64_t oc_register_shortcut(uint16_t key, uint8_t modifiers);
void oc_shortcut_fired(uint32_t identifier);

bool oc_start_worker(const char *path);
bool oc_send(const char *request);
bool oc_capture(const OCPart *parts, size_t count, bool detect_sensitive, const char *color);
void oc_event(const char *event);
void oc_payload(uint64_t ticket, int64_t id, bool sensitive, const OCPart *parts, size_t count);
void oc_preview_image(uint64_t ticket, int64_t id, const uint8_t *data, size_t length);
OCThumbnail oc_thumbnail(const uint8_t *data, size_t length);
void oc_free_thumbnail(uint8_t *data);

#endif
