#!/bin/bash
#############################################
# Cipi — what the API, the panel and the clients may put in an app's nginx.
#
#     _nginx_custom_lint <app> < directives
#
# Reads an app's custom nginx directives and says whether every one of them is
# in the list below. Exit 0 when they are; 1 with one line per problem
# ("line N: ...") when they are not; 2 when called wrongly.
#
# `cipi nginx edit|set <app>` run as root at the server take the whole language:
# root can write the file anyway. This check is for what arrives through
# `cipi api` (SUDO_USER=www-data), where a token must not become root. With
# nginx directives it would: `access_log` and `error_log` open any path as
# root, `include` and the ssl_* file directives read any file as root,
# `server_name` takes another app's domain, `listen` opens a port, a `*_pass`
# reaches another app's PHP socket or a database on the loopback. So this is a
# list of what is allowed, not of what is refused: a directive nobody thought
# about stays out. Reverse proxies and redirects have their own commands
# (`cipi proxy`, `cipi redirect`), which check where they point.
#
# The reader follows nginx's own (ngx_conf_read_token): whitespace is space,
# tab, CR, LF; a comment starts with # where a word could start; a word in
# quotes ends at the same quote, a backslash takes the next character; a bare
# word ends at whitespace, `;` or `{`, except the `{` of `${name}`. A directive
# is looked up by the word nginx would see, after unescaping.
#
# Python, kept in a shell library: every lib/*.sh reaches a server at
# `cipi self-update`, whatever version does the update.
#############################################

