/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * mb-tray - a minimal StatusNotifierItem + DBusMenu tray for the MaliBridge
 * memory budget. It talks to the same mbctl control socket as the shell plugin.
 *
 *  - C11 + glib/gio only (no GTK, no appindicator): one small process, one 5 s
 *    timer, at most one child process per poll.
 *  - The icon is a themed name ("mb-budget"); no pixel data travels over D-Bus.
 *  - The Noctalia plugin writes a heartbeat file while its widget is on screen.
 *    mb-tray waits 8 s and only registers with org.kde.StatusNotifierWatcher
 *    when that heartbeat is stale; it drops the item again when the plugin
 *    comes back, so the two never both show an icon.
 *  - Status comes from `mbctl status --json`; when that fails, the last "mem:"
 *    line of the server log is used. The report is never parsed.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* i18n：跟随系统语言（LC_ALL/LC_MESSAGES/LANG 含 zh 时用中文，否则英文）。 */
static gboolean mb_use_zh(void)
{
    static int cached = -1;
    if (cached < 0) {
        const char *v = getenv("LC_ALL");
        if (!v || !*v) v = getenv("LC_MESSAGES");
        if (!v || !*v) v = getenv("LANG");
        cached = (v && strstr(v, "zh")) ? 1 : 0;
    }
    return cached == 1;
}

static const char *mb_tr(const char *en, const char *zh)
{
    return mb_use_zh() ? zh : en;
}

#define SNI_IFACE "org.kde.StatusNotifierItem"
#define SNI_PATH "/StatusNotifierItem"
#define SNI_SERVICE "org.kde.StatusNotifierItem.mb-tray"
#define MENU_IFACE "com.canonical.dbusmenu"
#define MENU_PATH "/MenuBar"
#define WATCHER_NAME "org.kde.StatusNotifierWatcher"
#define WATCHER_PATH "/StatusNotifierWatcher"
#define WATCHER_IFACE "org.kde.StatusNotifierWatcher"

enum {
    ID_HEAD = 100,
    ID_SYS = 101,
    ID_PENDING = 102,
    ID_WARN = 103,
    ID_TOTAL = 110,
    ID_TOTAL_FIRST = 111, /* 111..115 */
    ID_PID = 120,
    ID_PID_FIRST = 121, /* 121..124 */
    ID_FLOOR = 130,
    ID_FLOOR_FIRST = 131, /* 131..134 */
    ID_APPLY = 140,
    ID_APPLY_NEXT = 141,
    ID_REPORT = 150,
    ID_LOG = 151,
    ID_QUIT = 160,
    ID_SEP1 = 170,
    ID_SEP2 = 171
};

static const gint64 TOTALS[] = {2048, 3072, 4096, 6144, 8192};
static const gint64 PIDS[] = {1024, 2048, 3072, 4096};
static const gint64 FLOORS[] = {1536, 2048, 2560, 3072};
#define N_TOTALS ((int)G_N_ELEMENTS(TOTALS))
#define N_PIDS ((int)G_N_ELEMENTS(PIDS))
#define N_FLOORS ((int)G_N_ELEMENTS(FLOORS))

typedef struct {
    const char *mbctl;
    const char *socket;
    const char *heartbeat;
    const char *report;
    const char *log;
    int start_delay_ms;
    int heartbeat_max_ms;
    int poll_ms;
    gboolean status_once;
    gboolean print_menu;
    gboolean no_register;
    gboolean verbose;
} options_t;

typedef struct {
    gint64 total_mb, pid_mb, floor_mb, map_limit;
    gint64 used_bytes, clients, max_client_bytes;
    gint64 avail_kb, maps, rss_kb;
    char pids[192];
    gboolean valid;
    gboolean from_log;
} status_t;

static options_t opt = {
    .mbctl = NULL,
    .socket = NULL,
    .heartbeat = "/run/user/1000/mb-budget-ui.plugin",
    .report = "/opt/mb-sock/malibridge-report.md",
    .log = "/opt/mb-sock/server.log",
    .start_delay_ms = 8000,
    .heartbeat_max_ms = 15000,
    .poll_ms = 5000,
    .status_once = FALSE,
    .print_menu = FALSE,
    .no_register = FALSE,
    .verbose = FALSE,
};

static status_t st;
static gboolean sel_init;
static gint64 sel_total_mb, sel_pid_mb, sel_floor_mb;

static GMainLoop *loop;
static GDBusConnection *bus;
static GDBusConnection *item_conn;
static guint sni_reg, menu_reg;
static gboolean registered;
static gboolean watcher_present;
static gboolean armed;
static guint poll_timer, start_timer;
static gint64 next_register_ms;
static guint32 menu_rev = 1;

static const GDBusInterfaceVTable mb_sni_vtable;
static const GDBusInterfaceVTable mb_menu_vtable;

static const char *sni_xml =
    "<node>"
    "  <interface name='org.kde.StatusNotifierItem'>"
    "    <property name='Category' type='s' access='read'/>"
    "    <property name='Id' type='s' access='read'/>"
    "    <property name='Title' type='s' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <property name='WindowId' type='i' access='read'/>"
    "    <property name='IconName' type='s' access='read'/>"
    "    <property name='IconPixmap' type='a(iiay)' access='read'/>"
    "    <property name='OverlayIconName' type='s' access='read'/>"
    "    <property name='OverlayIconPixmap' type='a(iiay)' access='read'/>"
    "    <property name='AttentionIconName' type='s' access='read'/>"
    "    <property name='AttentionIconPixmap' type='a(iiay)' access='read'/>"
    "    <property name='AttentionMovieName' type='s' access='read'/>"
    "    <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>"
    "    <property name='ItemIsMenu' type='b' access='read'/>"
    "    <property name='Menu' type='o' access='read'/>"
    "    <method name='ContextMenu'>"
    "      <arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/>"
    "    </method>"
    "    <method name='Activate'>"
    "      <arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/>"
    "    </method>"
    "    <method name='SecondaryActivate'>"
    "      <arg name='x' type='i' direction='in'/><arg name='y' type='i' direction='in'/>"
    "    </method>"
    "    <method name='Scroll'>"
    "      <arg name='delta' type='i' direction='in'/><arg name='orientation' type='s' direction='in'/>"
    "    </method>"
    "    <signal name='NewTitle'/>"
    "    <signal name='NewIcon'/>"
    "    <signal name='NewAttentionIcon'/>"
    "    <signal name='NewOverlayIcon'/>"
    "    <signal name='NewToolTip'/>"
    "    <signal name='NewStatus'><arg name='status' type='s'/></signal>"
    "    <signal name='NewMenu'/>"
    "  </interface>"
    "</node>";

