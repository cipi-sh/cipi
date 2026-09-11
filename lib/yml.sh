#!/bin/bash
#############################################
# Cipi — cipi.yml (declarative app configuration)
#
# An app can carry a `cipi.yml` in its repository describing the state it
# expects on the server: domain aliases, PHP version and settings, its extra
# databases, its queue workers and its backup strategy. `cipi yml apply`
# reconciles the server with that file, so the configuration travels with the
# code instead of living only in someone's shell history.
#
# The file arrives over git, which means anyone who can commit controls it.
# That shapes every design decision here:
#
#   * It can only *configure* an app that already exists. Creating, renaming,
#     deleting apps and users stays a root-only, out-of-band operation.
#   * Databases and backup profiles it declares must live in the app's own
#     namespace, so one repository can never touch another app's data.
#   * Nothing in the schema carries a free-form shell command — except
#     `deploy.post`, which runs a fixed, allowlisted set of runners (artisan,
#     npm, composer, …) with strictly validated arguments after each deploy.
#   * The parser implements a small YAML subset and refuses anchors, aliases,
#     tags, merge keys, block scalars and flow mappings outright.
#   * Applying is opt-in per app (`cipi yml auto <app> on`) and otherwise
#     manual; a plan can always be inspected before anything changes.
#############################################

yml_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        validate|check) _yml_validate_cmd "$@" ;;
        plan|diff)      _yml_plan_cmd "$@" ;;
        apply)          _yml_apply_cmd "$@" ;;
        auto)           _yml_auto_cmd "$@" ;;
        post-deploy|postdeploy) _yml_post_deploy_cmd "$@" ;;
        generate|dump)  _yml_generate "$@" ;;
        example|sample) _yml_example "$@" ;;
        *) error "Use: validate plan apply auto post-deploy generate example"; exit 1 ;;
    esac
}

# Where the file is looked for, in order: the live release, a custom app's
# htdocs/ (that tree *is* the document root), then shared/.
_yml_find_file() {
    local app="$1" f
    for f in "/home/${app}/current/cipi.yml" \
             "/home/${app}/current/cipi.yaml" \
             "/home/${app}/htdocs/cipi.yml" \
             "/home/${app}/htdocs/cipi.yaml" \
             "/home/${app}/shared/cipi.yml"; do
        [[ -f "$f" ]] && { echo "$f"; return 0; }
    done
    return 1
}

# Parse + validate, printing the validator's JSON result on stdout.
_yml_parse() {
    local file="$1" app="$2"
    command -v python3 >/dev/null 2>&1 || {
        echo '{"ok":false,"errors":["python3 is required to read cipi.yml"],"warnings":[]}'
        return 1
    }
    python3 - "$file" "$app" <<'CIPIYAMLPY'
#!/usr/bin/env python3
"""Cipi — cipi.yml parser and validator.

Parses a deliberately small YAML subset and validates it against Cipi's
schema, emitting JSON on stdout:

    {"ok": true,  "data": {...}, "warnings": [...]}
    {"ok": false, "errors": ["line 12: ..."], "warnings": [...]}

The file arrives over git, so anyone who can commit to the repository controls
its contents. Everything is therefore fail-closed: an unknown key, an
unsupported YAML construct or a value outside its allowed set is an error, not
something to skip. The parser implements no anchors, aliases, tags, merge keys
or block scalars at all, so those cannot be smuggled in.

Usage: yamlval.py <file> <app-name>
"""

import json
import re
import sys

MAX_BYTES = 65536
MAX_LINES = 2000
MAX_DEPTH = 6
MAX_SEQ = 200

PHP_VERSIONS = {"8.3", "8.4", "8.5"}
ENGINES = {"mariadb", "pgsql"}
SCOPES = {"all", "files", "db"}
DESTINATIONS = {"local", "s3"}

# Mirrors the settable catalog in lib/ini.sh. Server-wide keys are not
# reachable from a project file at all — only per-app overrides.
INI_KEYS = {
    "memory_limit", "upload_max_filesize", "post_max_size",
    "max_execution_time", "max_input_time", "max_input_vars",
    "max_file_uploads", "default_socket_timeout", "date.timezone",
    "display_errors", "log_errors", "output_buffering",
    "zlib.output_compression", "session.gc_maxlifetime",
    "realpath_cache_size", "realpath_cache_ttl", "expose_php",
    "opcache.enable", "opcache.enable_cli", "opcache.memory_consumption",
    "opcache.interned_strings_buffer", "opcache.max_accelerated_files",
    "opcache.validate_timestamps", "opcache.revalidate_freq",
    "opcache.jit", "opcache.jit_buffer_size",
}

SIZE_RE = re.compile(r"^(-1|[0-9]+[KkMmGg]?)$")
DOMAIN_RE = re.compile(
    r"^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?"
    r"(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$"
)
DB_NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,63}$")
QUEUE_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
PROFILE_RE = re.compile(r"^[a-z][a-z0-9-]{1,31}$")
EVERY_RE = re.compile(r"^([0-9]+)([mhd])$")
CRON_RE = re.compile(r"^[0-9*/,\s-]+$")
GLOB_RE = re.compile(r"^[a-zA-Z0-9_.*?\[\]-]{1,64}$")
# Deliberately narrow: scheme, host, optional port, optional path. No user
# info, no query string, no fragment, and no character that could confuse the
# shell or a downstream curl invocation.
URL_RE = re.compile(r"^https?://[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]{0,200})?$")
TABLE_GLOB_RE = re.compile(r"^[a-zA-Z0-9_.*?\[\]-]{1,128}$")
POST_RUNNERS = frozenset({"artisan", "npm", "npx", "yarn", "pnpm", "composer", "php", "node"})
ARTISAN_CMD_RE = re.compile(r"^[a-zA-Z0-9:_-]+$")
POST_ARG_RE = re.compile(r"^[a-zA-Z0-9_@./:=+-]{1,256}$")
REL_SCRIPT_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,200}$")
MAX_POST_STEPS = 20
MAX_POST_ARGS = 32
NPM_FORBIDDEN = frozenset({"explore", "init", "login", "adduser", "edit"})
COMPOSER_FORBIDDEN = frozenset({"shell", "browse", "fund"})


class YamlError(Exception):
    def __init__(self, line, msg):
        super().__init__("line %d: %s" % (line, msg))


# ── Parser ───────────────────────────────────────────────────