# Problems of the text on stdin, one per line; 0 = none, 1 = some, 2 = misuse.
_nginx_custom_lint() {
    local app="${1:-}" tmp rc=0
    command -v python3 >/dev/null 2>&1 || { echo "python3 is required to check nginx directives"; return 2; }
    tmp=$(mktemp) || return 2
    cat > "$tmp"
    python3 - "$app" "$tmp" <<'CIPINGINXLINT' || rc=$?
import re
import sys

MAX_BYTES = 32768

# Directives allowed in server, location, `if` and limit_except context.
ALLOWED = set("""
location if limit_except
return rewrite set try_files error_page internal
add_header add_trailer expires etag if_modified_since
gzip gzip_types gzip_min_length gzip_comp_level gzip_vary gzip_proxied gzip_static
gzip_disable gzip_buffers gzip_http_version
client_max_body_size client_body_buffer_size client_body_timeout client_header_timeout
send_timeout keepalive_timeout keepalive_requests
limit_rate limit_rate_after
allow deny satisfy auth_basic
autoindex autoindex_exact_size autoindex_localtime autoindex_format
index charset default_type types
log_not_found log_subrequest access_log
open_file_cache open_file_cache_valid open_file_cache_min_uses open_file_cache_errors
sendfile tcp_nopush tcp_nodelay
max_ranges merge_slashes absolute_redirect port_in_redirect server_name_in_redirect
server_tokens recursive_error_pages chunked_transfer_encoding ignore_invalid_headers
underscores_in_headers large_client_header_buffers disable_symlinks
root alias
sub_filter sub_filter_once sub_filter_types sub_filter_last_modified
valid_referers
fastcgi_read_timeout fastcgi_send_timeout fastcgi_connect_timeout fastcgi_buffers
fastcgi_buffer_size fastcgi_busy_buffers_size fastcgi_hide_header fastcgi_intercept_errors
proxy_read_timeout proxy_send_timeout proxy_connect_timeout proxy_buffers
proxy_buffer_size proxy_busy_buffers_size proxy_hide_header proxy_intercept_errors
""".split())

# Blocks whose body is directives again; `types` holds a table, not directives.
NESTING = {"location", "if", "limit_except"}
TABLES = {"types"}

WHY = {
    "access_log": "only `access_log off;` — a path is opened by nginx as root",
    "error_log": "a path is opened by nginx as root",
    "include": "it reads any file as root",
    "server_name": "the app's domains are set with cipi alias",
    "listen": "the ports of an app are Cipi's",
    "proxy_pass": "use cipi proxy add, which checks where it points",
    "fastcgi_pass": "it could reach another app's PHP",
    "ssl_certificate": "certificates are Cipi's (cipi ssl)",
    "ssl_certificate_key": "certificates are Cipi's (cipi ssl)",
    "auth_basic_user_file": "use cipi basicauth",
}


class Problem(Exception):
    pass


def tokens(text):
    """Yield (kind, word, line): kind is 'word', ';', '{' or '}'."""
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            if c == "\n":
                line += 1
            i += 1
            continue
        if c == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c in ";{}":
            yield (c, c, line)
            i += 1
            continue
        start_line = line
        raw = []
        if c in "\"'":
            quote = c
            i += 1
            while True:
                if i >= n:
                    raise Problem("line %d: the quote is never closed" % start_line)
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    raw.append(ch + text[i + 1])
                    if text[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if ch == quote:
                    i += 1
                    break
                if ch == "\n":
                    line += 1
                raw.append(ch)
                i += 1
            if i < n and text[i] not in " \t\r\n;{)":
                raise Problem("line %d: text right after a closing quote" % line)
        else:
            while i < n:
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    raw.append(ch + text[i + 1])
                    if text[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if ch in " \t\r\n;":
                    break
                if ch == "{":
                    if raw and raw[-1] == "$":      # ${name}
                        raw.append(ch)
                        i += 1
                        continue
                    break
                raw.append(ch)
                i += 1
        yield ("word", unescape(raw), start_line)


def unescape(parts):
    out = []
    for p in parts:
        if len(p) == 2 and p[0] == "\\":
            out.append({'"': '"', "'": "'", "\\": "\\", "t": "\t", "r": "\r", "n": "\n"}.get(p[1], p))
        else:
            out.append(p)
    return "".join(out)


def check_args(app, name, args, line, problems):
    def bad(msg):
        problems.append("line %d: %s" % (line, msg))

    if name == "access_log" and args != ["off"]:
        bad("access_log: %s" % WHY["access_log"])
    elif name == "auth_basic" and args != ["off"]:
        bad("auth_basic: only `auth_basic off;` — passwords are set with cipi basicauth")
    elif name in ("root", "alias"):
        home = "/home/%s/" % app
        ok = (len(args) == 1 and args[0].startswith(home)
              and re.match(r"^[A-Za-z0-9._/@+-]+$", args[0]) is not None
              and ".." not in args[0].split("/"))
        if not ok:
            bad("%s: a path under %s, without variables or `..`" % (name, home))
    for a in args:
        if any(ord(ch) < 32 and ch != "\t" for ch in a):
            bad("%s: a control character in an argument" % name)
            break


def walk(app, stream, depth, problems):
    """Read directives until the block (or the file) ends."""
    while True:
        try:
            kind, word, line = next(stream)
        except StopIteration:
            if depth:
                raise Problem("a block is never closed: `}` is missing")
            return
        if kind == "}":
            if not depth:
                raise Problem("line %d: `}` closes nothing" % line)
            return
        if kind != "word":
            raise Problem("line %d: `%s` where a directive should start" % (line, word))
        name, args, end = word, [], None
        for kind2, word2, _line2 in stream:
            if kind2 == "word":
                args.append(word2)
                continue
            end = kind2
            break
        if end is None:
            raise Problem("line %d: `%s` has no `;` at its end" % (line, name))
        if end == "}":
            raise Problem("line %d: `%s` has no `;` at its end" % (line, name))
        if not re.match(r"^[a-z][a-z0-9_]*$", name) or name not in ALLOWED:
            shown = name if re.match(r"^[A-Za-z0-9_]{1,40}$", name) else "that directive"
            why = WHY.get(name)
            problems.append("line %d: `%s` is not allowed from the API%s" % (line, shown, " — " + why if why else ""))
        else:
            check_args(app, name, args, line, problems)
        if end == "{":
            if name in TABLES:
                skip_table(stream, line)
            elif name in NESTING or name not in ALLOWED:
                walk(app, stream, depth + 1, problems)
            else:
                problems.append("line %d: `%s` takes no block" % (line, name))
                walk(app, stream, depth + 1, problems)
        elif name in NESTING or name in TABLES:
            problems.append("line %d: `%s` needs a block" % (line, name))


def skip_table(stream, line):
    for kind, _word, _line in stream:
        if kind == "}":
            return
        if kind == "{":
            raise Problem("line %d: a block inside `types`" % line)
    raise Problem("line %d: `types` is never closed" % line)


def lint(app, text):
    problems = []
    if len(text.encode("utf-8", "surrogateescape")) > MAX_BYTES:
        return ["the text is too long (%d KB at most)" % (MAX_BYTES // 1024)]
    if any((ord(ch) < 32 and ch not in "\t\r\n") or ord(ch) == 127 for ch in text):
        return ["a control character in the text"]
    try:
        walk(app, tokens(text), 0, problems)
    except Problem as e:
        problems.append(str(e))
    return problems


def main(argv):
    if len(argv) != 3 or not re.match(r"^[a-z][a-z0-9]{2,31}$", argv[1]):
        sys.stderr.write("usage: _nginx_custom_lint <app> < directives\n")
        return 2
    with open(argv[2], "rb") as fh:
        text = fh.read(MAX_BYTES + 1).decode("utf-8", "surrogateescape")
    problems = lint(argv[1], text)
    for p in problems[:20]:
        print(p)
    if len(problems) > 20:
        print("(+%d more)" % (len(problems) - 20))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
CIPINGINXLINT
    rm -f "$tmp"
    return $rc
}
