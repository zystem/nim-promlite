#ifndef DARKHTTPD_H
#define DARKHTTPD_H

#include <stddef.h>

struct darkhttpd_memory_response {
    int status;
    const char *content_type;
    const char *content_encoding;
    /* The body pointer is not copied or freed by darkhttpd. It must remain
     * valid until the response has been sent.
     */
    const void *body;
    size_t body_length;
};

typedef int (*darkhttpd_memory_handler)(
    void *user_data,
    const char *method,
    const char *url,
    struct darkhttpd_memory_response *response);

void darkhttpd_set_memory_handler(
    darkhttpd_memory_handler handler,
    void *user_data);

#endif