static const char *menu_xml =
    "<node>"
    "  <interface name='com.canonical.dbusmenu'>"
    "    <property name='Version' type='u' access='read'/>"
    "    <property name='TextDirection' type='s' access='read'/>"
    "    <property name='Status' type='s' access='read'/>"
    "    <property name='IconThemePath' type='as' access='read'/>"
    "    <method name='GetLayout'>"
    "      <arg name='parentId' type='i' direction='in'/>"
    "      <arg name='recursionDepth' type='i' direction='in'/>"
    "      <arg name='propertyNames' type='as' direction='in'/>"
    "      <arg name='revision' type='u' direction='out'/>"
    "      <arg name='layout' type='(ia{sv}av)' direction='out'/>"
    "    </method>"
    "    <method name='GetGroupProperties'>"
    "      <arg name='ids' type='ai' direction='in'/>"
    "      <arg name='propertyNames' type='as' direction='in'/>"
    "      <arg name='properties' type='a(ia{sv})' direction='out'/>"
    "    </method>"
    "    <method name='GetProperty'>"
    "      <arg name='id' type='i' direction='in'/>"
    "      <arg name='name' type='s' direction='in'/>"
    "      <arg name='value' type='v' direction='out'/>"
    "    </method>"
    "    <method name='Event'>"
    "      <arg name='id' type='i' direction='in'/>"
    "      <arg name='eventId' type='s' direction='in'/>"
    "      <arg name='data' type='v' direction='in'/>"
    "      <arg name='timestamp' type='u' direction='in'/>"
    "    </method>"
    "    <method name='EventGroup'>"
    "      <arg name='events' type='a(isvu)' direction='in'/>"
    "      <arg name='idErrors' type='ai' direction='out'/>"
    "    </method>"
    "    <method name='AboutToShow'>"
    "      <arg name='id' type='i' direction='in'/>"
    "      <arg name='needUpdate' type='b' direction='out'/>"
    "    </method>"
    "    <method name='AboutToShowGroup'>"
    "      <arg name='ids' type='ai' direction='in'/>"
    "      <arg name='updatesNeeded' type='ai' direction='out'/>"
    "      <arg name='idErrors' type='ai' direction='out'/>"
    "    </method>"
    "    <signal name='ItemsPropertiesUpdated'>"
    "      <arg name='updatedProps' type='a(ia{sv})'/>"
    "      <arg name='removedProps' type='a(ias)'/>"
    "    </signal>"
    "    <signal name='LayoutUpdated'>"
    "      <arg name='revision' type='u'/><arg name='parent' type='i'/>"
    "    </signal>"
    "  </interface>"
    "</node>";

static gint64 now_ms(void)
{
    return g_get_real_time() / 1000;
}

