#include "CLiveKitNativeOpenSSL.h"

#include <openssl/bio.h>
#include <openssl/ec.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/srtp.h>
#include <openssl/x509.h>
#include <limits.h>
#include <string.h>

struct LKNOpenSSLDTLSIdentity {
    EVP_PKEY *private_key;
    X509 *certificate;
};

struct LKNOpenSSLDTLSSession {
    SSL_CTX *context;
    SSL *ssl;
    BIO *read_bio;
    BIO *write_bio;
};

static _Thread_local char lkn_last_error[256];

static void lkn_store_error(void) {
    unsigned long code = ERR_get_error();
    if (code == 0) {
        lkn_last_error[0] = '\0';
        return;
    }
    ERR_error_string_n(code, lkn_last_error, sizeof(lkn_last_error));
}

static int lkn_verify_callback(int ok, X509_STORE_CTX *store) {
    (void)ok;
    (void)store;
    return 1;
}

LKNOpenSSLDTLSIdentity *lkn_dtls_identity_create(void) {
    EVP_PKEY_CTX *key_context = NULL;
    EVP_PKEY *private_key = NULL;
    X509 *certificate = NULL;
    LKNOpenSSLDTLSIdentity *identity = NULL;

    key_context = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
    if (key_context == NULL) {
        goto fail;
    }
    if (EVP_PKEY_keygen_init(key_context) <= 0) {
        goto fail;
    }
    if (EVP_PKEY_CTX_set_ec_paramgen_curve_nid(key_context, NID_X9_62_prime256v1) <= 0) {
        goto fail;
    }
    if (EVP_PKEY_keygen(key_context, &private_key) <= 0) {
        goto fail;
    }

    certificate = X509_new();
    if (certificate == NULL) {
        goto fail;
    }
    if (ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) != 1) {
        goto fail;
    }
    if (X509_gmtime_adj(X509_get_notBefore(certificate), 0) == NULL) {
        goto fail;
    }
    if (X509_gmtime_adj(X509_get_notAfter(certificate), 60 * 60 * 24) == NULL) {
        goto fail;
    }
    if (X509_set_pubkey(certificate, private_key) != 1) {
        goto fail;
    }

    X509_NAME *name = X509_get_subject_name(certificate);
    if (name == NULL) {
        goto fail;
    }
    if (X509_NAME_add_entry_by_txt(
            name,
            "CN",
            MBSTRING_ASC,
            (const unsigned char *)"LiveKitNative",
            -1,
            -1,
            0
        ) != 1) {
        goto fail;
    }
    if (X509_set_issuer_name(certificate, name) != 1) {
        goto fail;
    }
    if (X509_sign(certificate, private_key, EVP_sha256()) <= 0) {
        goto fail;
    }

    identity = OPENSSL_malloc(sizeof(LKNOpenSSLDTLSIdentity));
    if (identity == NULL) {
        goto fail;
    }
    identity->private_key = private_key;
    identity->certificate = certificate;

    EVP_PKEY_CTX_free(key_context);
    return identity;

fail:
    lkn_store_error();
    EVP_PKEY_CTX_free(key_context);
    EVP_PKEY_free(private_key);
    X509_free(certificate);
    OPENSSL_free(identity);
    return NULL;
}

void lkn_dtls_identity_free(LKNOpenSSLDTLSIdentity *identity) {
    if (identity == NULL) {
        return;
    }
    EVP_PKEY_free(identity->private_key);
    X509_free(identity->certificate);
    OPENSSL_free(identity);
}

int lkn_dtls_identity_copy_certificate_der(
    LKNOpenSSLDTLSIdentity *identity,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
) {
    if (identity == NULL || out_length == NULL) {
        return LKN_DTLS_FAILED;
    }

    int length = i2d_X509(identity->certificate, NULL);
    if (length <= 0) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    *out_length = (size_t)length;
    if (buffer == NULL) {
        return LKN_DTLS_OK;
    }
    if (capacity < (size_t)length) {
        return LKN_DTLS_FAILED;
    }

    unsigned char *cursor = buffer;
    if (i2d_X509(identity->certificate, &cursor) != length) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }

    return LKN_DTLS_OK;
}

LKNOpenSSLDTLSSession *lkn_dtls_session_create(
    LKNOpenSSLDTLSIdentity *identity,
    int is_server,
    const char *srtp_profiles
) {
    if (identity == NULL) {
        return NULL;
    }

    LKNOpenSSLDTLSSession *session = OPENSSL_malloc(sizeof(LKNOpenSSLDTLSSession));
    if (session == NULL) {
        return NULL;
    }
    memset(session, 0, sizeof(LKNOpenSSLDTLSSession));

    session->context = SSL_CTX_new(DTLS_method());
    if (session->context == NULL) {
        goto fail;
    }
    if (SSL_CTX_set_min_proto_version(session->context, DTLS1_2_VERSION) != 1 ||
        SSL_CTX_set_max_proto_version(session->context, DTLS1_2_VERSION) != 1) {
        goto fail;
    }
    SSL_CTX_set_verify(
        session->context,
        SSL_VERIFY_PEER | SSL_VERIFY_CLIENT_ONCE,
        lkn_verify_callback
    );
    if (SSL_CTX_use_certificate(session->context, identity->certificate) != 1) {
        goto fail;
    }
    if (SSL_CTX_use_PrivateKey(session->context, identity->private_key) != 1) {
        goto fail;
    }
    if (SSL_CTX_check_private_key(session->context) != 1) {
        goto fail;
    }
    if (SSL_CTX_set_tlsext_use_srtp(session->context, srtp_profiles) != 0) {
        goto fail;
    }

    session->ssl = SSL_new(session->context);
    if (session->ssl == NULL) {
        goto fail;
    }
    session->read_bio = BIO_new(BIO_s_mem());
    session->write_bio = BIO_new(BIO_s_mem());
    if (session->read_bio == NULL || session->write_bio == NULL) {
        goto fail;
    }
    BIO_set_mem_eof_return(session->read_bio, -1);
    BIO_set_mem_eof_return(session->write_bio, -1);
    SSL_set_bio(session->ssl, session->read_bio, session->write_bio);
    SSL_set_mtu(session->ssl, 1200);
    if (is_server) {
        SSL_set_accept_state(session->ssl);
    } else {
        SSL_set_connect_state(session->ssl);
    }

    return session;

fail:
    lkn_store_error();
    lkn_dtls_session_free(session);
    return NULL;
}

