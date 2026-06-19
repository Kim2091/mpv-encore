// mpv-settings — native Win32 settings window for mpv (mpv.net-style).
//
// A self-contained native GUI: a category TreeView on the left, the settings of
// the selected category on the right, an always-visible help/description pane
// (the "tooltips" mpv.net had), and a search box. It reads the same
// editor_conf.txt the Lua package uses, loads current values from mpv.conf, and
// (later phases) writes mpv.conf and live-applies via mpv's IPC pipe.
//
// Build (from a VS Developer prompt or via vcvars64):
//   cl /nologo /W3 /O2 mpv-settings.c /Fe:mpv-settings.exe ^
//      /link user32.lib comctl32.lib gdi32.lib shell32.lib ole32.lib
//
// This is the GUI component for the forked-mpv approach; it needs none of mpv's
// libraries to build, so it compiles with just MSVC + the Windows SDK.

#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>
#include <commdlg.h>
#include <shlobj.h>

#pragma comment(lib, "comdlg32.lib")
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#pragma comment(lib, "comctl32.lib")

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

#define MAX_SETTINGS 400
#define MAX_OPTIONS  64

typedef struct {
    char name[96];
    char help[512];
} Option;

typedef struct {
    char name[96];
    char file[24];
    char directory[160];
    char url[200];
    char type[16];
    char def[256];
    char value[256];          // current value (from mpv.conf, else default)
    char start[256];          // value at load time, to detect changes
    char help[2048];
    int  is_option;
    Option options[MAX_OPTIONS];
    int  n_options;
} Setting;

static Setting g_settings[MAX_SETTINGS];
static int     g_nsettings;

// ---------------------------------------------------------------------------
// Small string helpers
// ---------------------------------------------------------------------------

static void str_trim(char *s) {
    char *p = s;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') p++;
    if (p != s) memmove(s, p, strlen(p) + 1);
    size_t n = strlen(s);
    while (n > 0 && (s[n-1] == ' ' || s[n-1] == '\t' || s[n-1] == '\r' || s[n-1] == '\n'))
        s[--n] = 0;
}

static void str_copy(char *dst, size_t cap, const char *src) {
    if (cap == 0) return;
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}

