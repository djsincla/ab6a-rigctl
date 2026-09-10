#ifndef SHACK_HAMLIB_SHIM_H
#define SHACK_HAMLIB_SHIM_H
#include <hamlib/rig.h>

/* Hamlib 4.x defines rig_get_freq, RIG_VFO_CURR and friends as function-like
   macros. Swift cannot import those, so expose real functions instead.

   Everything here talks to a running rigctld over TCP via the NETRIGCTL
   backend. Nothing in this app ever opens a serial port: the interface belongs
   to rigctld, and exactly one owner is allowed. */

static inline void shk_quiet(void) { rig_set_debug(RIG_DEBUG_NONE); }

static inline RIG *shk_open(const char *host_port, int *err) {
    RIG *r = rig_init(RIG_MODEL_NETRIGCTL);
    if (!r) { *err = -1; return 0; }
    token_t t = rig_token_lookup(r, "rig_pathname");
    if (t != RIG_CONF_END) rig_set_conf(r, t, host_port);
    *err = rig_open(r);
    return r;
}

static inline int shk_get_freq(RIG *r, double *out) {
    freq_t f = 0;
    int rc = rig_get_freq(r, RIG_VFO_CURR, &f);
    *out = (double)f;
    return rc;
}

static inline int shk_get_mode(RIG *r, char *buf, int len, int *width) {
    rmode_t m = 0; pbwidth_t w = 0;
    int rc = rig_get_mode(r, RIG_VFO_CURR, &m, &w);
    if (rc == RIG_OK) { snprintf(buf, len, "%s", rig_strrmode(m)); *width = (int)w; }
    return rc;
}

static inline void shk_close(RIG *r) { if (r) { rig_close(r); rig_cleanup(r); } }

static inline const char *shk_error(int code) { return rigerror(code); }

#endif