void lkn_dtls_session_free(LKNOpenSSLDTLSSession *session) {
    if (session == NULL) {
        return;
    }
    SSL_free(session->ssl);
    SSL_CTX_free(session->context);
    OPENSSL_free(session);
}

int lkn_dtls_session_provide_datagram(
    LKNOpenSSLDTLSSession *session,
    const uint8_t *data,
    size_t length
) {
    if (session == NULL || session->ssl == NULL || data == NULL || length > INT_MAX) {
        return LKN_DTLS_FAILED;
    }
    int written = BIO_write(SSL_get_rbio(session->ssl), data, (int)length);
    if (written != (int)length) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    return LKN_DTLS_OK;
}

int lkn_dtls_session_do_handshake(
    LKNOpenSSLDTLSSession *session,
    int *is_complete
) {
    if (session == NULL || session->ssl == NULL || is_complete == NULL) {
        return LKN_DTLS_FAILED;
    }
    *is_complete = SSL_is_init_finished(session->ssl) == 1;
    if (*is_complete) {
        return LKN_DTLS_OK;
    }

    int result = SSL_do_handshake(session->ssl);
    if (result == 1) {
        *is_complete = 1;
        return LKN_DTLS_OK;
    }

    int ssl_error = SSL_get_error(session->ssl, result);
    if (ssl_error == SSL_ERROR_WANT_READ || ssl_error == SSL_ERROR_WANT_WRITE) {
        *is_complete = 0;
        return LKN_DTLS_WANT_READ;
    }

    lkn_store_error();
    return LKN_DTLS_FAILED;
}

int lkn_dtls_session_copy_outbound(
    LKNOpenSSLDTLSSession *session,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
) {
    if (session == NULL || session->ssl == NULL || out_length == NULL) {
        return LKN_DTLS_FAILED;
    }

    BIO *bio = SSL_get_wbio(session->ssl);
    size_t pending = BIO_ctrl_pending(bio);
    *out_length = pending;
    if (buffer == NULL || pending == 0) {
        return LKN_DTLS_OK;
    }
    if (capacity < pending || pending > INT_MAX) {
        return LKN_DTLS_FAILED;
    }

    int read_count = BIO_read(bio, buffer, (int)pending);
    if (read_count < 0) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    *out_length = (size_t)read_count;
    return LKN_DTLS_OK;
}

int lkn_dtls_session_export_keying_material(
    LKNOpenSSLDTLSSession *session,
    const char *label,
    uint8_t *buffer,
    size_t length
) {
    if (session == NULL || session->ssl == NULL || label == NULL || buffer == NULL) {
        return LKN_DTLS_FAILED;
    }
    if (SSL_export_keying_material(
            session->ssl,
            buffer,
            length,
            label,
            strlen(label),
            NULL,
            0,
            0
        ) != 1) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    return LKN_DTLS_OK;
}

uint16_t lkn_dtls_session_selected_srtp_profile(LKNOpenSSLDTLSSession *session) {
    if (session == NULL || session->ssl == NULL) {
        return 0;
    }
    const SRTP_PROTECTION_PROFILE *profile = SSL_get_selected_srtp_profile(session->ssl);
    if (profile == NULL) {
        return 0;
    }
    return (uint16_t)profile->id;
}

int lkn_dtls_session_copy_peer_certificate_der(
    LKNOpenSSLDTLSSession *session,
    uint8_t *buffer,
    size_t capacity,
    size_t *out_length
) {
    if (session == NULL || session->ssl == NULL || out_length == NULL) {
        return LKN_DTLS_FAILED;
    }

    X509 *certificate = SSL_get1_peer_certificate(session->ssl);
    if (certificate == NULL) {
        return LKN_DTLS_FAILED;
    }
    int length = i2d_X509(certificate, NULL);
    if (length <= 0) {
        X509_free(certificate);
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    *out_length = (size_t)length;
    if (buffer == NULL) {
        X509_free(certificate);
        return LKN_DTLS_OK;
    }
    if (capacity < (size_t)length) {
        X509_free(certificate);
        return LKN_DTLS_FAILED;
    }

    unsigned char *cursor = buffer;
    int encoded = i2d_X509(certificate, &cursor);
    X509_free(certificate);
    if (encoded != length) {
        lkn_store_error();
        return LKN_DTLS_FAILED;
    }
    return LKN_DTLS_OK;
}

unsigned long lkn_dtls_last_error_code(void) {
    return ERR_peek_last_error();
}

const char *lkn_dtls_last_error_string(void) {
    return lkn_last_error;
}