// Convert UTF-8 to a freshly allocated wide string (caller frees).
static wchar_t *u8tow(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

// Replace literal "\n" escapes in help text with real newlines.
static void unescape_newlines(char *s) {
    char *r = s, *w = s;
    while (*r) {
        if (r[0] == '\\' && r[1] == 'n') { *w++ = '\n'; r += 2; }
        else *w++ = *r++;
    }
    *w = 0;
}

// ---------------------------------------------------------------------------
// editor_conf.txt parser  (mirrors conf.lua)
// ---------------------------------------------------------------------------

static char *read_file(const char *path, long *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t rd = fread(buf, 1, (size_t)len, f);
    buf[rd] = 0;
    fclose(f);
    if (out_len) *out_len = (long)rd;
    // strip UTF-8 BOM
    if (rd >= 3 && (unsigned char)buf[0] == 0xEF && (unsigned char)buf[1] == 0xBB
        && (unsigned char)buf[2] == 0xBF)
        memmove(buf, buf + 3, rd - 3 + 1);
    return buf;
}

// Apply a finished section's accumulated key/value pairs onto a Setting.
static void finalize_section(Setting *s) {
    if (s->help[0]) unescape_newlines(s->help);
    if (s->is_option && s->def[0]) str_copy(s->value, sizeof(s->value), s->def);
    else if (!s->is_option) str_copy(s->value, sizeof(s->value), s->def);
}

static int parse_editor_conf(const char *path) {
    char *buf = read_file(path, NULL);
    if (!buf) return 0;

    g_nsettings = 0;
    Setting cur;
    memset(&cur, 0, sizeof(cur));
    int has_name = 0;

    char *line = buf;
    while (1) {
        char *nl = strpbrk(line, "\n");
        char saved = 0;
        if (nl) { saved = *nl; *nl = 0; }

        char tmp[2600];
        str_copy(tmp, sizeof(tmp), line);
        str_trim(tmp);

        if (tmp[0] == '#') {
            // comment, ignore
        } else if (tmp[0] == 0) {
            // blank line ends a section
            if (has_name && g_nsettings < MAX_SETTINGS) {
                finalize_section(&cur);
                g_settings[g_nsettings++] = cur;
            }
            memset(&cur, 0, sizeof(cur));
            has_name = 0;
        } else {
            char *eq = strchr(tmp, '=');
            if (eq) {
                *eq = 0;
                char key[64]; str_copy(key, sizeof(key), tmp); str_trim(key);
                char val[2400]; str_copy(val, sizeof(val), eq + 1); str_trim(val);

                if      (!strcmp(key, "name"))      { str_copy(cur.name, sizeof(cur.name), val); has_name = 1; }
                else if (!strcmp(key, "file"))      str_copy(cur.file, sizeof(cur.file), val);
                else if (!strcmp(key, "directory")) str_copy(cur.directory, sizeof(cur.directory), val);
                else if (!strcmp(key, "help"))      str_copy(cur.help, sizeof(cur.help), val);
                else if (!strcmp(key, "url"))       str_copy(cur.url, sizeof(cur.url), val);
                else if (!strcmp(key, "type"))      str_copy(cur.type, sizeof(cur.type), val);
                else if (!strcmp(key, "default"))   str_copy(cur.def, sizeof(cur.def), val);
                else if (!strcmp(key, "option")) {
                    cur.is_option = 1;
                    if (cur.n_options < MAX_OPTIONS) {
                        Option *o = &cur.options[cur.n_options++];
                        char *sp = strchr(val, ' ');
                        if (sp) {
                            *sp = 0;
                            str_copy(o->name, sizeof(o->name), val);
                            char *h = sp + 1; str_trim(h);
                            str_copy(o->help, sizeof(o->help), h);
                        } else {
                            str_copy(o->name, sizeof(o->name), val);
                        }
                    }
                }
            }
        }

        if (!nl) break;
        *nl = saved;
        line = nl + 1;
    }
    // trailing section (file may not end with blank line)
    if (has_name && g_nsettings < MAX_SETTINGS) {
        finalize_section(&cur);
        g_settings[g_nsettings++] = cur;
    }

    free(buf);
    return g_nsettings;
}

// ---------------------------------------------------------------------------
// mpv.conf value loader  (simplified read; full comment-preserving write later)
// ---------------------------------------------------------------------------

static Setting *find_setting(const char *name, const char *file) {
    for (int i = 0; i < g_nsettings; i++)
        if (!strcmp(g_settings[i].name, name) && !strcmp(g_settings[i].file, file))
            return &g_settings[i];
    return NULL;
}

static void load_conf_values(const char *path, const char *file_tag) {
    char *buf = read_file(path, NULL);
    if (!buf) return;
    char *line = buf;
    while (1) {
        char *nl = strpbrk(line, "\n");
        char saved = 0; if (nl) { saved = *nl; *nl = 0; }

        char tmp[1024]; str_copy(tmp, sizeof(tmp), line); str_trim(tmp);
        if (tmp[0] && tmp[0] != '#' && tmp[0] != '[') {
            char *eq = strchr(tmp, '=');
            if (eq) {
                *eq = 0;
                char key[96]; str_copy(key, sizeof(key), tmp); str_trim(key);
                char val[256]; str_copy(val, sizeof(val), eq + 1); str_trim(val);
                // strip an inline comment: a '#' preceded by whitespace (so a
                // color value like #FFFFFF is not mistaken for a comment)
                for (size_t p = 1; val[p]; p++) {
                    if (val[p] == '#' && (val[p-1] == ' ' || val[p-1] == '\t')) {
                        val[p] = 0; str_trim(val); break;
                    }
                }
                // strip leading dashes and surrounding quotes
                char *k = key; while (*k == '-') k++;
                size_t vl = strlen(val);
                if (vl >= 2 && ((val[0] == '"' && val[vl-1] == '"') ||
                                (val[0] == '\'' && val[vl-1] == '\''))) {
                    val[vl-1] = 0; memmove(val, val + 1, vl - 1);
                }
                Setting *s = find_setting(k, file_tag);
                if (s) str_copy(s->value, sizeof(s->value), val);
            }
        }
        if (!nl) break;
        *nl = saved; line = nl + 1;
    }
    free(buf);
}

// ---------------------------------------------------------------------------
// Win32 UI
// ---------------------------------------------------------------------------

static HWND g_tree, g_list, g_desc, g_search;
static HWND g_editlabel, g_combo, g_edit, g_pick;
static HFONT g_font;
static int  g_cur_setting = -1;   // index into g_settings of the selected row

enum { ID_TREE = 1001, ID_LIST, ID_DESC, ID_SEARCH, ID_COMBO, ID_EDIT, ID_PICK };

// Insert a category path (split on '/') into the tree, returning the leaf node.
static HTREEITEM tree_insert_path(const char *path) {
    char parts[160]; str_copy(parts, sizeof(parts), path);
    HTREEITEM parent = TVI_ROOT;
    char *seg = strtok(parts, "/");
    while (seg) {
        // find existing child named seg under parent
        HTREEITEM child = (parent == TVI_ROOT) ? TreeView_GetRoot(g_tree)
                                               : TreeView_GetChild(g_tree, parent);
        HTREEITEM found = NULL;
        for (; child; child = TreeView_GetNextSibling(g_tree, child)) {
            wchar_t buf[160]; TVITEM it = {0};
            it.mask = TVIF_TEXT; it.hItem = child; it.pszText = buf; it.cchTextMax = 160;
            TreeView_GetItem(g_tree, &it);
            wchar_t *wseg = u8tow(seg);
            int eq = (wcscmp(buf, wseg) == 0);
            free(wseg);
            if (eq) { found = child; break; }
        }
        if (!found) {
            wchar_t *wseg = u8tow(seg);
            TVINSERTSTRUCT is = {0};
            is.hParent = parent;
            is.hInsertAfter = TVI_LAST;
            is.item.mask = TVIF_TEXT;
            is.item.pszText = wseg;
            found = TreeView_InsertItem(g_tree, &is);
            free(wseg);
        }
        parent = found;
        seg = strtok(NULL, "/");
    }
    return parent;
}

static void build_tree(void) {
    for (int i = 0; i < g_nsettings; i++)
        if (g_settings[i].directory[0])
            tree_insert_path(g_settings[i].directory);
}

// Full category path of a tree item ("Video/libplacebo/Scaling").
static void tree_item_path(HTREEITEM item, char *out, size_t cap) {
    char stack[16][96]; int depth = 0;
    while (item && depth < 16) {
        wchar_t buf[96]; TVITEM it = {0};
        it.mask = TVIF_TEXT; it.hItem = item; it.pszText = buf; it.cchTextMax = 96;
        TreeView_GetItem(g_tree, &it);
        WideCharToMultiByte(CP_UTF8, 0, buf, -1, stack[depth], 96, NULL, NULL);
        depth++;
        item = TreeView_GetParent(g_tree, item);
    }
    out[0] = 0;
    for (int i = depth - 1; i >= 0; i--) {
        strncat(out, stack[i], cap - strlen(out) - 1);
        if (i > 0) strncat(out, "/", cap - strlen(out) - 1);
    }
}

// Map list rows back to settings.
static int g_list_map[MAX_SETTINGS];
static int g_list_count;

static void show_description(int idx);
static void on_select_setting(int list_index);
static void update_list_line(int list_index);

static void list_add_setting(int idx) {
    Setting *s = &g_settings[idx];
    char line[400];
    _snprintf(line, sizeof(line), "%s = %s", s->name,
              s->value[0] ? s->value : "(unset)");
    line[sizeof(line)-1] = 0;
    wchar_t *w = u8tow(line);
    SendMessageW(g_list, LB_ADDSTRING, 0, (LPARAM)w);
    free(w);
    g_list_map[g_list_count++] = idx;
}

static void show_category(const char *path) {
    SendMessageW(g_list, LB_RESETCONTENT, 0, 0);
    g_list_count = 0;
    for (int i = 0; i < g_nsettings; i++)
        if (!strcmp(g_settings[i].directory, path))
            list_add_setting(i);
    if (g_list_count > 0) {
        SendMessageW(g_list, LB_SETCURSEL, 0, 0);
        on_select_setting(0);
    } else {
        on_select_setting(-1);
    }
}

static void show_search(const char *query) {
    SendMessageW(g_list, LB_RESETCONTENT, 0, 0);
    g_list_count = 0;
    if (!query[0]) return;
    char q[128]; str_copy(q, sizeof(q), query);
    for (char *p = q; *p; p++) *p = (char)tolower(*p);
    for (int i = 0; i < g_nsettings; i++) {
        char hay[2400];
        _snprintf(hay, sizeof(hay), "%s %s %s", g_settings[i].name,
                  g_settings[i].directory, g_settings[i].help);
        for (char *p = hay; *p; p++) *p = (char)tolower(*p);
        if (strstr(hay, q)) list_add_setting(i);
    }
    if (g_list_count > 0) {
        SendMessageW(g_list, LB_SETCURSEL, 0, 0);
        on_select_setting(0);
    } else {
        on_select_setting(-1);
    }
}

static void show_description(int idx) {
    if (idx < 0 || idx >= g_nsettings) { SetWindowTextW(g_desc, L""); return; }
    Setting *s = &g_settings[idx];
    char buf[3200];
    int n = _snprintf(buf, sizeof(buf), "%s\r\n\r\n%s", s->name, s->help);
    // normalise \n to \r\n for the edit control
    char out[4096]; int j = 0;
    for (int i = 0; buf[i] && j < (int)sizeof(out) - 2; i++) {
        if (buf[i] == '\n' && (i == 0 || buf[i-1] != '\r')) { out[j++] = '\r'; out[j++] = '\n'; }
        else out[j++] = buf[i];
    }
    out[j] = 0;
    char tail[700];
    _snprintf(tail, sizeof(tail), "\r\n\r\ndefault: %s    file: %s%s%s",
              s->def[0] ? s->def : "(none)", s->file,
              s->url[0] ? "\r\n" : "", s->url);
    strncat(out, tail, sizeof(out) - strlen(out) - 1);
    wchar_t *w = u8tow(out);
    SetWindowTextW(g_desc, w);
    free(w);
    (void)n;
}

// Rewrite a single list row to reflect its setting's current value.
static void update_list_line(int list_index) {
    if (list_index < 0 || list_index >= g_list_count) return;
    Setting *s = &g_settings[g_list_map[list_index]];
    char line[400];
    _snprintf(line, sizeof(line), "%s = %s", s->name, s->value[0] ? s->value : "(unset)");
    line[sizeof(line)-1] = 0;
    wchar_t *w = u8tow(line);
    SendMessageW(g_list, LB_DELETESTRING, list_index, 0);
    SendMessageW(g_list, LB_INSERTSTRING, list_index, (LPARAM)w);
    free(w);
    SendMessageW(g_list, LB_SETCURSEL, list_index, 0);
}

// Show the editor controls appropriate for the selected setting.
static void on_select_setting(int list_index) {
    if (list_index < 0 || list_index >= g_list_count) {
        g_cur_setting = -1;
        ShowWindow(g_combo, SW_HIDE);
        ShowWindow(g_edit, SW_HIDE);
        ShowWindow(g_pick, SW_HIDE);
        SetWindowTextW(g_editlabel, L"");
        show_description(-1);
        return;
    }

    int idx = g_list_map[list_index];
    g_cur_setting = idx;
    Setting *s = &g_settings[idx];

    wchar_t *wname = u8tow(s->name);
    SetWindowTextW(g_editlabel, wname);
    free(wname);

    if (s->is_option) {
        SendMessageW(g_combo, CB_RESETCONTENT, 0, 0);
        int sel = -1;
        for (int i = 0; i < s->n_options; i++) {
            wchar_t *wo = u8tow(s->options[i].name);
            SendMessageW(g_combo, CB_ADDSTRING, 0, (LPARAM)wo);
            free(wo);
            if (!strcmp(s->options[i].name, s->value)) sel = i;
        }
        SendMessageW(g_combo, CB_SETCURSEL, sel, 0);
        ShowWindow(g_combo, SW_SHOW);
        ShowWindow(g_edit, SW_HIDE);
        ShowWindow(g_pick, SW_HIDE);
    } else {
        wchar_t *wv = u8tow(s->value);
        SetWindowTextW(g_edit, wv);
        free(wv);
        ShowWindow(g_edit, SW_SHOW);
        ShowWindow(g_combo, SW_HIDE);
        // color / folder settings get a "…" picker button
        ShowWindow(g_pick, (!strcmp(s->type, "color") || !strcmp(s->type, "folder")) ? SW_SHOW : SW_HIDE);
    }

    show_description(idx);
}

// Commit the option combobox selection to the current setting.
static void commit_combo(void) {
    if (g_cur_setting < 0) return;
    Setting *s = &g_settings[g_cur_setting];
    int sel = (int)SendMessageW(g_combo, CB_GETCURSEL, 0, 0);
    if (sel < 0 || sel >= s->n_options) return;
    str_copy(s->value, sizeof(s->value), s->options[sel].name);
    int li = (int)SendMessageW(g_list, LB_GETCURSEL, 0, 0);
    update_list_line(li);
}

// Commit the edit field text to the current setting.
static void commit_edit(void) {
    if (g_cur_setting < 0) return;
    Setting *s = &g_settings[g_cur_setting];
    if (s->is_option) return;
    wchar_t wbuf[512]; GetWindowTextW(g_edit, wbuf, 512);
    char val[256]; WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, val, sizeof(val), NULL, NULL);
    if (strcmp(val, s->value) != 0) {
        str_copy(s->value, sizeof(s->value), val);
        int li = (int)SendMessageW(g_list, LB_GETCURSEL, 0, 0);
        update_list_line(li);
    }
}

