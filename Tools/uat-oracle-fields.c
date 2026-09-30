// usage: build next to a dump978 checkout: gcc -O2 -o uat_fields uat-oracle-fields.c dump978/uat_decode.c dump978/reader.c -lm
//        zcat dump978/sample-data.txt.gz | ./uat_fields > dump978-sample-fields.txt
// Oracle: decodes dump978 text frames with dump978's own uat_decode.c and prints key fields, one line per frame
// (plus one line per FIS-B information frame, and the DLAC text of product 413 in hex so spacing is exact).
#include <stdio.h>
#include <string.h>
#include "dump978/uat.h"
#include "dump978/uat_decode.h"
#include "dump978/reader.h"
#include <assert.h>
// Copied verbatim from dump978/uat_decode.c (static there), so the oracle can print product 413 text.
// The odd two-string-literals here is to avoid \0x3ABCDEF being interpreted as a single (very large valued) character
static const char *dlac_alphabet = "\x03" "ABCDEFGHIJKLMNOPQRSTUVWXYZ\x1A\t\x1E\n| !\"#$%&'()*+,-./0123456789:;<=>?";

static const char *decode_dlac(uint8_t *data, unsigned bytelen)
{
    static char buf[1024];
    uint8_t *end = data + bytelen;
    char *p = buf;
    int step = 0;
    int tab = 0;
    
    while (data < end) {
        int ch;

        assert(step >= 0 && step <= 3);
        switch (step) {
        case 0:
            ch = data[0] >> 2;
            ++data;
            break;
        case 1:
            ch = ((data[-1] & 0x03) << 4) | (data[0] >> 4);
            ++data;
            break;
        case 2:
            ch = ((data[-1] & 0x0f) << 2) | (data[0] >> 6);
            break;
        case 3:
            ch = data[0] & 0x3f;
            ++data;
            break;
        }

        if (tab) {
            while (ch > 0)
                *p++ = ' ', ch--;
            tab = 0;
        } else if (ch == 28) { // tab
            tab = 1;
        } else {
            *p++ = dlac_alphabet[ch];
        }

        step = (step+1)%4;
    }

    *p = 0;
    return buf;
}
    
static void frame(frame_type_t type, uint8_t *f, int len, void *extra) {
    if (type == UAT_DOWNLINK) {
        struct uat_adsb_mdb m;
        uat_decode_adsb_mdb(f, &m);
        printf("D type=%d aq=%d addr=%06X", m.mdb_type, m.address_qualifier, m.address);
        if (m.has_sv) {
            printf(" nic=%d", m.nic);
            if (m.position_valid) printf(" lat=%.6f lon=%.6f", m.lat, m.lon);
            if (m.altitude_type) printf(" alt=%d/%d", m.altitude, m.altitude_type);
            printf(" ag=%d", m.airground_state);
            if (m.ns_vel_valid) printf(" ns=%d", m.ns_vel);
            if (m.ew_vel_valid) printf(" ew=%d", m.ew_vel);
            if (m.track_type) printf(" track=%d/%d", m.track, m.track_type);
            if (m.speed_valid) printf(" speed=%d", m.speed);
            if (m.vert_rate_source) printf(" vr=%d/%d", m.vert_rate, m.vert_rate_source);
            if (m.dimensions_valid) printf(" dim=%.1fx%.1f", m.length, m.width);
            printf(" utc=%d site=%d", m.utc_coupled ? 1 : 0, m.tisb_site_id);
        }
        if (m.has_ms) printf(" cat=%d cs=%d:%s emerg=%d ver=%d sil=%d nacp=%d nacv=%d nicbaro=%d caps=%d%d%d%d%d%d",
            m.emitter_category, m.callsign_type, m.callsign, m.emergency_status, m.uat_version, m.sil, m.nac_p, m.nac_v,
            m.nic_baro, m.has_cdti ? 1 : 0, m.has_acas ? 1 : 0, m.acas_ra_active ? 1 : 0, m.ident_active ? 1 : 0,
            m.atc_services ? 1 : 0, m.heading_type);
        if (m.has_auxsv && m.sec_altitude_type) printf(" alt2=%d/%d", m.sec_altitude, m.sec_altitude_type);
        printf("\n");
    } else {
        static struct uat_uplink_mdb m;
        memset(&m, 0, sizeof m);
        uat_decode_uplink_mdb(f, &m);
        printf("U lat=%.6f lon=%.6f pos=%d utc=%d app=%d slot=%d site=%d frames=%d\n", m.lat, m.lon, m.position_valid ? 1 : 0,
            m.utc_coupled ? 1 : 0, m.app_data_valid ? 1 : 0, m.slot_id, m.tisb_site_id, m.app_data_valid ? m.num_info_frames : 0);
        if (!m.app_data_valid) return;
        for (unsigned i = 0; i < m.num_info_frames; i++) {
            struct uat_uplink_info_frame *fr = &m.info_frames[i];
            printf(" I len=%d type=%d", fr->length, fr->type);
            if (fr->is_fisb) {
                struct fisb_apdu *a = &fr->fisb;
                printf(" product=%d flags=%d%d%d%d time=", a->product_id, a->a_flag ? 1 : 0, a->g_flag ? 1 : 0, a->p_flag ? 1 : 0, a->s_flag ? 1 : 0);
                if (a->monthday_valid) printf("%d/%d-", a->month, a->day);
                printf("%02d:%02d", a->hours, a->minutes);
                if (a->seconds_valid) printf(":%02d", a->seconds);
                printf(" payload=%d", a->length);
                if (a->product_id == 413) {
                    const char *t = decode_dlac(a->data, a->length);
                    printf(" text=");
                    for (const char *c = t; *c; c++) printf("%02x", (unsigned char)*c);
                }
            }
            printf("\n");
        }
    }
}
int main(void) {
    struct dump978_reader *r = dump978_reader_new(0, 0);
    while (dump978_read_frames(r, frame, NULL) > 0) ;
    return 0;
}