static void logmsg(const char *fmt, ...) G_GNUC_PRINTF(1, 2);
static void logmsg(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("mb-tray: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
}

/* ------------------------------------------------------------------ status */

static const char *jnum(const char *json, const char *key, gint64 *out)
{
    char pat[64];
    const char *p;
    char *end = NULL;
    long long v;

    snprintf(pat, sizeof(pat), "\"%s\":", key);
    p = strstr(json, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (*p == ' ') p++;
    v = strtoll(p, &end, 10);
    if (end == p) return NULL;
    *out = (gint64)v;
    return end;
}

static void parse_clients(const char *json)
{
    const char *p = strstr(json, "\"clients\":[");
    char *w = st.pids;
    size_t left = sizeof(st.pids);

    st.max_client_bytes = 0;
    st.pids[0] = 0;
    if (!p) return;
    p += strlen("\"clients\":[");
    while ((p = strstr(p, "{\"pid\":")) != NULL) {
        gint64 pid = 0, bytes = 0;
        const char *q = jnum(p, "pid", &pid);
        const char *r = q ? jnum(p, "bytes", &bytes) : NULL;
        int n;
        if (!r) break;
        if (bytes > st.max_client_bytes) st.max_client_bytes = bytes;
        if (left > 24) {
            n = snprintf(w, left, "%s%lld:%.0fM", w == st.pids ? "" : " ", (long long)pid,
                         (double)bytes / 1048576.0);
            if (n > 0) {
                w += n;
                left -= (size_t)n;
            }
        }
        p = r;
    }
}

static gboolean parse_mbctl_json(const char *json)
{
    gint64 total = 0, pid = 0, floor = 0, map = 0, used = 0, count = 0, avail = 0, maps = 0, rss = 0;

    if (!json || !strstr(json, "\"ok\":true")) return FALSE;
    if (!jnum(json, "total_mb", &total) || !jnum(json, "pid_mb", &pid)) return FALSE;
    if (!jnum(json, "floor_mb", &floor)) floor = 0;
    if (!jnum(json, "map_limit", &map)) map = 0;
    if (!jnum(json, "total_bytes", &used)) used = 0;
    if (!jnum(json, "clients_count", &count)) count = 0;
    if (!jnum(json, "mem_available_kb", &avail)) avail = 0;
    if (!jnum(json, "maps", &maps)) maps = 0;
    if (!jnum(json, "server_rss_kb", &rss)) rss = 0;

    st.total_mb = total;
    st.pid_mb = pid;
    st.floor_mb = floor;
    st.map_limit = map;
    st.used_bytes = used;
    st.clients = count;
    st.avail_kb = avail;
    st.maps = maps;
    st.rss_kb = rss;
    st.from_log = FALSE;
    st.valid = TRUE;
    parse_clients(json);
    return TRUE;
}

/* Only the last "mem:" line of the log, never the report. */
static gboolean parse_log_tail(const char *path)
{
    int fd;
    off_t sz;
    size_t want;
    char *buf, *p, *last = NULL, *q, *nl;
    ssize_t n;

    if (!path || !*path) return FALSE;
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return FALSE;
    sz = lseek(fd, 0, SEEK_END);
    if (sz <= 0) {
        close(fd);
        return FALSE;
    }
    want = sz > (off_t)262144 ? 262144u : (size_t)sz;
    buf = g_malloc(want + 1);
    n = pread(fd, buf, want, sz - (off_t)want);
    close(fd);
    if (n <= 0) {
        g_free(buf);
        return FALSE;
    }
    buf[n] = 0;
    p = buf;
    while ((p = strstr(p, "mem: ")) != NULL) {
        last = p;
        p += 5;
    }
    if (!last) {
        g_free(buf);
        return FALSE;
    }
    nl = strchr(last, '\n');
    if (nl) *nl = 0;

    memset(&st, 0, sizeof(st));
    st.valid = TRUE;
    st.from_log = TRUE;
    st.total_mb = -1;
    st.pid_mb = -1;
    st.floor_mb = -1;
    st.map_limit = -1;
    if ((q = strstr(last, "rss ")) != NULL) st.rss_kb = strtoll(q + 4, NULL, 10) * 1024;
    if ((q = strstr(last, "free ")) != NULL) st.avail_kb = strtoll(q + 5, NULL, 10) * 1024;
    if ((q = strstr(last, "maps ")) != NULL) st.maps = strtoll(q + 5, NULL, 10);
    if ((q = strstr(last, "live ")) != NULL) st.used_bytes = strtoll(q + 5, NULL, 10) * 1048576;
    if ((q = strstr(last, "pids ")) != NULL) {
        size_t k;
        q += 5;
        for (k = 0; k + 1 < sizeof(st.pids) && q[k] && q[k] != '|' && q[k] != '\n'; k++)
            st.pids[k] = q[k];
        while (k && (st.pids[k - 1] == ' ' || st.pids[k - 1] == '|')) k--;
        st.pids[k] = 0;
        /* "live N/COUNT" counts allocations; the pids field counts clients. */
        for (k = 0; st.pids[k]; k++)
            if (st.pids[k] == ':') st.clients++;
    }
    g_free(buf);
    return st.used_bytes > 0 || st.avail_kb > 0;
}

static gchar *run_mbctl_status_sync(void)
{
    GSubprocessLauncher *l = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                                      G_SUBPROCESS_FLAGS_STDERR_SILENCE);
    GSubprocess *p;
    gchar *out = NULL;
    GError *err = NULL;

    g_subprocess_launcher_setenv(l, "MBCTL_SOCKET", opt.socket, TRUE);
    p = g_subprocess_launcher_spawn(l, &err, opt.mbctl, "status", "--json", NULL);
    g_object_unref(l);
    if (!p) {
        logmsg("mbctl spawn failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        return NULL;
    }
    if (!g_subprocess_communicate_utf8(p, NULL, NULL, &out, NULL, &err)) {
        logmsg("mbctl communicate failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        g_object_unref(p);
        return NULL;
    }
    if (!g_subprocess_get_successful(p)) {
        g_free(out);
        out = NULL;
    }
    g_object_unref(p);
    return out;
}

static void status_refresh(void);
static void menu_maybe_changed(void);
static void emit_signal(const char *iface, const char *member, GVariant *params);

static void on_poll_done(GObject *src, GAsyncResult *res, gpointer data)
{
    GSubprocess *p = G_SUBPROCESS(src);
    gchar *out = NULL;
    GError *err = NULL;
    gboolean ok = FALSE;
    (void)data;

    if (g_subprocess_communicate_utf8_finish(p, res, &out, NULL, &err) && g_subprocess_get_successful(p))
        ok = parse_mbctl_json(out);
    if (err) g_clear_error(&err);
    g_free(out);
    if (!ok) {
        if (!parse_log_tail(opt.log) && !st.valid) {
            memset(&st, 0, sizeof(st));
            st.total_mb = st.pid_mb = st.floor_mb = st.map_limit = -1;
        }
    }
    if (!sel_init && st.valid && st.total_mb > 0) {
        sel_total_mb = st.total_mb;
        sel_pid_mb = st.pid_mb > 0 ? st.pid_mb : 2048;
        sel_floor_mb = st.floor_mb > 0 ? st.floor_mb : 2048;
        sel_init = TRUE;
    }
    if (opt.verbose)
        logmsg("status %s: used %.1f MB, total %lld MB, clients %lld, avail %lld MB",
               st.from_log ? "log" : "mbctl", (double)st.used_bytes / 1048576.0,
               (long long)st.total_mb, (long long)st.clients, (long long)(st.avail_kb >> 10));
    menu_maybe_changed();
}

static void status_refresh(void)
{
    GSubprocessLauncher *l = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE |
                                                       G_SUBPROCESS_FLAGS_STDERR_SILENCE);
    GSubprocess *p;
    GError *err = NULL;

    g_subprocess_launcher_setenv(l, "MBCTL_SOCKET", opt.socket, TRUE);
    p = g_subprocess_launcher_spawn(l, &err, opt.mbctl, "status", "--json", NULL);
    g_object_unref(l);
    if (!p) {
        g_clear_error(&err);
        if (!parse_log_tail(opt.log) && !st.valid) {
            memset(&st, 0, sizeof(st));
            st.total_mb = st.pid_mb = st.floor_mb = st.map_limit = -1;
        }
        menu_maybe_changed();
        return;
    }
    g_subprocess_communicate_utf8_async(p, NULL, NULL, on_poll_done, NULL);
    g_object_unref(p);
}

/* ------------------------------------------------------------------ labels */

static gchar *fmt_gb(gint64 mb)
{
    return g_strdup_printf("%.1f G", (double)mb / 1024.0);
}

static gchar *label_for(int id)
{
    int i;
    if (id == ID_HEAD) {
        if (!st.valid) return g_strdup(mb_tr("MaliBridge  -- / -- G", "MaliBridge  未连接"));
        if (st.total_mb > 0)
            return g_strdup_printf("MaliBridge  %.1f/%.1f G", (double)st.used_bytes / 1073741824.0,
                                   (double)st.total_mb / 1024.0);
        return g_strdup_printf(mb_tr("MaliBridge  %.1f G used", "MaliBridge  已用 %.1f G"), (double)st.used_bytes / 1073741824.0);
    }
    if (id == ID_SYS) {
        if (!st.valid) return g_strdup(mb_tr("no control socket or log", "无控制套接字或日志"));
        return g_strdup_printf(mb_tr("MemAvailable %.0f MB  |  maps %lld  |  clients %lld", "可用内存 %.0f MB  |  映射 %lld  |  客户端 %lld"),
                               (double)st.avail_kb / 1024.0, (long long)st.maps, (long long)st.clients);
    }
    if (id == ID_PENDING) {
        gchar *t = fmt_gb(sel_total_mb), *p = fmt_gb(sel_pid_mb), *f = fmt_gb(sel_floor_mb);
        gchar *s = g_strdup_printf(mb_tr("pending  %s / client %s / floor %s", "待应用  %s / 单客户端 %s / 下限 %s"), t, p, f);
        g_free(t);
        g_free(p);
        g_free(f);
        return s;
    }
    if (id == ID_WARN) {
        if (st.valid && st.total_mb > 0 && sel_total_mb > 0 && st.used_bytes / 1048576 > sel_total_mb)
            return g_strdup_printf(mb_tr("warning: total %lld MB is below current usage %.1f G", "警告：总预算 %lld MB 低于当前占用 %.1f G"),
                                   (long long)sel_total_mb, (double)st.used_bytes / 1073741824.0);
        if (st.valid && sel_pid_mb > 0 && st.max_client_bytes / 1048576 > sel_pid_mb)
            return g_strdup_printf(mb_tr("warning: a client uses %.1f G, above the %lld MB per-client cap", "警告：单客户端占用 %.1f G，超过 %lld MB 上限"),
                                   (double)st.max_client_bytes / 1073741824.0, (long long)sel_pid_mb);
        return g_strdup("");
    }
    if (id == ID_TOTAL) {
        gchar *cur = st.total_mb > 0 ? fmt_gb(st.total_mb) : g_strdup("?");
        gchar *s = g_strdup_printf(mb_tr("Total budget  (%s)", "总预算  (%s)"), cur);
        g_free(cur);
        return s;
    }
    if (id == ID_PID) {
        gchar *cur = st.pid_mb > 0 ? fmt_gb(st.pid_mb) : g_strdup("?");
        gchar *s = g_strdup_printf(mb_tr("Per client  (%s)", "单客户端  (%s)"), cur);
        g_free(cur);
        return s;
    }
    if (id == ID_FLOOR) {
        gchar *cur = st.floor_mb > 0 ? fmt_gb(st.floor_mb) : g_strdup("?");
        gchar *s = g_strdup_printf(mb_tr("MemAvailable floor  (%s)", "可用内存下限  (%s)"), cur);
        g_free(cur);
        return s;
    }
    if (id >= ID_TOTAL_FIRST && id < ID_TOTAL_FIRST + N_TOTALS) {
        i = id - ID_TOTAL_FIRST;
        if (TOTALS[i] == 8192) return g_strdup(mb_tr("8 G  (warning: high)", "8 G（偏高）"));
        return g_strdup_printf("%lld G", (long long)(TOTALS[i] / 1024));
    }
    if (id >= ID_PID_FIRST && id < ID_PID_FIRST + N_PIDS)
        return g_strdup_printf("%lld G", (long long)(PIDS[id - ID_PID_FIRST] / 1024));
    if (id >= ID_FLOOR_FIRST && id < ID_FLOOR_FIRST + N_FLOORS)
        return g_strdup_printf("%.1f G", (double)FLOORS[id - ID_FLOOR_FIRST] / 1024.0);
    if (id == ID_APPLY) return g_strdup(mb_tr("Apply now", "立即应用"));
    if (id == ID_APPLY_NEXT) return g_strdup(mb_tr("Apply now + save for next start", "立即应用并保存到下次启动"));
    if (id == ID_REPORT) return g_strdup(mb_tr("Open report", "打开报告"));
    if (id == ID_LOG) return g_strdup(mb_tr("Open log", "打开日志"));
    if (id == ID_QUIT) return g_strdup(mb_tr("Quit", "退出"));
    return g_strdup("");
}

static gboolean visible_for(int id)
{
    if (id == ID_PENDING || id == ID_WARN) {
        gchar *s = label_for(id);
        gboolean v = s[0] != 0;
        g_free(s);
        return v;
    }
    return TRUE;
}

static gboolean enabled_for(int id)
{
    if (id == ID_HEAD || id == ID_SYS || id == ID_PENDING || id == ID_WARN) return FALSE;
    if (id == ID_APPLY || id == ID_APPLY_NEXT) return sel_init;
    return TRUE;
}

static const char *toggle_type_for(int id)
{
    if (id >= ID_TOTAL_FIRST && id < ID_TOTAL_FIRST + N_TOTALS) return "radio";
    if (id >= ID_PID_FIRST && id < ID_PID_FIRST + N_PIDS) return "radio";
    if (id >= ID_FLOOR_FIRST && id < ID_FLOOR_FIRST + N_FLOORS) return "radio";
    return NULL;
}

static int toggle_state_for(int id)
{
    if (id >= ID_TOTAL_FIRST && id < ID_TOTAL_FIRST + N_TOTALS)
        return sel_total_mb == TOTALS[id - ID_TOTAL_FIRST] ? 1 : 0;
    if (id >= ID_PID_FIRST && id < ID_PID_FIRST + N_PIDS)
        return sel_pid_mb == PIDS[id - ID_PID_FIRST] ? 1 : 0;
    if (id >= ID_FLOOR_FIRST && id < ID_FLOOR_FIRST + N_FLOORS)
        return sel_floor_mb == FLOORS[id - ID_FLOOR_FIRST] ? 1 : 0;
    return 0;
}

static const char *child_display_for(int id)
{
    if (id == ID_TOTAL || id == ID_PID || id == ID_FLOOR) return "submenu";
    return NULL;
}

static int children_of(int id, int *out)
{
    int n = 0, i;
    switch (id) {
    case 0:
        out[n++] = ID_HEAD;
        out[n++] = ID_SYS;
        if (visible_for(ID_PENDING)) out[n++] = ID_PENDING;
        if (visible_for(ID_WARN)) out[n++] = ID_WARN;
        out[n++] = ID_SEP1;
        out[n++] = ID_TOTAL;
        out[n++] = ID_PID;
        out[n++] = ID_FLOOR;
        out[n++] = ID_SEP2;
        out[n++] = ID_APPLY;
        out[n++] = ID_APPLY_NEXT;
        out[n++] = ID_REPORT;
        out[n++] = ID_LOG;
        out[n++] = ID_QUIT;
        break;
    case ID_TOTAL:
        for (i = 0; i < N_TOTALS; i++) out[n++] = ID_TOTAL_FIRST + i;
        break;
    case ID_PID:
        for (i = 0; i < N_PIDS; i++) out[n++] = ID_PID_FIRST + i;
        break;
    case ID_FLOOR:
        for (i = 0; i < N_FLOORS; i++) out[n++] = ID_FLOOR_FIRST + i;
        break;
    default:
        break;
    }
    return n;
}

static void add_props(GVariantBuilder *pb, int id)
{
    gchar *label = label_for(id);
    const char *tt = toggle_type_for(id), *cd = child_display_for(id);

    g_variant_builder_add(pb, "{sv}", "label", g_variant_new_string(label));
    g_variant_builder_add(pb, "{sv}", "enabled", g_variant_new_boolean(enabled_for(id)));
    g_variant_builder_add(pb, "{sv}", "visible", g_variant_new_boolean(visible_for(id)));
    g_variant_builder_add(pb, "{sv}", "type",
                          g_variant_new_string(id == ID_SEP1 || id == ID_SEP2 ? "separator" : "standard"));
    if (tt) {
        g_variant_builder_add(pb, "{sv}", "toggle-type", g_variant_new_string(tt));
        g_variant_builder_add(pb, "{sv}", "toggle-state", g_variant_new_int32(toggle_state_for(id)));
    }
    if (cd) g_variant_builder_add(pb, "{sv}", "children-display", g_variant_new_string(cd));
    g_free(label);
}

static GVariant *node_var(int id, int depth)
{
    GVariantBuilder pb, cb;
    int kids[16], n, i;

    g_variant_builder_init(&pb, G_VARIANT_TYPE_VARDICT);
    add_props(&pb, id);
    g_variant_builder_init(&cb, G_VARIANT_TYPE("av"));
    n = depth == 0 ? 0 : children_of(id, kids);
    for (i = 0; i < n; i++)
        g_variant_builder_add(&cb, "v", node_var(kids[i], depth < 0 ? -1 : depth - 1));
    return g_variant_new("(ia{sv}av)", id, &pb, &cb);
}

static void return_value(GDBusMethodInvocation *inv, GVariant *value)
{
    g_dbus_method_invocation_return_value(inv, g_variant_new_tuple(&value, 1));
}

/* -------------------------------------------------------------------- menu */

static gchar *tooltip_subtitle(void)
{
    if (!st.valid) return g_strdup(mb_tr("no budget status", "无预算状态"));
    if (st.total_mb > 0)
        return g_strdup_printf(mb_tr("%.1f/%.1f G  |  MemAvailable %.0f MB  |  clients %lld", "%.1f/%.1f G  |  可用内存 %.0f MB  |  客户端 %lld"),
                               (double)st.used_bytes / 1073741824.0, (double)st.total_mb / 1024.0,
                               (double)st.avail_kb / 1024.0, (long long)st.clients);
    return g_strdup_printf(mb_tr("%.1f G used  |  MemAvailable %.0f MB", "已用 %.1f G  |  可用内存 %.0f MB"),
                           (double)st.used_bytes / 1073741824.0, (double)st.avail_kb / 1024.0);
}

static void emit_signal(const char *iface, const char *member, GVariant *params)
{
    if (!item_conn || !registered) {
        if (params) {
            g_variant_ref_sink(params);
            g_variant_unref(params);
        }
        return;
    }
    g_dbus_connection_emit_signal(item_conn, NULL, strcmp(iface, MENU_IFACE) == 0 ? MENU_PATH : SNI_PATH,
                                  iface, member, params, NULL);
}

static void menu_maybe_changed(void)
{
    static gchar *prev_menu, *prev_tip;
    int ids[12] = {ID_HEAD, ID_SYS, ID_PENDING, ID_WARN, ID_TOTAL, ID_PID,
                   ID_FLOOR, ID_APPLY, ID_APPLY_NEXT, ID_REPORT, ID_LOG, ID_QUIT};
    GString *s = g_string_new(NULL);
    gchar *tip;
    int i;

    for (i = 0; i < 12; i++) {
        gchar *l = label_for(ids[i]);
        g_string_append(s, l);
        g_free(l);
        g_string_append_printf(s, "%d%d", enabled_for(ids[i]), visible_for(ids[i]));
    }
    for (i = 0; i < N_TOTALS; i++) g_string_append_printf(s, "%d", toggle_state_for(ID_TOTAL_FIRST + i));
    for (i = 0; i < N_PIDS; i++) g_string_append_printf(s, "%d", toggle_state_for(ID_PID_FIRST + i));
    for (i = 0; i < N_FLOORS; i++) g_string_append_printf(s, "%d", toggle_state_for(ID_FLOOR_FIRST + i));

    if (!prev_menu || strcmp(prev_menu, s->str) != 0) {
        g_free(prev_menu);
        prev_menu = g_strdup(s->str);
        menu_rev++;
        emit_signal(MENU_IFACE, "LayoutUpdated", g_variant_new("(ui)", menu_rev, 0));
    }

    tip = tooltip_subtitle();
    if (!prev_tip || strcmp(prev_tip, tip) != 0) {
        g_free(prev_tip);
        prev_tip = g_strdup(tip);
        emit_signal(SNI_IFACE, "NewToolTip", NULL);
    }
    g_free(tip);
    g_string_free(s, TRUE);
}

/* -------------------------------------------------------------- arbitration */

static gboolean heartbeat_fresh(void)
{
    GStatBuf sb;
    gint64 now = now_ms(), age, stamp = 0;
    int fd;
    char buf[96];
    ssize_t n;

    if (g_stat(opt.heartbeat, &sb) != 0) return FALSE;
    age = now - (gint64)sb.st_mtime * 1000;
    if (age >= -2000 && age <= opt.heartbeat_max_ms) return TRUE;

    fd = open(opt.heartbeat, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return FALSE;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return FALSE;
    buf[n] = 0;
    stamp = g_ascii_strtoll(buf, NULL, 10);
    if (stamp > 1000000000000LL) {
        age = now - stamp;
        if (age >= -2000 && age <= opt.heartbeat_max_ms) return TRUE;
    }
    return FALSE;
}

static void tray_down(const char *why)
{
    if (!registered) return;
    logmsg("item unregistered (%s)", why);
    registered = FALSE;
    if (item_conn) {
        if (sni_reg) g_dbus_connection_unregister_object(item_conn, sni_reg);
        if (menu_reg) g_dbus_connection_unregister_object(item_conn, menu_reg);
        g_dbus_connection_set_exit_on_close(item_conn, FALSE);
        g_dbus_connection_close_sync(item_conn, NULL, NULL);
    }
    sni_reg = menu_reg = 0;
    g_clear_object(&item_conn);
}

static gboolean tray_up(void)
{
    GError *err = NULL;
    GDBusNodeInfo *sni_info = NULL, *menu_info = NULL;
    gchar *addr;
    GVariant *r;
    const gchar *service;

    if (registered) return TRUE;
    if (!watcher_present) return FALSE;
    if (now_ms() < next_register_ms) return FALSE;

    addr = g_dbus_address_get_for_bus_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!addr) {
        logmsg("session bus address: %s", err ? err->message : "?");
        g_clear_error(&err);
        next_register_ms = now_ms() + 30000;
        return FALSE;
    }
    item_conn = g_dbus_connection_new_for_address_sync(
        addr,
        G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
        NULL, NULL, &err);
    g_free(addr);
    if (!item_conn) {
        logmsg("private bus connection failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        next_register_ms = now_ms() + 30000;
        return FALSE;
    }
    g_dbus_connection_set_exit_on_close(item_conn, FALSE);

    sni_info = g_dbus_node_info_new_for_xml(sni_xml, &err);
    menu_info = g_dbus_node_info_new_for_xml(menu_xml, &err);
    if (!sni_info || !menu_info) {
        logmsg("interface XML: %s", err ? err->message : "?");
        g_clear_error(&err);
        goto fail;
    }
    sni_reg = g_dbus_connection_register_object(item_conn, SNI_PATH, sni_info->interfaces[0],
                                                &mb_sni_vtable, NULL, NULL, &err);
    if (!sni_reg) {
        logmsg("export SNI failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        goto fail;
    }
    menu_reg = g_dbus_connection_register_object(item_conn, MENU_PATH, menu_info->interfaces[0],
                                                 &mb_menu_vtable, NULL, NULL, &err);
    if (!menu_reg) {
        logmsg("export menu failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        goto fail;
    }

    /* Own a stable well-known name when possible: some watchers reject unique names. */
    r = g_dbus_connection_call_sync(item_conn, "org.freedesktop.DBus", "/org/freedesktop/DBus",
                                    "org.freedesktop.DBus", "RequestName",
                                    g_variant_new("(su)", SNI_SERVICE, 0u), NULL,
                                    G_DBUS_CALL_FLAGS_NONE, 3000, NULL, NULL);
    if (r) g_variant_unref(r);
    service = SNI_SERVICE;

    r = g_dbus_connection_call_sync(bus, WATCHER_NAME, WATCHER_PATH, WATCHER_IFACE,
                                    "RegisterStatusNotifierItem", g_variant_new("(s)", service),
                                    NULL, G_DBUS_CALL_FLAGS_NONE, 3000, NULL, &err);
    if (!r) {
        logmsg("RegisterStatusNotifierItem(%s) failed: %s", service, err ? err->message : "?");
        g_clear_error(&err);
        goto fail;
    }
    g_variant_unref(r);

    g_dbus_node_info_unref(sni_info);
    g_dbus_node_info_unref(menu_info);
    registered = TRUE;
    next_register_ms = 0;
    logmsg("item registered with %s as %s", WATCHER_NAME, service);
    emit_signal(SNI_IFACE, "NewStatus", g_variant_new("(s)", "Active"));
    emit_signal(SNI_IFACE, "NewIcon", NULL);
    emit_signal(SNI_IFACE, "NewToolTip", NULL);
    return TRUE;

fail:
    if (sni_info) g_dbus_node_info_unref(sni_info);
    if (menu_info) g_dbus_node_info_unref(menu_info);
    tray_down("export/register failed");
    next_register_ms = now_ms() + 30000;
    return FALSE;
}

static void arbitrate(void)
{
    gboolean fresh;
    if (opt.no_register) return;
    if (!armed) return;
    fresh = heartbeat_fresh();
    if (fresh) {
        if (registered) tray_down("plugin heartbeat is fresh");
        return;
    }
    if (!registered) {
        if (tray_up()) logmsg("tray owns the icon (plugin heartbeat stale or absent)");
        else if (!watcher_present) logmsg("DORMANT: no %s; retrying every 30 s", WATCHER_NAME);
    }
}

/* ----------------------------------------------------------------- actions */

static void open_path(const char *path)
{
    GError *err = NULL;
    gchar *argv[3];
    argv[0] = (gchar *)"xdg-open";
    argv[1] = (gchar *)path;
    argv[2] = NULL;
    if (!g_spawn_async(NULL, argv, NULL, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL, &err)) {
        logmsg("open %s: %s", path, err ? err->message : "?");
        g_clear_error(&err);
    }
}

static void on_apply_done(GObject *src, GAsyncResult *res, gpointer data)
{
    GSubprocess *p = G_SUBPROCESS(src);
    gchar *out = NULL;
    GError *err = NULL;
    (void)data;
    if (g_subprocess_communicate_utf8_finish(p, res, &out, NULL, &err)) {
        gboolean ok = g_subprocess_get_successful(p);
        logmsg("budget set %s%s%s", ok ? "ok" : "failed", out && *out ? ": " : "",
               out && *out ? g_strchomp(out) : "");
    } else {
        logmsg("budget set failed: %s", err ? err->message : "?");
        g_clear_error(&err);
    }
    g_free(out);
    status_refresh();
}

static void apply_budget(gboolean persist)
{
    GSubprocessLauncher *l;
    GSubprocess *p;
    GError *err = NULL;
    char total[32], pid[32], floor[32];

    if (!sel_init) return;
    snprintf(total, sizeof(total), "%lld", (long long)sel_total_mb);
    snprintf(pid, sizeof(pid), "%lld", (long long)sel_pid_mb);
    snprintf(floor, sizeof(floor), "%lld", (long long)sel_floor_mb);

    l = g_subprocess_launcher_new(G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
    g_subprocess_launcher_setenv(l, "MBCTL_SOCKET", opt.socket, TRUE);
    if (persist)
        p = g_subprocess_launcher_spawn(l, &err, opt.mbctl, "set", "--total", total, "--pid", pid,
                                       "--floor", floor, "--persist", "--json", NULL);
    else
        p = g_subprocess_launcher_spawn(l, &err, opt.mbctl, "set", "--total", total, "--pid", pid,
                                       "--floor", floor, "--json", NULL);
    g_object_unref(l);
    if (!p) {
        logmsg("mbctl set spawn failed: %s", err ? err->message : "?");
        g_clear_error(&err);
        return;
    }
    g_subprocess_communicate_utf8_async(p, NULL, NULL, on_apply_done, NULL);
    g_object_unref(p);
}

static void on_menu_event(int id)
{
    if (id >= ID_TOTAL_FIRST && id < ID_TOTAL_FIRST + N_TOTALS) {
        sel_total_mb = TOTALS[id - ID_TOTAL_FIRST];
        sel_init = TRUE;
    } else if (id >= ID_PID_FIRST && id < ID_PID_FIRST + N_PIDS) {
        sel_pid_mb = PIDS[id - ID_PID_FIRST];
        sel_init = TRUE;
    } else if (id >= ID_FLOOR_FIRST && id < ID_FLOOR_FIRST + N_FLOORS) {
        sel_floor_mb = FLOORS[id - ID_FLOOR_FIRST];
        sel_init = TRUE;
    } else if (id == ID_APPLY) {
        apply_budget(FALSE);
    } else if (id == ID_APPLY_NEXT) {
        apply_budget(TRUE);
    } else if (id == ID_REPORT) {
        open_path(opt.report);
    } else if (id == ID_LOG) {
        open_path(opt.log);
    } else if (id == ID_QUIT) {
        g_main_loop_quit(loop);
    } else {
        return;
    }
    menu_maybe_changed();
}

/* ------------------------------------------------------------ dbus vtables */

static GVariant *sni_get_property(GDBusConnection *c, const gchar *sender, const gchar *path,
                                  const gchar *iface, const gchar *prop, GError **error,
                                  gpointer data)
{
    GVariantBuilder rows;
    (void)c;
    (void)sender;
    (void)path;
    (void)iface;
    (void)data;
    (void)error;
    if (!strcmp(prop, "Category")) return g_variant_new_string("ApplicationStatus");
    if (!strcmp(prop, "Id")) return g_variant_new_string("mb-tray");
    if (!strcmp(prop, "Title")) return g_variant_new_string("MaliBridge");
    if (!strcmp(prop, "Status")) return g_variant_new_string(registered ? "Active" : "Passive");
    if (!strcmp(prop, "WindowId")) return g_variant_new_int32(0);
    if (!strcmp(prop, "IconName")) return g_variant_new_string("mb-budget");
    if (!strcmp(prop, "IconPixmap") || !strcmp(prop, "OverlayIconPixmap") ||
        !strcmp(prop, "AttentionIconPixmap")) {
        g_variant_builder_init(&rows, G_VARIANT_TYPE("a(iiay)"));
        return g_variant_new("a(iiay)", &rows);
    }
    if (!strcmp(prop, "OverlayIconName")) return g_variant_new_string("");
    if (!strcmp(prop, "AttentionIconName")) return g_variant_new_string("");
    if (!strcmp(prop, "AttentionMovieName")) return g_variant_new_string("");
    if (!strcmp(prop, "ItemIsMenu")) return g_variant_new_boolean(TRUE);
    if (!strcmp(prop, "Menu")) return g_variant_new_object_path(MENU_PATH);
    if (!strcmp(prop, "ToolTip")) {
        gchar *sub = tooltip_subtitle();
        GVariant *v;
        g_variant_builder_init(&rows, G_VARIANT_TYPE("a(iiay)"));
        v = g_variant_new("(sa(iiay)ss)", "mb-budget", &rows, "MaliBridge", sub);
        g_free(sub);
        return v;
    }
    return NULL;
}

static void sni_method_call(GDBusConnection *c, const gchar *sender, const gchar *path,
                            const gchar *iface, const gchar *method, GVariant *params,
                            GDBusMethodInvocation *inv, gpointer data)
{
    (void)c;
    (void)sender;
    (void)path;
    (void)iface;
    (void)params;
    (void)data;
    (void)method;
    /* ItemIsMenu is true: the host presents the DBusMenu itself. */
    g_dbus_method_invocation_return_value(inv, NULL);
}

static GVariant *menu_get_property(GDBusConnection *c, const gchar *sender, const gchar *path,
                                   const gchar *iface, const gchar *prop, GError **error,
                                   gpointer data)
{
    GVariantBuilder b;
    (void)c;
    (void)sender;
    (void)path;
    (void)iface;
    (void)data;
    (void)error;
    if (!strcmp(prop, "Version")) return g_variant_new_uint32(3);
    if (!strcmp(prop, "TextDirection")) return g_variant_new_string("ltr");
    if (!strcmp(prop, "Status")) return g_variant_new_string("normal");
    if (!strcmp(prop, "IconThemePath")) {
        g_variant_builder_init(&b, G_VARIANT_TYPE("as"));
        g_variant_builder_add(&b, "s", "/usr/share/icons/hicolor/scalable/apps");
        return g_variant_new("as", &b);
    }
    return NULL;
}

static void menu_method_call(GDBusConnection *c, const gchar *sender, const gchar *path,
                             const gchar *iface, const gchar *method, GVariant *params,
                             GDBusMethodInvocation *inv, gpointer data)
{
    (void)c;
    (void)sender;
    (void)path;
    (void)iface;
    (void)data;

    if (!strcmp(method, "GetLayout")) {
        gint32 parent = 0, depth = -1;
        GVariant *names = NULL;
        g_variant_get(params, "(ii@as)", &parent, &depth, &names);
        g_variant_unref(names);
        /* already a full (u(ia{sv}av)) tuple: no extra wrapping */
        g_dbus_method_invocation_return_value(
            inv, g_variant_new("(u@(ia{sv}av))", menu_rev, node_var(parent, depth)));
        return;
    }
    if (!strcmp(method, "GetGroupProperties")) {
        GVariant *ids = NULL, *names = NULL;
        GVariantIter *it;
        GVariantBuilder ob;
        gint32 id;
        g_variant_get(params, "(@ai@as)", &ids, &names);
        g_variant_unref(names);
        g_variant_builder_init(&ob, G_VARIANT_TYPE("a(ia{sv})"));
        it = g_variant_iter_new(ids);
        while (g_variant_iter_next(it, "i", &id)) {
            GVariantBuilder pb;
            g_variant_builder_init(&pb, G_VARIANT_TYPE_VARDICT);
            add_props(&pb, id);
            g_variant_builder_add(&ob, "(ia{sv})", id, &pb);
        }
        g_variant_iter_free(it);
        g_variant_unref(ids);
        return_value(inv, g_variant_new("a(ia{sv})", &ob));
        return;
    }
    if (!strcmp(method, "GetProperty")) {
        gint32 id = 0;
        const gchar *name = NULL;
        GVariantBuilder pb;
        GVariant *dict, *val;
        g_variant_get(params, "(i&s)", &id, &name);
        g_variant_builder_init(&pb, G_VARIANT_TYPE_VARDICT);
        add_props(&pb, id);
        dict = g_variant_builder_end(&pb);
        val = g_variant_lookup_value(dict, name, NULL);
        if (!val) val = g_variant_new_string("");
        g_variant_unref(dict);
        return_value(inv, g_variant_new_variant(val));
        return;
    }
    if (!strcmp(method, "Event")) {
        gint32 id = 0, ts = 0;
        const gchar *event = NULL;
        GVariant *data_v = NULL;
        g_variant_get(params, "(i&s@vu)", &id, &event, &data_v, &ts);
        if (!strcmp(event, "clicked")) on_menu_event(id);
        g_variant_unref(data_v);
        g_dbus_method_invocation_return_value(inv, NULL);
        return;
    }
    if (!strcmp(method, "EventGroup")) {
        GVariant *arr = NULL;
        GVariantIter *it;
        gint32 id, ts;
        const gchar *event;
        GVariant *dv;
        g_variant_get(params, "(@a(isvu))", &arr);
        it = g_variant_iter_new(arr);
        while (g_variant_iter_next(it, "(i&s@vu)", &id, &event, &dv, &ts)) {
            if (!strcmp(event, "clicked")) on_menu_event(id);
            g_variant_unref(dv);
        }
        g_variant_iter_free(it);
        g_variant_unref(arr);
        {
            GVariantBuilder b;
            g_variant_builder_init(&b, G_VARIANT_TYPE("ai"));
            return_value(inv, g_variant_new("ai", &b));
        }
        return;
    }
    if (!strcmp(method, "AboutToShow"))
        return_value(inv, g_variant_new_boolean(FALSE));
    else if (!strcmp(method, "AboutToShowGroup")) {
        GVariantBuilder a, b;
        g_variant_builder_init(&a, G_VARIANT_TYPE("ai"));
        g_variant_builder_init(&b, G_VARIANT_TYPE("ai"));
        g_dbus_method_invocation_return_value(inv, g_variant_new("(aiai)", &a, &b));
    } else
        g_dbus_method_invocation_return_dbus_error(inv, "org.freedesktop.DBus.Error.UnknownMethod",
                                                   "unknown method");
    (void)method;
}

static const GDBusInterfaceVTable mb_sni_vtable = {sni_method_call, sni_get_property, NULL, {0}};
static const GDBusInterfaceVTable mb_menu_vtable = {menu_method_call, menu_get_property, NULL, {0}};

/* ------------------------------------------------------------------- timers */

static gboolean on_poll_tick(gpointer data)
{
    (void)data;
    status_refresh();
    arbitrate();
    return G_SOURCE_CONTINUE;
}

static gboolean on_start_done(gpointer data)
{
    (void)data;
    start_timer = 0;
    armed = TRUE;
    logmsg("start delay elapsed (%d ms); heartbeat %s", opt.start_delay_ms,
           heartbeat_fresh() ? "fresh -> standing down" : "stale -> claiming the icon");
    status_refresh();
    arbitrate();
    poll_timer = g_timeout_add((guint)opt.poll_ms, on_poll_tick, NULL);
    return G_SOURCE_REMOVE;
}

static void on_watcher_appeared(GDBusConnection *c, const gchar *name, const gchar *owner,
                                gpointer data)
{
    (void)c;
    (void)name;
    (void)owner;
    (void)data;
    if (!watcher_present) logmsg("%s appeared", WATCHER_NAME);
    watcher_present = TRUE;
    arbitrate();
}

static void on_watcher_vanished(GDBusConnection *c, const gchar *name, gpointer data)
{
    (void)c;
    (void)name;
    (void)data;
    watcher_present = FALSE;
    logmsg("%s vanished", WATCHER_NAME);
    tray_down("watcher is gone");
}

/* -------------------------------------------------------------------- main */

static void usage(FILE *f)
{
    fprintf(f,
            "usage: mb-tray [options]\n"
            "  --socket PATH          mbctl control socket (env MBCTL_SOCKET)\n"
            "  --mbctl PATH           mbctl binary (env MBCTL)\n"
            "  --heartbeat PATH       plugin heartbeat file (default /run/user/1000/mb-budget-ui.plugin)\n"
            "  --start-delay SEC      wait before claiming the icon (default 8)\n"
            "  --heartbeat-max SEC    heartbeat freshness window (default 15)\n"
            "  --poll SEC             status/arbitration period (default 5)\n"
            "  --report PATH          report opened from the menu\n"
            "  --log PATH             server log for the mem: fallback\n"
            "  --status-once          print one status snapshot and exit\n"
            "  --print-menu           print the menu labels and exit\n"
            "  --no-register          never register (tests)\n"
            "  -v, --verbose          log every poll\n"
            "  -h, --help             this text\n");
}

static gboolean parse_args(int argc, char **argv)
{
    int i;
    for (i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!strcmp(a, "--socket") && v) {
            opt.socket = v;
            i++;
        } else if (!strcmp(a, "--mbctl") && v) {
            opt.mbctl = v;
            i++;
        } else if (!strcmp(a, "--heartbeat") && v) {
            opt.heartbeat = v;
            i++;
        } else if (!strcmp(a, "--report") && v) {
            opt.report = v;
            i++;
        } else if (!strcmp(a, "--log") && v) {
            opt.log = v;
            i++;
        } else if (!strcmp(a, "--start-delay") && v) {
            opt.start_delay_ms = atoi(v) * 1000;
            i++;
        } else if (!strcmp(a, "--heartbeat-max") && v) {
            opt.heartbeat_max_ms = atoi(v) * 1000;
            i++;
        } else if (!strcmp(a, "--poll") && v) {
            opt.poll_ms = atoi(v) * 1000;
            i++;
        } else if (!strcmp(a, "--status-once")) {
            opt.status_once = TRUE;
        } else if (!strcmp(a, "--print-menu")) {
            opt.print_menu = TRUE;
        } else if (!strcmp(a, "--no-register")) {
            opt.no_register = TRUE;
        } else if (!strcmp(a, "-v") || !strcmp(a, "--verbose")) {
            opt.verbose = TRUE;
        } else if (!strcmp(a, "-h") || !strcmp(a, "--help")) {
            usage(stdout);
            return FALSE;
        } else {
            usage(stderr);
            return FALSE;
        }
    }
    if (!opt.socket) {
        opt.socket = g_getenv("MBCTL_SOCKET");
        if (!opt.socket || !*opt.socket) opt.socket = "/opt/mb-sock/control.sock";
    }
    if (!opt.mbctl) {
        opt.mbctl = g_getenv("MBCTL");
        if (!opt.mbctl || !*opt.mbctl) {
            if (g_file_test("/opt/mb-ctl-42391593385/bin/mbctl", G_FILE_TEST_IS_EXECUTABLE))
                opt.mbctl = "/opt/mb-ctl-42391593385/bin/mbctl";
            else
                opt.mbctl = "mbctl";
        }
    }
    if (opt.poll_ms < 1000) opt.poll_ms = 1000;
    if (opt.heartbeat_max_ms < 1000) opt.heartbeat_max_ms = 1000;
    return TRUE;
}

static gboolean status_once(void)
{
    gchar *out = run_mbctl_status_sync();
    gboolean ok = out ? parse_mbctl_json(out) : FALSE;
    g_free(out);
    if (!ok) ok = parse_log_tail(opt.log);
    printf("source  %s\n",
           ok ? (st.from_log ? "server.log mem: tail" : "control.sock status") : "unavailable");
    if (!st.valid) {
        printf("usage   --\n");
        return ok;
    }
    if (st.total_mb > 0)
        printf("budget  total %lld MB, per client %lld MB, floor %lld MB, maps %lld\n",
               (long long)st.total_mb, (long long)st.pid_mb, (long long)st.floor_mb,
               (long long)st.map_limit);
    else
        printf("budget  unknown (log fallback)\n");
    printf("usage   %.1f MB total, %lld client%s\n", (double)st.used_bytes / 1048576.0,
           (long long)st.clients, st.clients == 1 ? "" : "s");
    printf("system  MemAvailable %lld MB, maps %lld, server RSS %lld MB\n",
           (long long)(st.avail_kb >> 10), (long long)st.maps, (long long)(st.rss_kb >> 10));
    if (st.pids[0]) printf("pids    %s\n", st.pids);
    printf("socket  %s\nmbctl   %s\n", opt.socket, opt.mbctl);
    return TRUE;
}

static void print_menu(void)
{
    int ids[24], n, i;
    gchar *out = run_mbctl_status_sync();
    if (!(out && parse_mbctl_json(out))) parse_log_tail(opt.log);
    g_free(out);
    if (!sel_init && st.valid && st.total_mb > 0) {
        sel_total_mb = st.total_mb;
        sel_pid_mb = st.pid_mb > 0 ? st.pid_mb : 2048;
        sel_floor_mb = st.floor_mb > 0 ? st.floor_mb : 2048;
        sel_init = TRUE;
    }
    n = children_of(0, ids);
    for (i = 0; i < n; i++) {
        gchar *l = label_for(ids[i]);
        if (ids[i] == ID_SEP1 || ids[i] == ID_SEP2) {
            printf("        ------\n");
        } else {
            printf("%5d  %s%s\n", ids[i], l, enabled_for(ids[i]) ? "" : "  [disabled]");
        }
        g_free(l);
        if (ids[i] == ID_TOTAL || ids[i] == ID_PID || ids[i] == ID_FLOOR) {
            int sub[8], m, k;
            m = children_of(ids[i], sub);
            for (k = 0; k < m; k++) {
                gchar *s = label_for(sub[k]);
                printf("       %5d  %s%s\n", sub[k], s, toggle_state_for(sub[k]) ? "  (*)" : "");
                g_free(s);
            }
        }
    }
}

int main(int argc, char **argv)
{
    GError *err = NULL;

    if (!parse_args(argc, argv)) return 1;
    if (opt.status_once) return status_once() ? 0 : 2;
    if (opt.print_menu) {
        print_menu();
        return 0;
    }

    signal(SIGPIPE, SIG_IGN);
    loop = g_main_loop_new(NULL, FALSE);

    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &err);
    if (!bus) {
        logmsg("no session bus: %s", err ? err->message : "?");
        g_clear_error(&err);
        return 2;
    }
    g_dbus_connection_set_exit_on_close(bus, FALSE);
    g_bus_watch_name_on_connection(bus, WATCHER_NAME, G_BUS_NAME_WATCHER_FLAGS_NONE,
                                   on_watcher_appeared, on_watcher_vanished, NULL, NULL);
    logmsg("starting: mbctl=%s socket=%s heartbeat=%s", opt.mbctl, opt.socket, opt.heartbeat);

    start_timer = g_timeout_add((guint)opt.start_delay_ms, on_start_done, NULL);
    g_main_loop_run(loop);

    if (start_timer) g_source_remove(start_timer);
    if (poll_timer) g_source_remove(poll_timer);
    tray_down("shutdown");
    if (bus) g_object_unref(bus);
    g_main_loop_unref(loop);
    return 0;
}