// Color / folder picker for the "…" button.
static void pick_value(HWND hwnd) {
    if (g_cur_setting < 0) return;
    Setting *s = &g_settings[g_cur_setting];

    if (!strcmp(s->type, "color")) {
        static COLORREF custom[16];
        unsigned r = 255, g = 255, b = 255;
        sscanf(s->value, "#%2x%2x%2x", &r, &g, &b);  // best-effort parse of #RRGGBB
        CHOOSECOLORW cc = { sizeof(cc) };
        cc.hwndOwner = hwnd;
        cc.lpCustColors = custom;
        cc.rgbResult = RGB(r, g, b);
        cc.Flags = CC_FULLOPEN | CC_RGBINIT;
        if (ChooseColorW(&cc)) {
            char hex[16];
            _snprintf(hex, sizeof(hex), "#%02X%02X%02X",
                      GetRValue(cc.rgbResult), GetGValue(cc.rgbResult), GetBValue(cc.rgbResult));
            str_copy(s->value, sizeof(s->value), hex);
            wchar_t *w = u8tow(hex); SetWindowTextW(g_edit, w); free(w);
            update_list_line((int)SendMessageW(g_list, LB_GETCURSEL, 0, 0));
        }
    } else if (!strcmp(s->type, "folder")) {
        BROWSEINFOW bi = {0};
        bi.hwndOwner = hwnd;
        bi.lpszTitle = L"Select folder";
        bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;
        LPITEMIDLIST pidl = SHBrowseForFolderW(&bi);
        if (pidl) {
            wchar_t path[MAX_PATH];
            if (SHGetPathFromIDListW(pidl, path)) {
                char val[512]; WideCharToMultiByte(CP_UTF8, 0, path, -1, val, sizeof(val), NULL, NULL);
                str_copy(s->value, sizeof(s->value), val);
                SetWindowTextW(g_edit, path);
                update_list_line((int)SendMessageW(g_list, LB_GETCURSEL, 0, 0));
            }
            CoTaskMemFree(pidl);
        }
    }
}