def strip_comment(s):
    """Remove a trailing comment, respecting quotes."""
    out = []
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == '"' and i + 1 < len(s):
                out.append(s[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        else:
            if c in ("'", '"'):
                quote = c
                out.append(c)
            elif c == "#" and (not out or out[-1] in (" ", "\t")):
                break
            else:
                out.append(c)
        i += 1
    return "".join(out).rstrip()


def parse_scalar(raw, lineno):
    s = raw.strip()
    if s == "":
        return None
    first = s[0]
    if first in "&*!":
        raise YamlError(lineno, "anchors, aliases and tags are not supported")
    if first in "|>":
        raise YamlError(lineno, "block scalars are not supported")
    if first == "{":
        raise YamlError(lineno, "flow mappings ({...}) are not supported — use indented keys")
    if first == "[":
        if not s.endswith("]"):
            raise YamlError(lineno, "unterminated flow sequence")
        inner = s[1:-1].strip()
        if inner == "":
            return []
        items = []
        for part in split_flow(inner, lineno):
            items.append(parse_scalar(part, lineno))
        return items
    if first == '"':
        if len(s) < 2 or not s.endswith('"'):
            raise YamlError(lineno, "unterminated double-quoted string")
        body = s[1:-1]
        try:
            return (body.replace("\\\\", "\x00")
                        .replace('\\"', '"')
                        .replace("\\n", "\n")
                        .replace("\\t", "\t")
                        .replace("\x00", "\\"))
        except Exception:
            raise YamlError(lineno, "invalid escape sequence")
    if first == "'":
        if len(s) < 2 or not s.endswith("'"):
            raise YamlError(lineno, "unterminated single-quoted string")
        return s[1:-1].replace("''", "'")

    low = s.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if low in ("null", "~"):
        return None
    if re.match(r"^-?[0-9]+$", s):
        return int(s)
    if re.match(r"^-?[0-9]*\.[0-9]+$", s):
        return float(s)
    if ": " in s or s.endswith(":"):
        raise YamlError(lineno, "unquoted ':' in a value — wrap the value in quotes")
    return s


def split_flow(s, lineno):
    parts, buf, quote = [], [], None
    for c in s:
        if quote:
            buf.append(c)
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
            buf.append(c)
        elif c == ",":
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(c)
    if quote:
        raise YamlError(lineno, "unterminated quoted string in flow sequence")
    parts.append("".join(buf))
    return [p.strip() for p in parts if p.strip() != ""]


def split_key(s, lineno):
    """Split 'key: value' at the first structural colon."""
    quote = None
    i = 0
    while i < len(s):
        c = s[i]
        if quote:
            if c == quote:
                quote = None
        elif c in ("'", '"'):
            quote = c
        elif c == ":":
            rest = s[i + 1:]
            if rest == "" or rest[0] in (" ", "\t"):
                return s[:i].strip(), rest.strip()
        i += 1
    raise YamlError(lineno, "expected 'key: value'")


def tokenize(text):
    lines = []
    for n, raw in enumerate(text.split("\n"), start=1):
        raw = raw.replace("\r", "")
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise YamlError(n, "tabs cannot be used for indentation — use spaces")
        content = strip_comment(raw)
        if content.strip() == "":
            continue
        if content.strip() in ("---", "..."):
            continue
        indent = len(content) - len(content.lstrip(" "))
        stripped = content.strip()
        if stripped.startswith("<<:"):
            raise YamlError(n, "merge keys (<<) are not supported")
        lines.append((indent, stripped, n))
    return lines


def parse_block(lines, idx, indent, depth):
    if depth > MAX_DEPTH:
        raise YamlError(lines[idx][2], "structure nested too deeply (max %d)" % MAX_DEPTH)
    if lines[idx][1].startswith("- "):
        return parse_seq(lines, idx, indent, depth)
    if lines[idx][1] == "-":
        raise YamlError(lines[idx][2], "empty sequence item")
    return parse_map(lines, idx, indent, depth)


def parse_map(lines, idx, indent, depth):
    out = {}
    while idx < len(lines):
        cur_indent, content, lineno = lines[idx]
        if cur_indent < indent:
            break
        if cur_indent > indent:
            raise YamlError(lineno, "unexpected indentation")
        if content.startswith("- "):
            raise YamlError(lineno, "sequence item where a key was expected")
        key, value = split_key(content, lineno)
        if key == "":
            raise YamlError(lineno, "empty key")
        if key in out:
            raise YamlError(lineno, "duplicate key '%s'" % key)
        if value == "":
            if idx + 1 < len(lines) and lines[idx + 1][0] > cur_indent:
                child, idx = parse_block(lines, idx + 1, lines[idx + 1][0], depth + 1)
                out[key] = child
                continue
            out[key] = None
            idx += 1
            continue
        out[key] = parse_scalar(value, lineno)
        idx += 1
    return out, idx


def parse_seq(lines, idx, indent, depth):
    out = []
    while idx < len(lines):
        cur_indent, content, lineno = lines[idx]
        if cur_indent < indent:
            break
        if cur_indent > indent:
            raise YamlError(lineno, "unexpected indentation in sequence")
        if not content.startswith("- "):
            break
        if len(out) >= MAX_SEQ:
            raise YamlError(lineno, "too many list items (max %d)" % MAX_SEQ)
        item = content[2:].strip()
        try:
            key, value = split_key(item, lineno)
            is_map = True
        except YamlError:
            is_map = False
        if is_map:
            # A mapping opened on the dash line: re-read it as a block whose
            # indent starts just past "- ".
            sub_indent = cur_indent + 2
            sub = [(sub_indent, item, lineno)]
            j = idx + 1
            while j < len(lines) and lines[j][0] >= sub_indent and not (
                lines[j][0] == cur_indent and lines[j][1].startswith("- ")
            ):
                if lines[j][0] < sub_indent:
                    break
                sub.append(lines[j])
                j += 1
            value_map, consumed = parse_map(sub, 0, sub_indent, depth + 1)
            if consumed != len(sub):
                raise YamlError(sub[consumed][2], "unexpected indentation in list item")
            out.append(value_map)
            idx = j
        else:
            out.append(parse_scalar(item, lineno))
            idx += 1
    return out, idx


def parse(text):
    lines = tokenize(text)
    if not lines:
        return {}
    if lines[0][0] != 0:
        raise YamlError(lines[0][2], "file must start at column 0")
    value, idx = parse_block(lines, 0, 0, 1)
    if idx != len(lines):
        raise YamlError(lines[idx][2], "unexpected content")
    return value


# ── Validation ───────────────────────────────────────────────

class Validator:
    def __init__(self, app):
        self.app = app
        self.errors = []
        self.warnings = []

    def err(self, path, msg):
        self.errors.append("%s: %s" % (path, msg))

    def warn(self, path, msg):
        self.warnings.append("%s: %s" % (path, msg))

    def expect_map(self, value, path):
        if value is None:
            return {}
        if not isinstance(value, dict):
            self.err(path, "expected a mapping of keys")
            return None
        return value

    def expect_list(self, value, path):
        if value is None:
            return []
        if not isinstance(value, list):
            self.err(path, "expected a list")
            return None
        return value

    def unknown_keys(self, value, allowed, path):
        for k in value:
            if k not in allowed:
                self.err("%s.%s" % (path, k),
                         "unknown key (allowed: %s)" % ", ".join(sorted(allowed)))

    def as_str(self, value, path):
        if isinstance(value, bool) or value is None:
            self.err(path, "expected a string")
            return None
        if isinstance(value, (int, float)):
            return str(value)
        if not isinstance(value, str):
            self.err(path, "expected a string")
            return None
        return value

    def as_int(self, value, path, lo, hi):
        if isinstance(value, bool) or not isinstance(value, int):
            self.err(path, "expected a whole number")
            return None
        if value < lo or value > hi:
            self.err(path, "must be between %d and %d" % (lo, hi))
            return None
        return value

    def as_bool(self, value, path):
        if not isinstance(value, bool):
            self.err(path, "expected true or false")
            return None
        return value

    # ── sections

    def validate(self, doc):
        if not isinstance(doc, dict):
            self.err("cipi.yml", "the file must be a mapping at the top level")
            return None

        allowed = {"version", "app", "databases", "workers", "backup", "schedule", "health", "deploy"}
        self.unknown_keys(doc, allowed, "cipi.yml")

        version = doc.get("version")
        if version is None:
            self.err("version", "required — add 'version: 1'")
        elif version != 1:
            self.err("version", "unsupported version %r (this Cipi understands version 1)" % (version,))

        out = {}
        if "app" in doc:
            out["app"] = self.v_app(doc["app"])
        if "databases" in doc:
            out["databases"] = self.v_databases(doc["databases"])
        if "workers" in doc:
            out["workers"] = self.v_workers(doc["workers"])
        if "backup" in doc:
            out["backup"] = self.v_backup(doc["backup"])
        if "schedule" in doc:
            b = self.as_bool(doc["schedule"], "schedule")
            if b is not None:
                out["schedule"] = b
        if "health" in doc:
            out["health"] = self.v_health(doc["health"])
        if "deploy" in doc:
            out["deploy"] = self.v_deploy(doc["deploy"])
        return out

    def v_deploy(self, node):
        m = self.expect_map(node, "deploy")
        if m is None:
            return {}
        self.unknown_keys(m, {"post", "post_on_failure"}, "deploy")
        out = {"post_on_failure": "warn", "post": []}

        if "post_on_failure" in m:
            s = self.as_str(m["post_on_failure"], "deploy.post_on_failure")
            if s is not None:
                if s not in ("warn", "abort"):
                    self.err("deploy.post_on_failure", "must be 'warn' or 'abort'")
                else:
                    out["post_on_failure"] = s

        if "post" not in m:
            return out
        lst = self.expect_list(m["post"], "deploy.post")
        if lst is None:
            return out
        if len(lst) > MAX_POST_STEPS:
            self.err("deploy.post", "at most %d steps" % MAX_POST_STEPS)
            return out
        for i, item in enumerate(lst):
            step = self.v_deploy_post_step(item, "deploy.post[%d]" % i)
            if step is not None:
                out["post"].append(step)
        return out

    def valid_post_arg(self, arg, path):
        if not isinstance(arg, str):
            self.err(path, "expected a string")
            return False
        if not POST_ARG_RE.match(arg):
            self.err(path, "contains disallowed characters — use letters, digits, -_.:/@=+ only")
            return False
        if ".." in arg:
            self.err(path, "path traversal (..) is not allowed")
            return False
        return True

    def v_deploy_post_step(self, item, path):
        if isinstance(item, str):
            return self.v_deploy_post_string(item.strip(), path)
        if isinstance(item, dict):
            if "run" in item:
                return self.v_deploy_post_structured(item, path)
            if len(item) == 1:
                runner = next(iter(item))
                if runner in POST_RUNNERS:
                    val = item[runner]
                    if isinstance(val, str):
                        return self.v_deploy_post_string("%s %s" % (runner, val.strip()), path)
                    if isinstance(val, list):
                        parts = [runner]
                        for j, a in enumerate(val):
                            if not self.valid_post_arg(str(a), "%s[%d]" % (path, j)):
                                return None
                            parts.append(str(a))
                        return self.v_deploy_post_string(" ".join(parts), path)
            self.err(path, "expected a string, a one-key map (artisan: …), or an object with 'run:'")
            return None
        self.err(path, "expected a string or a mapping")
        return None

    def v_deploy_post_string(self, s, path):
        if not s:
            self.err(path, "empty step")
            return None
        parts = s.split()
        if not parts:
            self.err(path, "empty step")
            return None
        runner = parts[0]
        if runner not in POST_RUNNERS:
            self.err(path, "unknown runner %r — allowed: %s" % (
                runner, ", ".join(sorted(POST_RUNNERS))))
            return None
        argv = parts[1:]
        return self.v_deploy_post_argv(runner, argv, path)

    def v_deploy_post_structured(self, item, path):
        runner = self.as_str(item.get("run"), path + ".run")
        if runner is None:
            return None
        if runner not in POST_RUNNERS:
            self.err(path + ".run", "unknown runner %r — allowed: %s" % (
                runner, ", ".join(sorted(POST_RUNNERS))))
            return None
        argv = []
        if runner == "artisan":
            cmd = self.as_str(item.get("command"), path + ".command")
            if cmd is None:
                self.err(path, "'command' is required when run is artisan")
                return None
            if not ARTISAN_CMD_RE.match(cmd):
                self.err(path + ".command", "invalid artisan command name")
                return None
            if cmd.lower() == "tinker":
                self.err(path + ".command", "artisan tinker is not allowed")
                return None
            argv.append(cmd)
        if "args" in item:
            alst = self.expect_list(item["args"], path + ".args")
            if alst is None:
                return None
            if len(alst) > MAX_POST_ARGS:
                self.err(path + ".args", "at most %d arguments" % MAX_POST_ARGS)
                return None
            for j, a in enumerate(alst):
                if not self.valid_post_arg(str(a), path + ".args[%d]" % j):
                    return None
                argv.append(str(a))
        elif runner != "artisan":
            self.err(path, "'args' is required when run is not artisan")
            return None
        if item.get("force") is True and runner == "artisan":
            if "--force" not in argv:
                argv.append("--force")
        for k in item:
            if k not in ("run", "command", "args", "force"):
                self.err(path + "." + k, "unknown key")
        return self.v_deploy_post_argv(runner, argv, path)

    def v_deploy_post_argv(self, runner, argv, path):
        if len(argv) > MAX_POST_ARGS:
            self.err(path, "at most %d arguments" % MAX_POST_ARGS)
            return None
        if runner == "artisan":
            if not argv:
                self.err(path, "artisan requires a command (e.g. 'artisan cache:clear')")
                return None
            if not ARTISAN_CMD_RE.match(argv[0]):
                self.err(path, "invalid artisan command %r" % argv[0])
                return None
            if argv[0].lower() == "tinker":
                self.err(path, "artisan tinker is not allowed")
                return None
            for j, a in enumerate(argv[1:], 1):
                if not self.valid_post_arg(a, path + "[%d]" % j):
                    return None
        elif runner in ("npm", "npx", "yarn", "pnpm"):
            if not argv:
                self.err(path, "%s requires at least one argument (e.g. 'npm run build')" % runner)
                return None
            if argv[0] in NPM_FORBIDDEN:
                self.err(path, "%s %s is not allowed" % (runner, argv[0]))
                return None
            for j, a in enumerate(argv):
                if not self.valid_post_arg(a, path + "[%d]" % j):
                    return None
        elif runner == "composer":
            if not argv:
                self.err(path, "composer requires at least one argument")
                return None
            if argv[0] in COMPOSER_FORBIDDEN:
                self.err(path, "composer %s is not allowed" % argv[0])
                return None
            for j, a in enumerate(argv):
                if not self.valid_post_arg(a, path + "[%d]" % j):
                    return None
        elif runner in ("php", "node"):
            if len(argv) != 1:
                self.err(path, "%s requires exactly one script path" % runner)
                return None
            if not REL_SCRIPT_RE.match(argv[0]) or argv[0].startswith("/"):
                self.err(path, "script must be a relative path under the release (e.g. scripts/warm.mjs)")
                return None
        return {"run": runner, "argv": argv}

    def v_health(self, node):
        m = self.expect_map(node, "health")
        if m is None:
            return {}
        self.unknown_keys(m, {"enabled", "url", "expect", "grace",
                              "postdeploy", "rollback_on_unhealthy"}, "health")
        out = {}

        if "enabled" in m:
            b = self.as_bool(m["enabled"], "health.enabled")
            if b is None:
                return {}
            out["enabled"] = b
            if b is False:
                # "health: {enabled: false}" removes the healthcheck; nothing
                # else in the section would mean anything.
                for k in m:
                    if k != "enabled":
                        self.err("health." + k, "cannot be combined with 'enabled: false'")
                return out
        else:
            out["enabled"] = True

        if "url" not in m:
            self.err("health", "'url' is required (or use 'enabled: false' to remove the healthcheck)")
            return out
        url = self.as_str(m.get("url"), "health.url")
        if url is None:
            return out
        if not URL_RE.match(url):
            self.err("health.url",
                     "must be a plain http:// or https:// URL with no credentials, "
                     "query string or fragment")
            return out
        # The host is checked against the app's own domains in the plan, where
        # the server state is available: a project file must not be able to
        # point this server's prober at somewhere else on the network.
        out["url"] = url

        if "expect" in m:
            v = self.as_int(m["expect"], "health.expect", 100, 599)
            if v is not None:
                out["expect"] = v
        else:
            out["expect"] = 200

        if "grace" in m:
            v = self.as_int(m["grace"], "health.grace", 0, 120)
            if v is not None:
                out["grace"] = v

        for field in ("postdeploy", "rollback_on_unhealthy"):
            if field in m:
                b = self.as_bool(m[field], "health." + field)
                if b is not None:
                    out[field] = b
        return out

    def v_app(self, node):
        m = self.expect_map(node, "app")
        if m is None:
            return {}
        self.unknown_keys(m, {"php", "aliases", "ini"}, "app")
        out = {}

        if "php" in m:
            php = self.as_str(m["php"], "app.php")
            if php is not None:
                if php not in PHP_VERSIONS:
                    self.err("app.php", "must be one of %s" % ", ".join(sorted(PHP_VERSIONS)))
                else:
                    out["php"] = php

        if "aliases" in m:
            lst = self.expect_list(m["aliases"], "app.aliases")
            aliases = []
            if lst is not None:
                if len(lst) > 100:
                    self.err("app.aliases", "at most 100 aliases")
                for i, a in enumerate(lst):
                    p = "app.aliases[%d]" % i
                    s = self.as_str(a, p)
                    if s is None:
                        continue
                    if not DOMAIN_RE.match(s):
                        self.err(p, "not a valid hostname: %r" % s)
                        continue
                    if s in aliases:
                        self.err(p, "duplicate alias %r" % s)
                        continue
                    aliases.append(s)
            out["aliases"] = aliases

        if "ini" in m:
            im = self.expect_map(m["ini"], "app.ini")
            ini = {}
            if im is not None:
                for k, v in im.items():
                    p = "app.ini.%s" % k
                    if k not in INI_KEYS:
                        self.err(p, "not a settable PHP setting (see: cipi ini keys)")
                        continue
                    if isinstance(v, bool):
                        ini[k] = "On" if v else "Off"
                        continue
                    s = self.as_str(v, p)
                    if s is None:
                        continue
                    if not re.match(r"^[A-Za-z0-9_.,+/-]{1,64}$", s):
                        self.err(p, "invalid value %r" % s)
                        continue
                    ini[k] = s
            out["ini"] = ini
        return out

    def db_allowed(self, name):
        """A project file may only own databases in its own namespace.

        Without this a commit could declare `name: otherapp` and Cipi would
        hand this app's user full privileges on another app's database.
        """
        return name == self.app or name.startswith(self.app + "_")

    def v_databases(self, node):
        lst = self.expect_list(node, "databases")
        if lst is None:
            return []
        out, seen = [], set()
        if len(lst) > 50:
            self.err("databases", "at most 50 databases")
            return []
        for i, item in enumerate(lst):
            p = "databases[%d]" % i
            if isinstance(item, str):
                item = {"name": item}
            m = self.expect_map(item, p)
            if m is None:
                continue
            self.unknown_keys(m, {"name", "engine"}, p)
            name = self.as_str(m.get("name"), p + ".name")
            if name is None:
                self.err(p, "'name' is required")
                continue
            if not DB_NAME_RE.match(name):
                self.err(p + ".name",
                         "invalid database name %r (lowercase letters, digits and underscores)" % name)
                continue
            if not self.db_allowed(name):
                self.err(p + ".name",
                         "must be '%s' or start with '%s_' — a project file cannot "
                         "claim databases outside its own namespace" % (self.app, self.app))
                continue
            if name in seen:
                self.err(p + ".name", "duplicate database %r" % name)
                continue
            seen.add(name)
            engine = m.get("engine", "mariadb")
            engine = self.as_str(engine, p + ".engine")
            if engine is None:
                continue
            engine = {"mysql": "mariadb", "postgres": "pgsql", "postgresql": "pgsql"}.get(engine, engine)
            if engine not in ENGINES:
                self.err(p + ".engine", "must be one of %s" % ", ".join(sorted(ENGINES)))
                continue
            out.append({"name": name, "engine": engine})
        return out

    def v_workers(self, node):
        m = self.expect_map(node, "workers")
        if m is None:
            return {}
        self.unknown_keys(m, {"horizon", "reverb", "queues"}, "workers")
        out = {}
        if "horizon" in m:
            b = self.as_bool(m["horizon"], "workers.horizon")
            if b is not None:
                out["horizon"] = b
        if "reverb" in m:
            b = self.as_bool(m["reverb"], "workers.reverb")
            if b is not None:
                out["reverb"] = b
        if "queues" in m:
            lst = self.expect_list(m["queues"], "workers.queues")
            queues, seen = [], set()
            if lst is not None:
                if len(lst) > 20:
                    self.err("workers.queues", "at most 20 queue workers")
                    lst = lst[:20]
                for i, item in enumerate(lst):
                    p = "workers.queues[%d]" % i
                    if isinstance(item, str):
                        item = {"queue": item}
                    q = self.expect_map(item, p)
                    if q is None:
                        continue
                    self.unknown_keys(q, {"queue", "processes", "tries", "timeout"}, p)
                    name = self.as_str(q.get("queue"), p + ".queue")
                    if name is None:
                        self.err(p, "'queue' is required")
                        continue
                    if not QUEUE_RE.match(name):
                        self.err(p + ".queue", "invalid queue name %r" % name)
                        continue
                    if name in seen:
                        self.err(p + ".queue", "duplicate queue %r" % name)
                        continue
                    seen.add(name)
                    entry = {"queue": name}
                    for field, lo, hi, default in (
                        ("processes", 1, 20, 1),
                        ("tries", 1, 100, 3),
                        ("timeout", 10, 86400, 3600),
                    ):
                        if field in q:
                            val = self.as_int(q[field], "%s.%s" % (p, field), lo, hi)
                            if val is None:
                                continue
                            entry[field] = val
                        else:
                            entry[field] = default
                    queues.append(entry)
            out["queues"] = queues
        if out.get("horizon") and out.get("queues"):
            self.err("workers",
                     "horizon and queues are mutually exclusive — Horizon replaces queue:work workers")
        return out

    def v_backup(self, node):
        m = self.expect_map(node, "backup")
        if m is None:
            return {}
        self.unknown_keys(m, {"profiles"}, "backup")
        lst = self.expect_list(m.get("profiles"), "backup.profiles")
        if lst is None:
            return {}
        out, seen = [], set()
        if len(lst) > 10:
            self.err("backup.profiles", "at most 10 profiles per app")
            return {}
        for i, item in enumerate(lst):
            p = "backup.profiles[%d]" % i
            pm = self.expect_map(item, p)
            if pm is None:
                continue
            self.unknown_keys(pm, {
                "name", "scope", "databases", "exclude_databases", "exclude_tables",
                "every", "cron", "destinations", "encrypt",
                "keep", "keep_days", "keep_weeks",
            }, p)

            name = self.as_str(pm.get("name"), p + ".name")
            if name is None:
                self.err(p, "'name' is required")
                continue
            if not PROFILE_RE.match(name):
                self.err(p + ".name", "invalid profile name %r" % name)
                continue
            # Same namespacing rule as databases: a project file must not be
            # able to rewrite or delete another app's backup strategy.
            if name != self.app and not name.startswith(self.app + "-"):
                self.err(p + ".name",
                         "must be '%s' or start with '%s-' — a project file cannot "
                         "modify another app's backup profiles" % (self.app, self.app))
                continue
            if name in seen:
                self.err(p + ".name", "duplicate profile %r" % name)
                continue
            seen.add(name)

            prof = {"name": name}

            scope = pm.get("scope", "all")
            scope = self.as_str(scope, p + ".scope")
            if scope is None:
                continue
            if scope not in SCOPES:
                self.err(p + ".scope", "must be one of %s" % ", ".join(sorted(SCOPES)))
                continue
            prof["scope"] = scope

            for field, rx in (("databases", GLOB_RE),
                              ("exclude_databases", GLOB_RE),
                              ("exclude_tables", TABLE_GLOB_RE)):
                if field not in pm:
                    continue
                items = self.expect_list(pm[field], "%s.%s" % (p, field))
                if items is None:
                    continue
                vals = []
                for j, g in enumerate(items):
                    gp = "%s.%s[%d]" % (p, field, j)
                    s = self.as_str(g, gp)
                    if s is None:
                        continue
                    if not rx.match(s):
                        self.err(gp, "invalid pattern %r" % s)
                        continue
                    vals.append(s)
                prof[field] = vals

            if "every" in pm and "cron" in pm:
                self.err(p, "use either 'every' or 'cron', not both")
                continue
            if "every" in pm:
                s = self.as_str(pm["every"], p + ".every")
                if s is None:
                    continue
                mm = EVERY_RE.match(s)
                if not mm:
                    self.err(p + ".every", "expected a value like 30m, 6h or 1d")
                    continue
                num, unit = int(mm.group(1)), mm.group(2)
                if num == 0:
                    self.err(p + ".every", "must be greater than zero")
                    continue
                if unit == "m" and (num > 59 or 60 % num != 0):
                    self.err(p + ".every", "minutes must divide 60 evenly (5m, 10m, 15m, 20m, 30m)")
                    continue
                if unit == "h" and (num > 23 or 24 % num != 0):
                    self.err(p + ".every", "hours must divide 24 evenly (1h, 2h, 3h, 4h, 6h, 8h, 12h)")
                    continue
                if unit == "d" and num > 28:
                    self.err(p + ".every", "at most 28 days")
                    continue
                prof["every"] = s
            elif "cron" in pm:
                s = self.as_str(pm["cron"], p + ".cron")
                if s is None:
                    continue
                if not CRON_RE.match(s) or len(s.split()) != 5:
                    self.err(p + ".cron",
                             "expected five cron fields using digits and * / , - only")
                    continue
                prof["cron"] = s

            if "destinations" in pm:
                items = self.expect_list(pm["destinations"], p + ".destinations")
                if items is None:
                    continue
                dests = []
                for j, d in enumerate(items):
                    dp = "%s.destinations[%d]" % (p, j)
                    s = self.as_str(d, dp)
                    if s is None:
                        continue
                    if s not in DESTINATIONS:
                        self.err(dp, "must be one of %s" % ", ".join(sorted(DESTINATIONS)))
                        continue
                    if s not in dests:
                        dests.append(s)
                if not dests:
                    self.err(p + ".destinations", "at least one destination is required")
                    continue
                prof["destinations"] = dests

            if "encrypt" in pm:
                b = self.as_bool(pm["encrypt"], p + ".encrypt")
                if b is not None:
                    prof["encrypt"] = b

            ret = {}
            for field, lo, hi in (("keep", 0, 1000), ("keep_days", 0, 3650), ("keep_weeks", 0, 520)):
                if field in pm:
                    val = self.as_int(pm[field], "%s.%s" % (p, field), lo, hi)
                    if val is not None:
                        ret[field] = val
            if ret and not any(v > 0 for v in ret.values()):
                self.err(p, "retention is all zeros — the profile would grow without bound")
                continue
            if not ret:
                self.err(p, "retention is required — set keep, keep_days or keep_weeks")
                continue
            prof["retention"] = {
                "keep": ret.get("keep", 0),
                "days": ret.get("keep_days", 0),
                "weeks": ret.get("keep_weeks", 0),
            }

            if scope == "db" and prof.get("databases") == []:
                self.err(p, "scope 'db' with an empty databases list would back up nothing")
                continue
            out.append(prof)
        return {"profiles": out}


def main():
    if len(sys.argv) < 3:
        print(json.dumps({"ok": False, "errors": ["usage: yamlval.py <file> <app>"], "warnings": []}))
        return 2
    path, app = sys.argv[1], sys.argv[2]
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        print(json.dumps({"ok": False, "errors": ["cannot read %s: %s" % (path, exc)], "warnings": []}))
        return 2

    if len(raw) > MAX_BYTES:
        print(json.dumps({"ok": False,
                          "errors": ["file is larger than %d bytes" % MAX_BYTES],
                          "warnings": []}))
        return 2
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        print(json.dumps({"ok": False, "errors": ["file is not valid UTF-8"], "warnings": []}))
        return 2
    if text.count("\n") > MAX_LINES:
        print(json.dumps({"ok": False,
                          "errors": ["file has more than %d lines" % MAX_LINES],
                          "warnings": []}))
        return 2

    try:
        doc = parse(text)
    except YamlError as exc:
        print(json.dumps({"ok": False, "errors": [str(exc)], "warnings": []}))
        return 1
    except RecursionError:
        print(json.dumps({"ok": False, "errors": ["structure nested too deeply"], "warnings": []}))
        return 1

    v = Validator(app)
    data = v.validate(doc)
    if v.errors:
        print(json.dumps({"ok": False, "errors": v.errors, "warnings": v.warnings}))
        return 1
    print(json.dumps({"ok": True, "data": data, "warnings": v.warnings}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
CIPIYAMLPY
}

_yml_resolve() {
    # Sets _YML_FILE and _YML_APP from args. parse_args must already have run.
    local app="${1:-}"
    _YML_FILE="${ARG_file:-}"
    if [[ -n "$_YML_FILE" ]]; then
        [[ -f "$_YML_FILE" ]] || { error "File not found: ${_YML_FILE}"; exit 1; }
        [[ -z "$app" ]] && { error "Usage: cipi yml <command> <app> --file=<path>"; exit 1; }
    fi
    [[ -z "$app" ]] && { error "Usage: cipi yml <command> <app> [--file=<path>]"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    _YML_APP="$app"
    if [[ -z "$_YML_FILE" ]]; then
        _YML_FILE=$(_yml_find_file "$app") || {
            error "No cipi.yml found for '${app}'."
            echo "  Looked in: /home/${app}/current/cipi.yml, current/cipi.yaml, htdocs/cipi.yml, shared/cipi.yml"
            echo ""
            echo "  Start from what this server already has:"
            echo "    cipi yml generate ${app} > cipi.yml"
            echo "  Or from a blank template in this app's namespace:"
            echo "    cipi yml example ${app} > cipi.yml"
            echo "  Then commit it to the repository and deploy."
            exit 1
        }
    fi
}

# Validate and leave the parsed document in _YML_DATA.
_yml_load() {
    local quiet="${1:-false}"
    local result
    result=$(_yml_parse "$_YML_FILE" "$_YML_APP") || true
    if [[ "$(echo "$result" | jq -r '.ok')" != "true" ]]; then
        error "cipi.yml is not valid (${_YML_FILE}):"
        echo "$result" | jq -r '.errors[]' | sed 's/^/    /'
        return 1
    fi
    local warns; warns=$(echo "$result" | jq -r '.warnings[]?' 2>/dev/null || true)
    if [[ -n "$warns" && "$quiet" != "true" ]]; then
        echo "$warns" | while IFS= read -r w; do [[ -n "$w" ]] && warn "$w"; done
    fi
    _YML_DATA=$(echo "$result" | jq '.data')
    return 0
}

_yml_validate_cmd() {
    local app="${1:-}"; shift||true
    parse_args "$@"
    _yml_resolve "$app"
    _yml_load || exit 1
    success "cipi.yml is valid (${_YML_FILE})"
    echo ""
    echo -e "  ${DIM}See what applying it would change: ${CYAN}cipi yml plan ${_YML_APP}${NC}"
    echo ""
}

# ── Plan ─────────────────────────────────────────────────────
#
# Every change is computed before anything is touched, so `apply` never
# surprises anyone and `plan` is safe to run on a live server.

_yml_build_plan() {
    local app="$_YML_APP"
    _YML_ACTIONS=()
    _YML_BLOCKERS=()
    _YML_NOTES=()

    # ── PHP version
    local want_php cur_php
    want_php=$(echo "$_YML_DATA" | jq -r '.app.php // empty')
    if [[ -n "$want_php" ]]; then
        cur_php=$(app_get "$app" php)
        if [[ "$want_php" != "$cur_php" ]]; then
            if ! php_is_installed "$want_php"; then
                _YML_BLOCKERS+=("PHP ${want_php} is not installed — run: cipi php install ${want_php}")
            else
                _YML_ACTIONS+=("php|${want_php}|PHP ${cur_php} → ${want_php}")
            fi
        fi
    fi

    # ── aliases (declared set replaces the current one)
    if echo "$_YML_DATA" | jq -e 'has("app") and (.app | has("aliases"))' &>/dev/null; then
        local primary cur_aliases want_aliases a owner
        primary=$(app_get "$app" domain)
        cur_aliases=$(vault_read apps.json | jq -r --arg a "$app" '(.[$a].aliases // [])[]' 2>/dev/null || true)
        want_aliases=$(echo "$_YML_DATA" | jq -r '.app.aliases[]?' 2>/dev/null || true)

        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            grep -Fxq "$a" <<< "$cur_aliases" && continue
            if [[ "$a" == "$primary" ]]; then
                _YML_BLOCKERS+=("alias '${a}' is already the primary domain of '${app}'")
                continue
            fi
            if domain_is_used_by_other_app "$a" "$app"; then
                _YML_BLOCKERS+=("alias '${a}' already belongs to app '${DOMAIN_USED_BY_APP}'")
                continue
            fi
            _YML_ACTIONS+=("alias-add|${a}|add domain alias ${a}")
        done <<< "$want_aliases"

        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            grep -Fxq "$a" <<< "$want_aliases" && continue
            _YML_ACTIONS+=("alias-remove|${a}|remove domain alias ${a}")
        done <<< "$cur_aliases"
    fi

    # ── php.ini overrides (app scope only)
    if echo "$_YML_DATA" | jq -e 'has("app") and (.app | has("ini"))' &>/dev/null; then
        local k v cur
        while IFS=$'\t' read -r k v; do
            [[ -n "$k" ]] || continue
            cur=$(vault_read apps.json | jq -r --arg a "$app" --arg k "$k" '.[$a].ini[$k] // empty')
            [[ "$cur" == "$v" ]] && continue
            _YML_ACTIONS+=("ini|${k}=${v}|php.ini ${k} = ${v}${cur:+ (was ${cur})}")
        done < <(echo "$_YML_DATA" | jq -r '.app.ini // {} | to_entries[] | "\(.key)\t\(.value)"')

        while IFS= read -r k; do
            [[ -n "$k" ]] || continue
            echo "$_YML_DATA" | jq -e --arg k "$k" '.app.ini | has($k)' &>/dev/null && continue
            _YML_ACTIONS+=("ini-unset|${k}|drop php.ini override ${k}")
        done < <(vault_read apps.json | jq -r --arg a "$app" '(.[$a].ini // {}) | keys[]' 2>/dev/null || true)
    fi

    # ── databases (created, never dropped)
    local name engine
    while IFS=$'\t' read -r name engine; do
        [[ -n "$name" ]] || continue
        if ! db_engine_is_installed "$engine" 2>/dev/null; then
            _YML_BLOCKERS+=("database '${name}' needs ${engine}, which is not installed — run: cipi db install ${engine}")
            continue
        fi
        if db_database_exists "$engine" "$name" 2>/dev/null; then
            continue
        fi
        _YML_ACTIONS+=("db|${name}|${engine}|create database ${name} (${engine})")
    done < <(echo "$_YML_DATA" | jq -r '.databases[]? | "\(.name)\t\(.engine)"')

    # ── workers
    if echo "$_YML_DATA" | jq -e 'has("workers")' &>/dev/null; then
        # `// empty` cannot be used to read these: jq's alternative operator
        # treats `false` exactly like a missing key, so "horizon: false" used to
        # read back as "not declared" and silently did nothing.
        local want_horizon cur_horizon
        want_horizon=$(echo "$_YML_DATA" | jq -r 'if .workers | has("horizon") then (.workers.horizon|tostring) else "" end')
        cur_horizon=$(app_get "$app" horizon)
        if [[ "$want_horizon" == "true" && "$cur_horizon" != "true" ]]; then
            _YML_ACTIONS+=("horizon|on|enable Horizon")
        elif [[ "$want_horizon" == "false" && "$cur_horizon" == "true" ]]; then
            _YML_ACTIONS+=("horizon|off|disable Horizon (restore queue workers)")
        fi

        # Reverb is independent of Horizon and of the queue workers: it is its
        # own Supervisor program with its own localhost port, so it is only ever
        # on or off here.
        local want_reverb cur_reverb
        want_reverb=$(echo "$_YML_DATA" | jq -r 'if .workers | has("reverb") then (.workers.reverb|tostring) else "" end')
        cur_reverb="false"; [[ -n "$(app_get "$app" reverb)" ]] && cur_reverb="true"
        if [[ "$want_reverb" == "true" && "$cur_reverb" != "true" ]]; then
            if [[ "$(app_get "$app" custom)" == "true" ]]; then
                _YML_BLOCKERS+=("workers.reverb is declared, but '${app}' is a custom app — Reverb is Laravel only")
            else
                _YML_ACTIONS+=("reverb|on|enable Reverb (WebSockets, nginx /app + /apps)")
            fi
        elif [[ "$want_reverb" == "false" && "$cur_reverb" == "true" ]]; then
            _YML_ACTIONS+=("reverb|off|disable Reverb (broadcasting back to its previous driver)")
        fi

        if echo "$_YML_DATA" | jq -e '.workers | has("queues")' &>/dev/null; then
            if [[ "$cur_horizon" == "true" && "$want_horizon" != "false" ]]; then
                _YML_BLOCKERS+=("queue workers are declared but Horizon is enabled — set 'workers.horizon: false' as well")
            else
                local conf="/etc/supervisor/conf.d/${app}.conf" q procs tries timeout cur_progs
                cur_progs=$(grep -oE "^\[program:${app}-worker-[^]]+\]" "$conf" 2>/dev/null \
                    | sed "s/^\[program:${app}-worker-//; s/\]$//" || true)
                while IFS=$'\t' read -r q procs tries timeout; do
                    [[ -n "$q" ]] || continue
                    if grep -Fxq "$q" <<< "$cur_progs"; then
                        _YML_ACTIONS+=("worker-sync|${q}|${procs}|${tries}|${timeout}|update queue worker ${q} (${procs} process(es))")
                    else
                        _YML_ACTIONS+=("worker-add|${q}|${procs}|${tries}|${timeout}|add queue worker ${q} (${procs} process(es))")
                    fi
                done < <(echo "$_YML_DATA" | jq -r '.workers.queues[]? | "\(.queue)\t\(.processes)\t\(.tries)\t\(.timeout)"')

                while IFS= read -r q; do
                    [[ -n "$q" ]] || continue
                    echo "$_YML_DATA" | jq -e --arg q "$q" '[.workers.queues[]?.queue] | index($q) != null' &>/dev/null && continue
                    _YML_ACTIONS+=("worker-remove|${q}|remove queue worker ${q}")
                done <<< "$cur_progs"
            fi
        fi
    fi

    # ── scheduler
    local want_sched cur_sched
    want_sched=$(echo "$_YML_DATA" | jq -r 'if has("schedule") then (.schedule|tostring) else "" end')
    if [[ -n "$want_sched" ]]; then
        cur_sched="true"
        crontab -u "$app" -l 2>/dev/null | grep -q '^\* \* \* \* \*.*schedule:run' || cur_sched="false"
        [[ "$want_sched" != "$cur_sched" ]] \
            && _YML_ACTIONS+=("schedule|${want_sched}|turn Laravel scheduler ${want_sched/true/on}${want_sched/false/off}")
    fi

    # ── healthcheck
    if echo "$_YML_DATA" | jq -e 'has("health")' &>/dev/null; then
        local h_enabled h_url h_expect h_grace h_pd h_rb
        # `// true` would read an explicit `enabled: false` as true (jq treats
        # false as empty) — has() is the correct "default true", as below.
        h_enabled=$(echo "$_YML_DATA" | jq -r 'if .health | has("enabled") then (.health.enabled|tostring) else "true" end')
        if [[ "$h_enabled" == "false" ]]; then
            [[ -n "$(app_get "$app" health_url)" ]] \
                && _YML_ACTIONS+=("health-unset||remove the healthcheck")
        else
            h_url=$(echo "$_YML_DATA" | jq -r '.health.url // empty')
            h_expect=$(echo "$_YML_DATA" | jq -r '.health.expect // 200')
            h_grace=$(echo "$_YML_DATA" | jq -r '.health.grace // empty')
            h_pd=$(echo "$_YML_DATA" | jq -r 'if .health | has("postdeploy") then (.health.postdeploy|tostring) else "true" end')
            h_rb=$(echo "$_YML_DATA" | jq -r 'if .health | has("rollback_on_unhealthy") then (.health.rollback_on_unhealthy|tostring) else "false" end')

            if ! _yml_url_belongs_to_app "$app" "$h_url"; then
                _YML_BLOCKERS+=("health.url '${h_url}' is not one of this app's domains — a project file cannot aim the server's prober elsewhere")
            else
                local cur_url cur_expect cur_grace cur_pd cur_rb
                cur_url=$(app_get "$app" health_url)
                cur_expect=$(app_get "$app" health_expect); [[ -n "$cur_expect" ]] || cur_expect=200
                cur_grace=$(app_get "$app" health_grace)
                cur_pd="true";  [[ "$(app_get "$app" health_postdeploy)" == "false" ]] && cur_pd="false"
                cur_rb="false"; [[ "$(app_get "$app" health_rollback)" == "true" ]] && cur_rb="true"
                if [[ "$cur_url" != "$h_url" || "$cur_expect" != "$h_expect" \
                      || "$cur_grace" != "$h_grace" || "$cur_pd" != "$h_pd" || "$cur_rb" != "$h_rb" ]]; then
                    local desc="healthcheck ${h_url} (expect ${h_expect}"
                    [[ -n "$h_grace" ]] && desc="${desc}, grace ${h_grace}s"
                    [[ "$h_pd" == "false" ]] && desc="${desc}, no post-deploy check"
                    [[ "$h_rb" == "true" ]] && desc="${desc}, AUTO-ROLLBACK on failure"
                    desc="${desc})"
                    _YML_ACTIONS+=("health|${h_url}|${h_expect}|${h_grace}|${h_pd}|${h_rb}|${desc}")
                fi
            fi
        fi
    fi

    # ── post-deploy steps (run after every deploy — not server state to reconcile)
    if echo "$_YML_DATA" | jq -e '.deploy.post | length > 0' &>/dev/null; then
        local n on_fail step_line run argc
        n=$(echo "$_YML_DATA" | jq '.deploy.post | length')
        on_fail=$(echo "$_YML_DATA" | jq -r '.deploy.post_on_failure // "warn"')
        _YML_NOTES+=("${n} post-deploy step(s) will run after every successful deploy (post_on_failure: ${on_fail})")
        while IFS= read -r step_line; do
            [[ -n "$step_line" ]] || continue
            run=$(echo "$step_line" | jq -r '.run')
            argc=$(echo "$step_line" | jq -r '[.argv[]?] | join(" ")')
            _YML_NOTES+=("  → ${run} ${argc}")
        done < <(echo "$_YML_DATA" | jq -c '.deploy.post[]?')
    fi

    # ── backup profiles
    if echo "$_YML_DATA" | jq -e 'has("backup")' &>/dev/null; then
        if ! _bk_configured; then
            _YML_BLOCKERS+=("backup profiles are declared but backup is not configured — run: cipi backup configure")
        else
            local pname pjson
            while IFS= read -r pname; do
                [[ -n "$pname" ]] || continue
                pjson=$(echo "$_YML_DATA" | jq -c --arg n "$pname" '.backup.profiles[] | select(.name == $n)')
                local dests
                dests=$(echo "$pjson" | jq -r '.destinations[]?' 2>/dev/null || true)
                if grep -qx 's3' <<< "$dests" && ! _bk_has_s3; then
                    _YML_BLOCKERS+=("backup profile '${pname}' targets s3 but no bucket is configured")
                    continue
                fi
                if _bk_profile_exists "$pname"; then
                    _YML_ACTIONS+=("backup-profile|${pname}|update backup profile ${pname}")
                else
                    _YML_ACTIONS+=("backup-profile|${pname}|create backup profile ${pname}")
                fi
            done < <(echo "$_YML_DATA" | jq -r '.backup.profiles[]?.name')
        fi
    fi
}

_yml_print_plan() {
    echo -e "\n${BOLD}Plan for '${_YML_APP}'${NC} ${DIM}(${_YML_FILE})${NC}\n"
    if [[ ${#_YML_BLOCKERS[@]} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}Blocked${NC}"
        local b
        for b in "${_YML_BLOCKERS[@]}"; do echo -e "    ${RED}✗${NC} ${b}"; done
        echo ""
    fi
    if [[ ${#_YML_NOTES[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}After deploy${NC}"
        local n
        for n in "${_YML_NOTES[@]}"; do echo -e "    ${DIM}•${NC} ${n}"; done
        echo ""
    fi
    if [[ ${#_YML_ACTIONS[@]} -eq 0 ]]; then
        if [[ ${#_YML_BLOCKERS[@]} -eq 0 ]]; then
            echo -e "  ${GREEN}Nothing to do — the server already matches cipi.yml.${NC}\n"
        fi
        return 0
    fi
    echo -e "  ${BOLD}Would change${NC}"
    local a desc
    for a in "${_YML_ACTIONS[@]}"; do
        desc="${a##*|}"
        echo -e "    ${CYAN}→${NC} ${desc}"
    done
    echo ""
}

# Load the libraries a plan or an apply needs. Each is loaded at most once:
# several of them declare readonly constants, and re-sourcing one mid-run would
# abort the command under `set -e`.
_yml_source_libs() {
    # shellcheck source=/dev/null
    declare -f db_create_database   >/dev/null 2>&1 || source "${CIPI_LIB}/db.sh"
    # shellcheck source=/dev/null
    declare -f _bk_profile_save     >/dev/null 2>&1 || source "${CIPI_LIB}/backup.sh"
    [[ "${1:-}" == "--with-app" ]] || return 0
    # shellcheck source=/dev/null
    declare -f _create_fpm_pool     >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
    # shellcheck source=/dev/null
    declare -f _horizon_enable      >/dev/null 2>&1 || source "${CIPI_LIB}/worker.sh"
    # shellcheck source=/dev/null
    declare -f _ini_set             >/dev/null 2>&1 || source "${CIPI_LIB}/ini.sh"
    # shellcheck source=/dev/null
    declare -f _health_set          >/dev/null 2>&1 || source "${CIPI_LIB}/health.sh"
}

_yml_plan_cmd() {
    local app="${1:-}"; shift||true
    parse_args "$@"
    _yml_resolve "$app"
    _yml_source_libs
    _yml_load || exit 1
    _yml_build_plan
    _yml_print_plan
    [[ ${#_YML_BLOCKERS[@]} -gt 0 ]] && return 1
    return 0
}

# Is this URL served by the app itself?
#
# The healthcheck URL is fetched by the server every five minutes and after
# every deploy, and the resulting status code comes back in alert emails. Left
# unrestricted, a project file could point it at anything reachable from the
# server — an internal address, another tenant — and read the answer out of the
# notifications. Restricting it to the app's own primary domain and aliases is
# both the safe rule and the only one that makes sense for a healthcheck.
_yml_url_belongs_to_app() {
    local app="$1" url="$2" host allowed a
    [[ -n "$url" ]] || return 1
    host="${url#*://}"; host="${host%%/*}"; host="${host%%:*}"
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    [[ -n "$host" ]] || return 1

    allowed=$(app_get "$app" domain)$'\n'
    allowed="${allowed}$(vault_read apps.json | jq -r --arg a "$app" '(.[$a].aliases // [])[]' 2>/dev/null || true)"

    while IFS= read -r a; do
        [[ -n "$a" ]] || continue
        a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')
        [[ "$host" == "$a" ]] && return 0
        # A wildcard alias covers its subdomains, one level deep, as nginx does.
        if [[ "$a" == \*.* ]]; then
            local base="${a#\*.}"
            [[ "$host" == *."$base" ]] && return 0
            [[ "$host" == "$base" ]] && return 0
        fi
    done <<< "$allowed"
    return 1
}

# ── Apply ────────────────────────────────────────────────────

_yml_apply_cmd() {
    local app="${1:-}"; shift||true
    parse_args "$@"
    local auto="${ARG_auto:-}"

    # --auto is the unattended, post-deploy path. Both of its gates are checked
    # before anything else, so the answer never depends on whether a file
    # happens to be present:
    #   1. the app must have opted in (cipi yml auto <app> on);
    #   2. a release without a cipi.yml is simply nothing to reconcile — asked
    #      for explicitly, a missing file stays an error.
    if [[ "$auto" == "true" ]]; then
        [[ -z "$app" ]] && { error "Usage: cipi yml apply <app>"; exit 1; }
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        if [[ "$(app_get "$app" yml_auto)" != "true" ]]; then
            error "Automatic cipi.yml apply is not enabled for '${app}'"
            error "Turn it on with: cipi yml auto ${app} on"
            exit 1
        fi
        if [[ -z "${ARG_file:-}" ]] && ! _yml_find_file "$app" >/dev/null; then
            info "No cipi.yml in the current release of '${app}' — nothing to reconcile"
            return 0
        fi
    fi

    _yml_resolve "$app"
    _yml_source_libs --with-app

    if ! _yml_load "$([[ "$auto" == "true" ]] && echo true || echo false)"; then
        [[ "$auto" == "true" ]] && cipi_notify \
            "Cipi cipi.yml invalid: ${_YML_APP} on $(hostname)" \
            "The cipi.yml shipped with the latest release of '${_YML_APP}' failed validation and was not applied.\n\nServer: $(hostname)\nFile: ${_YML_FILE}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nRun: cipi yml validate ${_YML_APP}" \
            yml_fail
        exit 1
    fi

    _yml_build_plan

    if [[ ${#_YML_BLOCKERS[@]} -gt 0 ]]; then
        _yml_print_plan
        error "Nothing was applied — resolve the blocking items above first."
        [[ "$auto" == "true" ]] && cipi_notify \
            "Cipi cipi.yml blocked: ${_YML_APP} on $(hostname)" \
            "cipi.yml for '${_YML_APP}' could not be applied.\n\nServer: $(hostname)\nBlocked by:\n$(printf '  - %s\n' "${_YML_BLOCKERS[@]}")\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            yml_fail
        exit 1
    fi

    if [[ ${#_YML_ACTIONS[@]} -eq 0 ]]; then
        [[ "$auto" == "true" ]] || success "Nothing to do — the server already matches cipi.yml"
        return 0
    fi

    if [[ "${ARG_yes:-}" != "true" ]]; then
        _yml_print_plan
        if [[ -t 0 ]]; then
            confirm "Apply these changes to '${_YML_APP}'?" || { info "Cancelled"; return 0; }
        else
            error "Refusing to apply without confirmation. Re-run with --yes."
            exit 1
        fi
    fi

    local applied=0 failed=0 a kind
    for a in "${_YML_ACTIONS[@]}"; do
        kind="${a%%|*}"
        if _yml_apply_action "$a"; then
            ((applied++)) || true
        else
            ((failed++)) || true
            error "  failed: ${a##*|}"
        fi
    done

    echo ""
    if [[ $failed -eq 0 ]]; then
        success "Applied ${applied} change(s) from cipi.yml"
        log_action "YML APPLY: ${_YML_APP} applied=${applied}"
        cipi_notify \
            "Cipi cipi.yml applied: ${_YML_APP} on $(hostname)" \
            "cipi.yml was applied.\n\nServer: $(hostname)\nApp: ${_YML_APP}\nFile: ${_YML_FILE}\nChanges: ${applied}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
            yml_apply
        return 0
    fi
    error "Applied ${applied} change(s), ${failed} failed"
    log_action "YML APPLY: ${_YML_APP} applied=${applied} failed=${failed}"
    cipi_notify \
        "Cipi cipi.yml partially applied: ${_YML_APP} on $(hostname)" \
        "cipi.yml was applied with errors.\n\nServer: $(hostname)\nApp: ${_YML_APP}\nApplied: ${applied}\nFailed: ${failed}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        yml_fail
    return 1
}

_yml_apply_action() {
    local spec="$1" app="$_YML_APP"
    local kind; kind="${spec%%|*}"
    local rest; rest="${spec#*|}"

    case "$kind" in
        php)
            local ver="${rest%%|*}"
            step "PHP → ${ver}"
            app_edit "$app" "--php=${ver}" >/dev/null
            ;;
        alias-add)
            local dom="${rest%%|*}"
            step "alias + ${dom}"
            alias_add "$app" "$dom" >/dev/null
            ;;
        alias-remove)
            local dom="${rest%%|*}"
            step "alias - ${dom}"
            alias_remove "$app" "$dom" >/dev/null
            ;;
        ini)
            local pair="${rest%%|*}"
            step "php.ini ${pair}"
            _ini_set "$pair" "--app=${app}" >/dev/null
            ;;
        ini-unset)
            local key="${rest%%|*}"
            step "php.ini unset ${key}"
            _ini_unset "$key" "--app=${app}" >/dev/null
            ;;
        db)
            local name="${rest%%|*}"; rest="${rest#*|}"
            local engine="${rest%%|*}"
            step "database ${name} (${engine})"
            _yml_create_database "$name" "$engine"
            ;;
        horizon)
            local mode="${rest%%|*}"
            step "horizon ${mode}"
            if [[ "$mode" == "on" ]]; then _horizon_enable "$app" >/dev/null
            else _horizon_disable "$app" >/dev/null; fi
            ;;
        reverb)
            local mode="${rest%%|*}"
            step "reverb ${mode}"
            # Not silenced: enabling prints the credentials it generated, the
            # ws:// vs wss:// it settled on, and whether Supervisor still needs
            # a restart to lift its open-file limit.
            if [[ "$mode" == "on" ]]; then _app_reverb_enable "$app"
            else _app_reverb_disable "$app"; fi
            ;;
        worker-add|worker-sync)
            local q procs tries timeout
            q="${rest%%|*}"; rest="${rest#*|}"
            procs="${rest%%|*}"; rest="${rest#*|}"
            tries="${rest%%|*}"; rest="${rest#*|}"
            timeout="${rest%%|*}"
            step "worker ${q} (${procs} process(es))"
            _supervisor_remove_program "$app" "${app}-worker-${q}"
            _create_supervisor_worker "$app" "$(app_get "$app" php)" "$q" "$procs" "$tries" "$timeout"
            reload_supervisor || true
            supervisorctl start "${app}-worker-${q}:*" &>/dev/null || true
            ;;
        worker-remove)
            local q="${rest%%|*}"
            step "worker remove ${q}"
            supervisorctl stop "${app}-worker-${q}:*" &>/dev/null || true
            _supervisor_remove_program "$app" "${app}-worker-${q}"
            reload_supervisor || true
            ;;
        schedule)
            local mode="${rest%%|*}"
            step "scheduler ${mode}"
            if [[ "$mode" == "true" ]]; then _schedule_set on "$app" >/dev/null
            else _schedule_set off "$app" >/dev/null; fi
            ;;
        health)
            local h_url h_expect h_grace h_pd h_rb
            h_url="${rest%%|*}";    rest="${rest#*|}"
            h_expect="${rest%%|*}"; rest="${rest#*|}"
            h_grace="${rest%%|*}";  rest="${rest#*|}"
            h_pd="${rest%%|*}";     rest="${rest#*|}"
            h_rb="${rest%%|*}"
            step "healthcheck ${h_url}"
            local -a hargs=( "--url=${h_url}" "--expect=${h_expect}" )
            [[ -n "$h_grace" ]] && hargs+=( "--grace=${h_grace}" )
            # Always pass the explicit form of both switches, so applying the
            # file converges on exactly what it declares rather than inheriting
            # whatever the app happened to have.
            if [[ "$h_pd" == "false" ]]; then hargs+=( "--no-postdeploy" ); else hargs+=( "--postdeploy" ); fi
            if [[ "$h_rb" == "true" ]]; then hargs+=( "--rollback-on-unhealthy" ); else hargs+=( "--no-rollback-on-unhealthy" ); fi
            declare -f _health_set >/dev/null 2>&1 || source "${CIPI_LIB}/health.sh"
            _health_set "$app" "${hargs[@]}" >/dev/null
            ;;
        health-unset)
            step "healthcheck removed"
            declare -f _health_unset >/dev/null 2>&1 || source "${CIPI_LIB}/health.sh"
            _health_unset "$app" >/dev/null
            ;;
        backup-profile)
            local pname="${rest%%|*}"
            step "backup profile ${pname}"
            _yml_apply_backup_profile "$pname"
            ;;
        *)
            error "Unknown plan action: ${kind}"
            return 1
            ;;
    esac
}

# Create a declared database and hand its credentials to the app rather than
# printing them: the .env in shared/ is where the app will look for them.
_yml_create_database() {
    local name="$1" engine="$2" app="$_YML_APP"
    local pass; pass=$(generate_password 40)
    db_create_database "$engine" "$name" "$name" "$pass" || return 1
    _db_meta_set "$engine" "$name" "$name"
    log_action "YML DB CREATED: ${name} (${engine}) for ${app}"

    # Credentials go to a root-readable file next to the app's .env; writing
    # them into .env itself would guess at variable names the app may not use.
    local out="/home/${app}/shared/cipi-databases.env"
    if [[ -d "/home/${app}/shared" ]]; then
        local upper; upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
        touch "$out"
        chown "${app}:${app}" "$out"
        chmod 600 "$out"
        grep -v "^${upper}_DB_" "$out" > "${out}.tmp" 2>/dev/null || true
        mv "${out}.tmp" "$out" 2>/dev/null || true
        {
            printf '%s_DB_CONNECTION=%s\n' "$upper" "$(db_engine_laravel_connection "$engine")"
            printf '%s_DB_HOST=127.0.0.1\n' "$upper"
            printf '%s_DB_PORT=%s\n' "$upper" "$(db_engine_port "$engine")"
            printf '%s_DB_DATABASE=%s\n' "$upper" "$name"
            printf '%s_DB_USERNAME=%s\n' "$upper" "$name"
            printf '%s_DB_PASSWORD=%s\n' "$upper" "$pass"
        } >> "$out"
        chown "${app}:${app}" "$out"
        chmod 600 "$out"
        info "  credentials written to ${out}"
    else
        warn "  no shared/ directory — credentials: user=${name} password=${pass}"
    fi
    cipi_notify \
        "Cipi database created: ${name} (${engine}) on $(hostname)" \
        "A database declared in cipi.yml was created.\n\nServer: $(hostname)\nApp: ${app}\nEngine: ${engine}\nDatabase: ${name}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        db_create
    return 0
}

_yml_apply_backup_profile() {
    local pname="$1"
    local spec; spec=$(echo "$_YML_DATA" | jq -c --arg n "$pname" '.backup.profiles[] | select(.name == $n)')
    [[ -z "$spec" ]] && return 1

    local base
    if _bk_profile_exists "$pname"; then
        base=$(_bk_profile_json "$pname")
    else
        base=$(_bk_default_profile_json)
    fi

    local json="$base"
    json=$(echo "$json" | jq --argjson s "$spec" '
        .scope        = ($s.scope // .scope)
        | .databases  = ($s.databases // .databases)
        | .exclude_databases = ($s.exclude_databases // .exclude_databases)
        | .exclude_tables    = ($s.exclude_tables // .exclude_tables)
        | .destinations      = ($s.destinations // .destinations)
        | .encrypt           = (if ($s | has("encrypt")) then $s.encrypt else .encrypt end)
        | .retention         = ($s.retention // .retention)
        | .enabled           = true
    ')

    # Schedule: "every" is translated here so the stored profile always carries
    # both the cron line and the interval the staleness check needs.
    local every cron
    every=$(echo "$spec" | jq -r '.every // empty')
    cron=$(echo "$spec" | jq -r '.cron // empty')
    if [[ -n "$every" ]]; then
        local es; es=$(_bk_every_to_cron "$every") || return 1
        json=$(echo "$json" | jq --arg c "${es#*$'\t'}" --argjson i "${es%%$'\t'*}" \
            '.cron = $c | .interval_seconds = $i')
    elif [[ -n "$cron" ]]; then
        _bk_valid_cron "$cron" || return 1
        json=$(echo "$json" | jq --arg c "$cron" --argjson i "$(_bk_cron_interval_seconds "$cron")" \
            '.cron = $c | .interval_seconds = $i')
    fi

    if [[ "$(echo "$json" | jq -r '.encrypt')" == "true" ]]; then
        _bk_key_ensure || return 1
    fi

    _bk_profile_save "$pname" "$json"

    # Remember which profiles this app owns, so they can be cleaned up with it.
    local owned; owned=$(vault_read apps.json | jq --arg a "$_YML_APP" '(.[$a].backup_profiles // [])')
    app_set_json "$_YML_APP" backup_profiles \
        "$(echo "$owned" | jq --arg p "$pname" '. + [$p] | unique')"
    return 0
}

# ── Post-deploy steps (deploy.post) ──────────────────────────
#
# Runs allowlisted commands from cipi.yml after a release goes live. Unlike
# `apply`, this is not server reconciliation — it executes every time the file
# declares steps, on both `cipi deploy` and the webhook path.

_yml_post_deploy_workdir() {
    local app="$1" home="/home/${app}" wd="$home"
    if [[ -d "${home}/current" ]]; then
        wd="${home}/current"
    elif [[ -d "${home}/htdocs" ]]; then
        wd="${home}/htdocs"
    fi
    echo "$wd"
}

_yml_post_deploy_is_custom() {
    local app="$1" home="/home/${app}"
    [[ ! -f "${home}/current/artisan" && -d "${home}/htdocs" ]]
}

# Run one validated step. $1=as (root|self) $2=app $3=php_ver $4=run $5+=argv
_yml_post_deploy_exec() {
    local as="$1" app="$2" php_ver="$3" run="$4"; shift 4
    local -a argv=("$@") wd cmd_q args_q
    wd=$(_yml_post_deploy_workdir "$app")
    local -a env=(CI=true DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat COMPOSER_NO_INTERACTION=1 NPM_CONFIG_YES=true)

    case "$run" in
        artisan)
            if _yml_post_deploy_is_custom "$app"; then
                warn "  skip artisan (custom app)"
                return 0
            fi
            [[ -f "${wd}/artisan" ]] || { error "  artisan not found in ${wd}"; return 1; }
            cmd_q=$(printf '%q' "/usr/bin/php${php_ver}")
            args_q="artisan"
            local a
            for a in "${argv[@]}"; do args_q+=" $(printf '%q' "$a")"; done
            ;;
        npm|npx|yarn|pnpm|composer|php|node)
            cmd_q=$(printf '%q' "$run")
            args_q=""
            for a in "${argv[@]}"; do args_q+=" $(printf '%q' "$a")"; done
            ;;
        *)
            error "  unknown runner: ${run}"
            return 1
            ;;
    esac

    local inner="cd $(printf '%q' "$wd") && exec ${cmd_q}${args_q}"
    if [[ "$as" == "self" ]]; then
        env "${env[@]}" bash -c "$inner"
    else
        sudo -u "$app" env "${env[@]}" bash -c "$inner"
    fi
}

# Echo a one-line summary on stdout; return the step runner's exit code.
# $1=app $2=php_ver $3=log_file (optional) $4=quiet (true for --auto webhook)
# $5=as (root|self — who invokes the runners; default root)
_yml_post_deploy_run() {
    local app="$1" php_ver="$2" lf="${3:-}" quiet="${4:-false}" as="${5:-root}"
    local file result steps n on_fail i run line rc=0 failed=0 step_rc
    local -a argv=()

    file=$(_yml_find_file "$app") || { echo "none declared"; return 0; }

    result=$(_yml_parse "$file" "$app") || { echo "invalid cipi.yml"; return 1; }
    [[ "$(echo "$result" | jq -r '.ok')" == "true" ]] || { echo "invalid cipi.yml"; return 1; }

    steps=$(echo "$result" | jq -c '.data.deploy.post // []')
    n=$(echo "$steps" | jq 'length')
    [[ "$n" -gt 0 ]] || { echo "none declared"; return 0; }

    on_fail=$(echo "$result" | jq -r '.data.deploy.post_on_failure // "warn"')

    _yml_post_deploy_log() {
        [[ -n "$lf" ]] && printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$1" >> "$lf" 2>/dev/null || true
        [[ "$quiet" != "true" ]] && printf '%s\n' "$1"
    }

    _yml_post_deploy_log "===== post-deploy steps (${n}, post_on_failure=${on_fail}) ====="

    for ((i=0; i<n; i++)); do
        run=$(echo "$steps" | jq -r ".[$i].run")
        mapfile -t argv < <(echo "$steps" | jq -r ".[$i].argv[]?")
        line="${run} ${argv[*]}"
        [[ "$quiet" != "true" ]] && step "Post-deploy [$((i+1))/${n}]: ${line}"
        _yml_post_deploy_log "post-deploy [$((i+1))/${n}]: ${line}"

        step_rc=0
        if ! _yml_post_deploy_exec "$as" "$app" "$php_ver" "$run" "${argv[@]}" >>"${lf:-/dev/null}" 2>&1; then
            step_rc=$?
            ((failed++)) || true
            _yml_post_deploy_log "post-deploy FAILED (${step_rc}): ${line}"
            [[ "$quiet" != "true" ]] && error "  failed (exit ${step_rc}): ${line}"
            if [[ "$on_fail" == "abort" ]]; then
                cipi_notify \
                    "Cipi post-deploy failed: ${app} on $(hostname)" \
                    "A post-deploy step declared in cipi.yml failed and post_on_failure is 'abort'.\n\nServer: $(hostname)\nApp: ${app}\nStep: ${line}\nExit: ${step_rc}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nDeploy log: ${lf:-/home/${app}/logs/deploy.log}" \
                    yml_post_fail 2>/dev/null || true
                echo "${failed} of ${n} failed (abort)"
                return "$step_rc"
            fi
            rc=1
        else
            _yml_post_deploy_log "post-deploy OK: ${line}"
        fi
    done

    if [[ $failed -eq 0 ]]; then
        echo "${n} step(s) OK"
        return 0
    fi
    cipi_notify \
        "Cipi post-deploy failed: ${app} on $(hostname)" \
        "One or more post-deploy steps declared in cipi.yml failed (post_on_failure: warn — deploy left live).\n\nServer: $(hostname)\nApp: ${app}\nFailed: ${failed} of ${n}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nDeploy log: ${lf:-/home/${app}/logs/deploy.log}" \
        yml_post_fail 2>/dev/null || true
    echo "${failed} of ${n} failed (warn)"
    return "$rc"
}

_yml_post_deploy_cmd() {
    local app="${1:-}"; shift||true
    parse_args "$@"
    local auto="${ARG_auto:-}" quiet="false"
    [[ "$auto" == "true" ]] && quiet="true"
    [[ -z "$app" ]] && { error "Usage: cipi yml post-deploy <app> [--auto]"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    local php_ver; php_ver=$(app_get "$app" php)
    [[ -n "$php_ver" ]] || { error "App '${app}' has no PHP version configured"; exit 1; }
    local lf="/home/${app}/logs/deploy.log"
    local summary rc=0
    summary=$(_yml_post_deploy_run "$app" "$php_ver" "$lf" "$quiet") || rc=$?
    [[ "$quiet" == "true" ]] || success "Post-deploy: ${summary}"
    return "$rc"
}

# ── Automatic apply after deploy ─────────────────────────────

_yml_auto_cmd() {
    local app="${1:-}" mode="${2:-status}"
    [[ -z "$app" ]] && { error "Usage: cipi yml auto <app> on|off|status"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    local sudoers="/etc/sudoers.d/cipi-${app}-yml"

    case "$mode" in
        on|enable)
            # The deploy trigger runs as the app user, so applying after a
            # deploy needs exactly one narrowly scoped sudo rule — that command
            # line and no other.
            cat > "$sudoers" <<SUDO
${app} ALL=(root) NOPASSWD: /usr/local/bin/cipi yml apply ${app} --yes --auto
SUDO
            chmod 440 "$sudoers"
            if ! visudo -cf "$sudoers" &>/dev/null; then
                rm -f "$sudoers"
                error "sudoers rule rejected — automatic apply not enabled"
                exit 1
            fi
            app_set "$app" yml_auto "true"
            success "cipi.yml will be applied after every successful deploy of '${app}'"
            info "Both paths: 'cipi deploy ${app}' and the Git webhook."
            warn "Anyone who can commit to the repository can now change this app's"
            warn "aliases, PHP settings, workers, databases and backup schedule."
            log_action "YML AUTO ON: $app"
            ;;
        off|disable)
            rm -f "$sudoers"
            app_unset "$app" yml_auto
            success "Automatic cipi.yml apply disabled for '${app}'"
            log_action "YML AUTO OFF: $app"
            ;;
        status)
            echo -e "\n${BOLD}cipi.yml for '${app}'${NC}"
            local f
            if f=$(_yml_find_file "$app"); then
                printf "  %-16s %s\n" "File" "$f"
            else
                printf "  %-16s ${DIM}%s${NC}\n" "File" "not present in the current release"
            fi
            if [[ "$(app_get "$app" yml_auto)" == "true" ]]; then
                printf "  %-16s ${GREEN}%s${NC}\n" "Auto-apply" "on — after every successful deploy (CLI and webhook)"
            else
                printf "  %-16s ${DIM}%s${NC}\n" "Auto-apply" "off — deploys ignore the file"
                printf "  %-16s ${DIM}%s${NC}\n" "" "apply by hand: cipi yml apply ${app}"
                printf "  %-16s ${DIM}%s${NC}\n" "" "or turn it on:  cipi yml auto ${app} on"
            fi
            echo ""
            ;;
        *) error "Use: cipi yml auto <app> on|off|status"; exit 1 ;;
    esac
}

# ── Generate ─────────────────────────────────────────────────
#
# Print the cipi.yml that describes an app as it is configured *right now*, so
# it can be pasted into the repository instead of written from scratch. This is
# the reverse of `apply`: read the live server, emit the declaration. Running
# `cipi yml plan` against freshly generated output should report no changes.

# Emit a YAML scalar, quoting whenever a plain one would be misread — a leading
# "*" is an alias, "8.5" is a float, "on"/"off"/"no" are booleans.
_yml_q() {
    local v="$1" lower
    if [[ -z "$v" ]]; then echo '""'; return; fi
    lower=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        true|false|on|off|yes|no|null|~) printf '"%s"\n' "$v"; return ;;
    esac
    if [[ "$v" =~ ^[A-Za-z][A-Za-z0-9._/-]*$ ]]; then
        printf '%s\n' "$v"
        return
    fi
    printf '"%s"\n' "${v//\"/\\\"}"
}

# "a,b" → [ "a", "b" ] on one line.
_yml_flow() {
    local out="" item
    for item in "$@"; do
        [[ -n "$item" ]] || continue
        out="${out}${out:+, }$(_yml_q "$item")"
    done
    printf '[%s]\n' "$out"
}

# Turn a stored cron expression back into the friendlier `every:` form when it
# maps cleanly onto one; otherwise the caller keeps the cron line.
_yml_cron_to_every() {
    local expr="$1" min hour dom mon dow
    read -r min hour dom mon dow <<< "$expr"
    [[ "$mon" == "*" && "$dow" == "*" ]] || return 1
    if [[ "$min" =~ ^\*/([0-9]+)$ && "$hour" == "*" && "$dom" == "*" ]]; then
        echo "${BASH_REMATCH[1]}m"; return 0
    fi
    if [[ "$min" == "0" && "$hour" =~ ^\*/([0-9]+)$ && "$dom" == "*" ]]; then
        echo "${BASH_REMATCH[1]}h"; return 0
    fi
    if [[ "$min" == "0" && "$hour" == "2" && "$dom" == "*" ]]; then
        echo "1d"; return 0
    fi
    if [[ "$min" == "0" && "$hour" == "2" && "$dom" =~ ^\*/([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}d"; return 0
    fi
    return 1
}

# Queue workers as "<queue>\t<procs>\t<tries>\t<timeout>", read back out of the
# supervisor program Cipi wrote for them.
_yml_read_workers() {
    local app="$1"
    local conf="/etc/supervisor/conf.d/${app}.conf"
    [[ -f "$conf" ]] || return 0
    awk -v app="$app" '
        $0 ~ "^\\[program:" app "-worker-" {
            if (queue != "") print queue "\t" procs "\t" tries "\t" timeout
            queue = $0
            sub("^\\[program:" app "-worker-", "", queue)
            sub("\\]$", "", queue)
            procs = 1; tries = 3; timeout = 3600
            next
        }
        /^\[program:/ {
            if (queue != "") print queue "\t" procs "\t" tries "\t" timeout
            queue = ""
            next
        }
        queue != "" && /^numprocs=/ { procs = substr($0, 10) }
        queue != "" && /--tries=/ {
            t = $0; sub(/.*--tries=/, "", t); sub(/[^0-9].*/, "", t); if (t != "") tries = t
        }
        queue != "" && /--max-time=/ {
            t = $0; sub(/.*--max-time=/, "", t); sub(/[^0-9].*/, "", t); if (t != "") timeout = t
        }
        END { if (queue != "") print queue "\t" procs "\t" tries "\t" timeout }
    ' "$conf"
}

_yml_generate() {
    local app="${1:-}"; shift||true
    [[ -z "$app" ]] && { error "Usage: cipi yml generate <app>"; exit 1; }
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    _yml_source_libs

    local out; out=$(mktemp)
    local domain php custom
    domain=$(app_get "$app" domain)
    php=$(app_get "$app" php)
    custom=$(app_get "$app" custom)

    {
        echo "# cipi.yml for '${app}' (${domain}) — generated on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# by: cipi yml generate ${app}"
        echo "#"
        echo "# This is the app's configuration as it stands on $(hostname) right now."
        echo "# Commit it at the root of the repository, then check it back with:"
        echo "#     cipi yml plan ${app}      (should report nothing to do)"
        echo "#"
        echo "# Not covered here, on purpose: the primary domain, the app's own"
        echo "# database, SSL certificates and anything else that is not safe to"
        echo "# drive from a file living in the repository."
        echo ""
        echo "version: 1"
        echo ""
        echo "app:"
        echo "  php: $(_yml_q "$php")"

        # ── aliases
        local aliases; aliases=$(vault_read apps.json | jq -r --arg a "$app" '(.[$a].aliases // [])[]' 2>/dev/null || true)
        if [[ -n "$aliases" ]]; then
            echo ""
            echo "  # The declared list replaces the current aliases: removing one here"
            echo "  # removes it from the server on the next apply."
            echo "  aliases:"
            local al
            while IFS= read -r al; do
                [[ -n "$al" ]] || continue
                echo "    - $(_yml_q "$al")"
            done <<< "$aliases"
        else
            echo ""
            echo "  # No aliases configured. Uncomment to declare some:"
            echo "  # aliases:"
            echo "  #   - \"www.${domain}\""
        fi

        # ── per-app php.ini overrides
        local ini_pairs; ini_pairs=$(vault_read apps.json | jq -r --arg a "$app" \
            '(.[$a].ini // {}) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null || true)
        if [[ -n "$ini_pairs" ]]; then
            echo ""
            echo "  ini:"
            local k v
            while IFS=$'\t' read -r k v; do
                [[ -n "$k" ]] || continue
                echo "    ${k}: $(_yml_q "$v")"
            done <<< "$ini_pairs"
        else
            echo ""
            echo "  # No per-app php.ini overrides. This app follows the server-wide"
            echo "  # values (cipi ini list --app=${app}). Uncomment to pin some here:"
            echo "  # ini:"
            echo "  #   upload_max_filesize: 50M"
            echo "  #   post_max_size: 60M"
        fi

        # ── databases the app owns, beyond the one created with it
        local dbs="" eng db
        for eng in mariadb pgsql; do
            db_engine_is_installed "$eng" 2>/dev/null || continue
            while IFS= read -r db; do
                [[ -n "$db" ]] || continue
                [[ "$db" == "$app" ]] && continue
                [[ "$db" == "${app}_"* ]] || continue
                dbs="${dbs}${db}	${eng}"$'\n'
            done < <(db_list_databases "$eng" 2>/dev/null || true)
        done
        echo ""
        if [[ -n "$dbs" ]]; then
            echo "# Extra databases owned by this app. The app's own database ('${app}')"
            echo "# is created with the app and is deliberately not managed here."
            echo "databases:"
            while IFS=$'\t' read -r db eng; do
                [[ -n "$db" ]] || continue
                echo "  - name: $(_yml_q "$db")"
                echo "    engine: ${eng}"
            done <<< "$dbs"
        else
            echo "# No extra databases. A declared database must be named '${app}' or"
            echo "# '${app}_*' — nothing outside this app's namespace is accepted."
            echo "# databases:"
            echo "#   - name: ${app}_reporting"
        fi

        # ── workers
        local horizon workers reverb
        horizon=$(app_get "$app" horizon)
        workers=$(_yml_read_workers "$app")
        reverb="false"; [[ -n "$(app_get "$app" reverb)" ]] && reverb="true"
        echo ""
        echo "workers:"
        if [[ "$horizon" == "true" ]]; then
            echo "  horizon: true"
            [[ -n "$workers" ]] && echo "  # (queue workers are replaced by Horizon while it is on)"
        elif [[ -n "$workers" ]]; then
            echo "  horizon: false"
            echo "  queues:"
            local q procs tries timeout
            while IFS=$'\t' read -r q procs tries timeout; do
                [[ -n "$q" ]] || continue
                echo "    - queue: $(_yml_q "$q")"
                echo "      processes: ${procs:-1}"
                [[ "${tries:-3}" != "3" ]] && echo "      tries: ${tries}"
                [[ "${timeout:-3600}" != "3600" ]] && echo "      timeout: ${timeout}"
            done <<< "$workers"
        else
            echo "  horizon: false"
            echo "  # No queue workers configured. Uncomment to declare some:"
            echo "  # queues:"
            echo "  #   - queue: default"
            echo "  #     processes: 2"
        fi
        if [[ "$custom" != "true" ]]; then
            if [[ "$reverb" == "true" ]]; then
                echo "  # Laravel Reverb — nginx proxies /app and /apps to it on this domain."
                echo "  reverb: true"
            else
                echo "  reverb: false          # true adds a Reverb WebSocket server"
            fi
        fi

        # ── scheduler
        if [[ "$custom" != "true" ]]; then
            local sched="false"
            crontab -u "$app" -l 2>/dev/null | grep -qE '^\* \* \* \* \*.*schedule:run' && sched="true"
            echo ""
            echo "# Laravel scheduler (* * * * * artisan schedule:run)"
            echo "schedule: ${sched}"
        fi

        # ── healthcheck
        local hu he hg hpd hrb
        hu=$(app_get "$app" health_url)
        echo ""
        if [[ -n "$hu" ]]; then
            he=$(app_get "$app" health_expect); [[ -n "$he" ]] || he=200
            hg=$(app_get "$app" health_grace)
            hpd=$(app_get "$app" health_postdeploy)
            hrb=$(app_get "$app" health_rollback)
            echo "# Checked every 5 minutes and right after every deploy."
            echo "health:"
            echo "  url: $(_yml_q "$hu")"
            echo "  expect: ${he}"
            [[ -n "$hg" ]] && echo "  grace: ${hg}          # seconds to wait before the first probe"
            [[ "$hpd" == "false" ]] && echo "  postdeploy: false"
            if [[ "$hrb" == "true" ]]; then
                echo "  rollback_on_unhealthy: true   # undo a release that fails the check"
            fi
        else
            echo "# No healthcheck configured. The URL must be one of this app's own"
            echo "# domains. Uncomment to add one:"
            echo "# health:"
            echo "#   url: \"https://${domain}/up\""
            echo "#   expect: 200"
        fi

        # ── post-deploy steps (only from an existing cipi.yml in the release)
        echo ""
        echo "# Post-deploy commands (run after every successful deploy)."
        echo "# Uncomment and edit — or declare them here and commit:"
        echo "# deploy:"
        echo "#   post:"
        echo "#     - artisan cache:clear"
        echo "#     - npm run build"

        # ── backup profiles this app owns
        local owned="" p
        if _bk_configured; then
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                [[ "$p" == "$app" || "$p" == "${app}-"* ]] || continue
                owned="${owned}${p}"$'\n'
            done < <(_bk_profile_names)
        fi

        echo ""
        if [[ -n "$owned" ]]; then
            echo "backup:"
            echo "  profiles:"
            local scope enc every cron ret_keep ret_days ret_weeks
            while IFS= read -r p; do
                [[ -n "$p" ]] || continue
                scope=$(_bk_profile_get "$p" scope)
                cron=$(_bk_profile_get "$p" cron)
                enc=$(_bk_profile_get "$p" encrypt)
                echo "    - name: $(_yml_q "$p")"
                echo "      scope: ${scope}"

                local dbg exdbg extg
                dbg=$(_bk_profile_list_field "$p" databases | tr '\n' ' ')
                exdbg=$(_bk_profile_list_field "$p" exclude_databases | tr '\n' ' ')
                extg=$(_bk_profile_list_field "$p" exclude_tables | tr '\n' ' ')
                # shellcheck disable=SC2086
                [[ -n "${dbg// }"   ]] && echo "      databases: $(_yml_flow $dbg)"
                # shellcheck disable=SC2086
                [[ -n "${exdbg// }" ]] && echo "      exclude_databases: $(_yml_flow $exdbg)"
                # shellcheck disable=SC2086
                [[ -n "${extg// }"  ]] && echo "      exclude_tables: $(_yml_flow $extg)"

                if every=$(_yml_cron_to_every "$cron"); then
                    echo "      every: ${every}"
                else
                    echo "      cron: $(_yml_q "$cron")"
                fi

                local dests
                dests=$(_bk_profile_list_field "$p" destinations | tr '\n' ' ')
                # shellcheck disable=SC2086
                echo "      destinations: $(_yml_flow $dests)"
                [[ "$enc" == "true" ]] && echo "      encrypt: true"

                ret_keep=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.keep  // 0')
                ret_days=$(_bk_profiles_json  | jq -r --arg p "$p" '.[$p].retention.days  // 0')
                ret_weeks=$(_bk_profiles_json | jq -r --arg p "$p" '.[$p].retention.weeks // 0')
                [[ "$ret_keep"  -gt 0 ]] && echo "      keep: ${ret_keep}"
                [[ "$ret_days"  -gt 0 ]] && echo "      keep_days: ${ret_days}"
                [[ "$ret_weeks" -gt 0 ]] && echo "      keep_weeks: ${ret_weeks}"
            done <<< "$owned"
        else
            echo "# No backup profile belongs to this app yet. A profile declared here"
            echo "# must be named '${app}' or '${app}-*'; server-wide profiles such as"
            echo "# 'default' stay out of the repository on purpose."
            echo "# backup:"
            echo "#   profiles:"
            echo "#     - name: ${app}-db"
            echo "#       scope: db"
            echo "#       databases: [$(_yml_q "$app"), \"${app}_*\"]"
            echo "#       exclude_tables: [\"*.jobs\", \"*.telescope_*\"]"
            echo "#       every: 30m"
            echo "#       keep: 48"
            echo "#       destinations: [local]"
        fi
    } > "$out"

    # The generated file is fed straight back through the validator: emitting
    # something this same Cipi would reject is a bug, and better caught here
    # than after it has been committed.
    local check; check=$(_yml_parse "$out" "$app" 2>/dev/null || true)
    if [[ "$(echo "$check" | jq -r '.ok' 2>/dev/null)" != "true" ]]; then
        warn "The generated file did not pass validation — please report this:"
        echo "$check" | jq -r '.errors[]?' 2>/dev/null | sed 's/^/    /' >&2
        warn "It is printed below anyway so nothing is lost."
    fi

    cat "$out"
    rm -f "$out"
}

# `cipi yml example [app]` — a blank, commented template.
#
# Given an app name it is written in that app's namespace, so the output
# validates as-is. Without one the placeholders say "example", which would fail
# validation for any real app — the namespacing rules are not negotiable, and a
# template that trips over them on first use is a trap rather than a starting
# point.
_yml_example() {
    local app="${1:-example}" domain=""
    if [[ "$app" != "example" ]]; then
        validate_username "$app" || { error "Invalid app name: ${app}"; exit 1; }
        if app_exists "$app"; then
            domain=$(app_get "$app" domain)
        fi
    fi
    [[ -n "$domain" ]] || domain="example.com"

    cat <<YMLEXAMPLE
# cipi.yml — declarative configuration for one Cipi app.
#
# Commit this at the root of your repository. After a deploy, run
#   cipi yml plan ${app}     to see what would change
#   cipi yml apply ${app}    to apply it
# or turn on automatic apply with
#   cipi yml auto ${app} on
#
# Only this app is ever touched: databases must be named ${app} or ${app}_*,
# and backup profiles ${app} or ${app}-*. Everything else is rejected.
#
# Tip: to start from what the server already has, use
#   cipi yml generate ${app} > cipi.yml

version: 1

app:
  # 8.3, 8.4 or 8.5 — must already be installed (cipi php install 8.5)
  php: "8.5"

  # The declared list replaces the current aliases: an alias you remove here
  # is removed from the server. The primary domain is not managed here.
  aliases:
    - "www.${domain}"
    - "*.${domain}"      # wildcard, for multi-tenant subdomains

  # Per-app php.ini overrides. Server-wide values stay with \`cipi ini set\`.
  ini:
    upload_max_filesize: 50M
    post_max_size: 60M
    memory_limit: 512M

# Extra databases beyond the one created with the app.
# Credentials land in /home/${app}/shared/cipi-databases.env — never dropped.
databases:
  - name: ${app}_reporting
  - name: ${app}_analytics
    engine: pgsql          # mariadb (default) or pgsql

workers:
  horizon: false           # true replaces the queue workers below

  # Laravel Reverb. Cipi gives it a localhost port, a Supervisor program and an
  # nginx proxy for /app/{key} and /apps/{id}/… on this app's own domain, and
  # generates REVERB_APP_ID/KEY/SECRET (plus the VITE_ copies) in the .env the
  # first time it is enabled. An app with its own /app or /apps route cannot
  # use it behind the same domain — those paths belong to the Pusher protocol.
  reverb: false

  queues:
    - queue: default
      processes: 2
    - queue: emails
      processes: 1
      tries: 5
      timeout: 300

# Laravel scheduler (* * * * * artisan schedule:run)
schedule: true

# Commands to run after every successful deploy, from the live release directory.
# Each step uses an allowlisted runner — no shell, no pipes, no free-form scripts.
# Runs on both 'cipi deploy' and the Git webhook; does not require 'cipi yml auto'.
deploy:
  post:
    - artisan cache:clear
    - artisan scout:import --force
    - npm run build
    - composer dump-autoload -o
  # post_on_failure: abort   # default warn — log + email, leave the release live

# HTTP healthcheck. Probed every 5 minutes and right after every deploy.
# The URL must be one of this app's own domains.
health:
  url: "https://${domain}/up"
  expect: 200
  # grace: 8                      # seconds before the first probe after a deploy
  # postdeploy: false             # skip the check right after a deploy
  # rollback_on_unhealthy: true   # undo a release that fails the check
  #                               # (the code symlink only — migrations are NOT undone)
  # Use "health: {enabled: false}" to remove the healthcheck entirely.

# Backup strategy for this app. Profile names must be ${app} or ${app}-*.
backup:
  profiles:
    # Frequent, cheap: databases only, without the noisy tables.
    - name: ${app}-db
      scope: db
      databases: ["${app}", "${app}_*", "tenant_*"]
      exclude_tables: ["*.jobs", "*.failed_jobs", "*.telescope_*"]
      every: 30m           # 5m/10m/15m/20m/30m, 1h..12h, 1d..28d
      keep: 48             # keep the last 48 runs
      destinations: [local]

    # Slower, complete, off-site and encrypted.
    - name: ${app}-nightly
      scope: all           # all | files | db
      cron: "0 2 * * *"    # or use \\`every:\\`
      keep_days: 14
      destinations: [s3]
      encrypt: true
YMLEXAMPLE
}
