#ifndef CLIVEKIT_NATIVE_OPENSSL_H
#define CLIVEKIT_NATIVE_OPENSSL_H

#include <stddef.h>
#include <stdint.h>

typedef struct LKNOpenSSLDTLSIdentity LKNOpenSSLDTLSIdentity;
typedef struct LKNOpenSSLDTLSSession LKNOpenSSLDTLSSession;

enum {
    LKN_DTLS_OK = 0,
    LKN_DTLS_WANT_READ = 1,
    LKN_DTLS_FAILED = -1
};

LKNOpenSSLDTLSIdentity *lkn_dtls_identity_create(void);
void lkn_dtls_identity_free(LKNOpenSSLDTLSIdentity *identity);
int lkn_dtls_identity_copy_certificate_der(
    LKNOpenSSLDTLSIdentity *identity,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
);

LKNOpenSSLDTLSSession *lkn_dtls_session_create(
    LKNOpenSSLDTLSIdentity *identity,
    int is_server,
    const char *srtp_profiles
);
void lkn_dtls_session_free(LKNOpenSSLDTLSSession *session);
int lkn_dtls_session_provide_datagram(
    LKNOpenSSLDTLSSession *session,
    const uint8_t *data,
    size_t length
);
int lkn_dtls_session_do_handshake(
    LKNOpenSSLDTLSSession *session,
    int *is_complete
);
int lkn_dtls_session_copy_outbound(
    LKNOpenSSLDTLSSession *session,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
);
int lkn_dtls_session_write_application_data(
    LKNOpenSSLDTLSSession *session,
    const uint8_t *data,
    size_t length
);
int lkn_dtls_session_read_application_data(
    LKNOpenSSLDTLSSession *session,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
);
int lkn_dtls_session_export_keying_material(
    LKNOpenSSLDTLSSession *session,
    const char *label,
    uint8_t *buffer,
    size_t length
);
uint16_t lkn_dtls_session_selected_srtp_profile(LKNOpenSSLDTLSSession *session);
int lkn_dtls_session_copy_peer_certificate_der(
    LKNOpenSSLDTLSSession *session,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
);
unsigned long lkn_dtls_last_error_code(void);
const char *lkn_dtls_last_error_string(void);

#endif