static void layout(HWND hwnd) {
    RECT rc; GetClientRect(hwnd, &rc);
    int W = rc.right, H = rc.bottom;
    int treeW = 240, pad = 8, searchH = 26;
    MoveWindow(g_search, treeW + pad*2, pad, W - treeW - pad*3, searchH, TRUE);
    MoveWindow(g_tree, pad, pad, treeW, H - pad*2, TRUE);
    int rx = treeW + pad*2;
    int rw = W - rx - pad;
    int listTop = pad + searchH + pad;
    int editH = 26;
    int descH = (H - listTop) / 3;
    int listH = H - listTop - editH - descH - pad*3;
    if (listH < 60) listH = 60;

    MoveWindow(g_list, rx, listTop, rw, listH, TRUE);

    int editY = listTop + listH + pad;
    int labelW = 130;
    MoveWindow(g_editlabel, rx, editY + 4, labelW, editH, TRUE);
    int ctrlX = rx + labelW;
    int ctrlW = rw - labelW;
    int pickW = 30;
    // combo and edit share the same slot; pick button (if shown) sits at the right
    MoveWindow(g_combo, ctrlX, editY, ctrlW, 200, TRUE);
    int editFieldW = IsWindowVisible(g_pick) ? (ctrlW - pickW - 4) : ctrlW;
    MoveWindow(g_edit, ctrlX, editY, editFieldW, editH, TRUE);
    MoveWindow(g_pick, ctrlX + ctrlW - pickW, editY, pickW, editH, TRUE);

    MoveWindow(g_desc, rx, editY + editH + pad, rw, H - (editY + editH + pad) - pad, TRUE);
}

// ---------------------------------------------------------------------------
// Saving + live-apply
// ---------------------------------------------------------------------------

static char g_ipc_pipe[512];

// Escape a value the way mpv.conf expects (mirrors conffile.lua escape_value).
static void escape_value(const char *v, char *out, size_t cap) {
    int needs = strchr(v, '#') || v[0] == '%' || v[0] == ' ' ||
                (v[0] && v[strlen(v)-1] == ' ') || strchr(v, '\'') || strchr(v, '"');
    if (strchr(v, '\'')) _snprintf(out, cap, "\"%s\"", v);
    else if (needs)      _snprintf(out, cap, "'%s'", v);
    else                 _snprintf(out, cap, "%s", v);
    out[cap-1] = 0;
}

// Rewrite a conf file: keep all existing lines/comments, update lines whose key
// matches a non-default setting, and append any new non-default settings.
static void save_conf(const char *path, const char *file_tag) {
    // gather the file's settings that should be written (value != default)
    char *buf = read_file(path, NULL);

    FILE *out = fopen(path, "wb");
    if (!out) { free(buf); return; }

    char written[MAX_SETTINGS]; memset(written, 0, sizeof(written));

    // pass over existing lines, updating matched keys in place
    if (buf) {
        char *line = buf;
        while (1) {
            char *nl = strpbrk(line, "\n");
            // skip the empty segment produced after the file's final newline
            if (!nl && line[0] == 0) break;
            char saved = 0; if (nl) { saved = *nl; *nl = 0; }

            // drop a trailing '\r' so CRLF files don't grow stray characters
            size_t ll = strlen(line);
            if (ll && line[ll-1] == '\r') line[ll-1] = 0;

            char trimmed[1024]; str_copy(trimmed, sizeof(trimmed), line); str_trim(trimmed);
            int handled = 0;
            if (trimmed[0] && trimmed[0] != '#' && trimmed[0] != '[') {
                char *eq = strchr(trimmed, '=');
                if (eq) {
                    char key[96]; size_t kl = (size_t)(eq - trimmed);
                    if (kl >= sizeof(key)) kl = sizeof(key)-1;
                    memcpy(key, trimmed, kl); key[kl] = 0; str_trim(key);
                    char *k = key; while (*k == '-') k++;
                    for (int i = 0; i < g_nsettings; i++) {
                        Setting *s = &g_settings[i];
                        if (!strcmp(s->file, file_tag) && !strcmp(s->name, k)) {
                            written[i] = 1;
                            if (strcmp(s->value, s->def) != 0 && s->value[0]) {
                                char ev[300]; escape_value(s->value, ev, sizeof(ev));
                                fprintf(out, "%s=%s\n", s->name, ev);
                            }
                            // value == default: drop the line (mpv.net behaviour)
                            handled = 1;
                            break;
                        }
                    }
                }
            }
            if (!handled) fprintf(out, "%s\n", line);

            if (!nl) break;
            *nl = saved; line = nl + 1;
        }
        free(buf);
    }

    // append new non-default settings not already present
    for (int i = 0; i < g_nsettings; i++) {
        Setting *s = &g_settings[i];
        if (!written[i] && !strcmp(s->file, file_tag) &&
            s->value[0] && strcmp(s->value, s->def) != 0) {
            char ev[300]; escape_value(s->value, ev, sizeof(ev));
            fprintf(out, "%s=%s\n", s->name, ev);
        }
    }
    fclose(out);
}

// Send changed mpv settings to a running mpv over its JSON IPC pipe.
static void ipc_apply(void) {
    if (!g_ipc_pipe[0]) return;
    wchar_t *wpipe = u8tow(g_ipc_pipe);
    HANDLE h = CreateFileW(wpipe, GENERIC_WRITE, 0, NULL, OPEN_EXISTING, 0, NULL);
    free(wpipe);
    if (h == INVALID_HANDLE_VALUE) return;
    for (int i = 0; i < g_nsettings; i++) {
        Setting *s = &g_settings[i];
        if (strcmp(s->file, "mpv") != 0) continue;
        if (strcmp(s->value, s->start) == 0) continue;
        char json[600];
        int n = _snprintf(json, sizeof(json),
            "{\"command\":[\"set_property\",\"%s\",\"%s\"]}\n", s->name, s->value);
        DWORD wr; WriteFile(h, json, (DWORD)n, &wr, NULL);
    }
    CloseHandle(h);
}

static void save_all(const char *mpv_conf, const char *encore_conf) {
    if (mpv_conf[0])    save_conf(mpv_conf, "mpv");
    if (encore_conf[0]) save_conf(encore_conf, "encore");
    ipc_apply();
}

// conf paths captured from argv for use at close time
static char g_mpv_conf[1024], g_encore_conf[1024];

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE: {
        g_font = CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
            0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");

        g_search = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
            0,0,0,0, hwnd, (HMENU)ID_SEARCH, NULL, NULL);
        g_tree = CreateWindowExW(WS_EX_CLIENTEDGE, WC_TREEVIEW, L"",
            WS_CHILD | WS_VISIBLE | TVS_HASLINES | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_SHOWSELALWAYS,
            0,0,0,0, hwnd, (HMENU)ID_TREE, NULL, NULL);
        g_list = CreateWindowExW(WS_EX_CLIENTEDGE, L"LISTBOX", L"",
            WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOTIFY,
            0,0,0,0, hwnd, (HMENU)ID_LIST, NULL, NULL);
        g_desc = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_READONLY,
            0,0,0,0, hwnd, (HMENU)ID_DESC, NULL, NULL);
        g_editlabel = CreateWindowExW(0, L"STATIC", L"",
            WS_CHILD | WS_VISIBLE | SS_LEFTNOWORDWRAP,
            0,0,0,0, hwnd, NULL, NULL, NULL);
        g_combo = CreateWindowExW(0, L"COMBOBOX", L"",
            WS_CHILD | CBS_DROPDOWNLIST | WS_VSCROLL,
            0,0,0,0, hwnd, (HMENU)ID_COMBO, NULL, NULL);
        g_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | ES_AUTOHSCROLL,
            0,0,0,0, hwnd, (HMENU)ID_EDIT, NULL, NULL);
        g_pick = CreateWindowExW(0, L"BUTTON", L"…",
            WS_CHILD | BS_PUSHBUTTON,
            0,0,0,0, hwnd, (HMENU)ID_PICK, NULL, NULL);

        SendMessageW(g_search, WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_tree,   WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_list,   WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_desc,   WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_editlabel, WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_combo,  WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_edit,   WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_pick,   WM_SETFONT, (WPARAM)g_font, TRUE);
        SendMessageW(g_search, EM_SETCUEBANNER, TRUE, (LPARAM)L"Search all settings…");

        build_tree();
        // Select a category up front so the window opens populated.
        {
            HTREEITEM root = TreeView_GetRoot(g_tree);
            // jump to "Video" if present (has loaded values to show), else first
            HTREEITEM pick = root;
            for (HTREEITEM it = root; it; it = TreeView_GetNextSibling(g_tree, it)) {
                wchar_t b[64]; TVITEM t = {0};
                t.mask = TVIF_TEXT; t.hItem = it; t.pszText = b; t.cchTextMax = 64;
                TreeView_GetItem(g_tree, &t);
                if (wcscmp(b, L"Video") == 0) { pick = it; break; }
            }
            if (pick) TreeView_SelectItem(g_tree, pick);
        }
        return 0;
    }
    case WM_SIZE: layout(hwnd); return 0;
    case WM_NOTIFY: {
        LPNMHDR nh = (LPNMHDR)lp;
        if (nh->idFrom == ID_TREE &&
            (nh->code == TVN_SELCHANGEDW || nh->code == TVN_SELCHANGEDA)) {
            LPNMTREEVIEW tv = (LPNMTREEVIEW)lp;
            char path[200]; tree_item_path(tv->itemNew.hItem, path, sizeof(path));
            show_category(path);
        }
        return 0;
    }
    case WM_COMMAND: {
        int id = LOWORD(wp), code = HIWORD(wp);
        if (id == ID_LIST && code == LBN_SELCHANGE) {
            int sel = (int)SendMessageW(g_list, LB_GETCURSEL, 0, 0);
            on_select_setting(sel);
        } else if (id == ID_COMBO && code == CBN_SELCHANGE) {
            commit_combo();
        } else if (id == ID_EDIT && code == EN_KILLFOCUS) {
            commit_edit();
        } else if (id == ID_PICK && code == BN_CLICKED) {
            pick_value(hwnd);
        } else if (id == ID_SEARCH && code == EN_CHANGE) {
            wchar_t wq[128]; GetWindowTextW(g_search, wq, 128);
            char q[256]; WideCharToMultiByte(CP_UTF8, 0, wq, -1, q, sizeof(q), NULL, NULL);
            if (q[0]) {
                show_search(q);
            } else {
                // cleared search: restore the selected category's settings
                HTREEITEM sel = TreeView_GetSelection(g_tree);
                if (sel) {
                    char path[200]; tree_item_path(sel, path, sizeof(path));
                    show_category(path);
                } else {
                    show_category("");
                }
            }
        }
        return 0;
    }
    case WM_CLOSE:
        commit_edit();                 // flush any value typed but not yet committed
        save_all(g_mpv_conf, g_encore_conf);
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY: PostQuitMessage(0); return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, PWSTR cmd, int show) {
    (void)hp; (void)show;

    // args: mpv-settings.exe [editor_conf] [mpv.conf] [encore.conf]
    int argc; LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    char editor_conf[1024] = "editor_conf.txt";
    char selftest[256] = "";
    // positional: [editor_conf] [mpv.conf] [encore.conf]; options: --ipc=PIPE, --set=file:name=value
    int pos = 0;
    for (int i = 1; i < argc; i++) {
        char a[1024]; WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, a, sizeof(a), NULL, NULL);
        if (!strncmp(a, "--ipc=", 6))      str_copy(g_ipc_pipe, sizeof(g_ipc_pipe), a + 6);
        else if (!strncmp(a, "--set=", 6)) str_copy(selftest, sizeof(selftest), a + 6);
        else {
            if      (pos == 0) str_copy(editor_conf, sizeof(editor_conf), a);
            else if (pos == 1) str_copy(g_mpv_conf, sizeof(g_mpv_conf), a);
            else if (pos == 2) str_copy(g_encore_conf, sizeof(g_encore_conf), a);
            pos++;
        }
    }

    if (!parse_editor_conf(editor_conf)) {
        MessageBoxW(NULL, L"Could not read editor_conf.txt", L"mpv-settings", MB_ICONERROR);
        return 1;
    }
    if (g_mpv_conf[0])    load_conf_values(g_mpv_conf, "mpv");
    if (g_encore_conf[0]) load_conf_values(g_encore_conf, "encore");
    for (int i = 0; i < g_nsettings; i++)
        str_copy(g_settings[i].start, sizeof(g_settings[i].start), g_settings[i].value);

    // headless self-test: --set=file:name=value  -> apply, save, exit (no UI)
    if (selftest[0]) {
        char *colon = strchr(selftest, ':');
        char *eq = strchr(selftest, '=');
        if (colon && eq && colon < eq) {
            *colon = 0; *eq = 0;   // selftest="file", colon+1="name", eq+1="value"
            Setting *s = find_setting(colon + 1, selftest);
            if (s) str_copy(s->value, sizeof(s->value), eq + 1);
        }
        save_all(g_mpv_conf, g_encore_conf);
        return 0;
    }

    INITCOMMONCONTROLSEX ic = { sizeof(ic), ICC_TREEVIEW_CLASSES | ICC_STANDARD_CLASSES };
    InitCommonControlsEx(&ic);

    WNDCLASSEXW wc = { sizeof(wc) };
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hi;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = L"MpvSettingsWindow";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, wc.lpszClassName, L"mpv Settings",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 940, 660,
        NULL, NULL, hi, NULL);
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);

    MSG m;
    while (GetMessageW(&m, NULL, 0, 0)) {
        if (!IsDialogMessageW(hwnd, &m)) {
            TranslateMessage(&m);
            DispatchMessageW(&m);
        }
    }
    return 0;
}
