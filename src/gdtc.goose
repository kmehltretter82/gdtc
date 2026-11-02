// SPDX-License-Identifier: GPL-2.0-or-later
//
// A deliberately Goose-native DTS -> DTB compiler. Nodes and properties share
// one compact, variable-size pool. The links are four-byte offsets inside that
// pool, not native pointers.
//
// The front end follows upstream dtc's flex lexer and bison grammar rule for
// rule, including the longest-match lexer start conditions and bison's parser
// stack limit. The tree follows dtc's livetree: a node that is merged into an
// existing one moves its properties and children into it in place, deletions
// mark entries rather than unlinking them, and labels live on the nodes and
// properties that carry them. The checks that can fail a compilation, and the
// fixups that change the output, run in dtc's order.

import std;
import os;

let FDT_MAGIC: u32 = 0xd00dfeed;
let FDT_BEGIN_NODE: u32 = 1;
let FDT_END_NODE: u32 = 2;
let FDT_PROP: u32 = 3;
let FDT_END: u32 = 9;
let FDT_VERSION: u32 = 17;
let FDT_LAST_COMP_VERSION: u32 = 16;
let FDT_HEADER_SIZE: u32 = 40;
let FDT_RESERVE_SIZE = 16;

// dtc's bison parser keeps at most YYMAXDEPTH (10000) states on its stack. A
// state is pushed for every grammar symbol on the stack plus the initial one,
// so a parse fails with "memory exhausted" when 9999 symbols are stacked.
let PARSER_STACK_SYMBOLS = 9999;
// srcpos.c refuses to nest source files more deeply than this.
let MAX_SOURCE_DEPTH = 200;

// Lexer start conditions (dtc-lexer.l): INITIAL, the inclusive V1 state, and
// the exclusive PROPNODENAME and BYTESTRING states.
let LEX_INITIAL = 0;
let LEX_V1 = 1;
let LEX_NAME = 2;
let LEX_BYTES = 3;

// Token kinds. A T_CHAR token carries its byte in `value`.
let T_EOF = 0;
let T_V1 = 1;
let T_PLUGIN = 2;
let T_MEMRESERVE = 3;
let T_BITS = 4;
let T_DEL_PROP = 5;
let T_DEL_NODE = 6;
let T_OMIT = 7;
let T_INCBIN = 8;
let T_NAME = 9;
let T_LITERAL = 10;
let T_CHAR_LITERAL = 11;
let T_BYTE = 12;
let T_STRING = 13;
let T_LABEL = 14;
let T_LABEL_REF = 15;
let T_PATH_REF = 16;
let T_LSHIFT = 17;
let T_RSHIFT = 18;
let T_LE = 19;
let T_GE = 20;
let T_EQ = 21;
let T_NE = 22;
let T_AND = 23;
let T_OR = 24;
let T_CHAR = 25;

// Data marker kinds (dtc's REF_PHANDLE, REF_PATH and LABEL markers).
let M_PHANDLE = 1;
let M_PATH = 2;
let M_LABEL = 3;

// Expression precedence, loosest first, as in dtc-parser.y.
let PREC_OR = 1;
let PREC_AND = 2;
let PREC_BIT_OR = 3;
let PREC_BIT_XOR = 4;
let PREC_BIT_AND = 5;
let PREC_EQUALITY = 6;
let PREC_RELATION = 7;
let PREC_SHIFT = 8;
let PREC_ADD = 9;
let PREC_MULTIPLY = 10;

enum Item {
    Node {
        next: Item..&<u32 in items>?,
        props: Item..&<u32 in items>?,
        children: Item..&<u32 in items>?,
        parent: Item..&<u32 in items>?,
        labels: i64,                     // first entry of this node's label chain
        phandle: u32,
        token: u32,                      // for diagnostics
        deleted: bool,
        omit_if_unused: bool,
        referenced: bool,
        name: u8[varint],
    },
    Property {
        next: Item..&<u32 in items>?,
        labels: i64,
        marker_first: u32,               // this value's run in `markers`
        marker_count: u32,
        token: u32,
        deleted: bool,
        name: u8[varint],
        value: u8[varint],
    },
}

struct Token {
    kind: i64,
    start: i64,                          // the token's text in `source`
    len: i64,
    value: u64,
    file: i32,
    line: i32,
}

struct SourceFile {
    name_start: i64,                     // the file's path in `paths`
    name_len: i64,
}

struct Frame {
    begin: i64,
    pos: i64,
    end: i64,
    file: i64,
    physical: i64,
    line: i64,
}

struct Reserve {
    address: u64,
    size: u64,
}

struct Marker {
    kind: i64,
    offset: u32,
    ref: const u8[:],
    token: u32,
}

// A label on a node, a property, or a position inside a property value.
struct Label {
    name: const u8[:],
    node: Item.Node?,
    prop: Item.Property?,
    marker: i64,                         // for value labels; -1 otherwise
    deleted: bool,
    next_owner: i64,                     // next label of the same owner
    next_same: i64,                      // next label with the same name
}

// A compilation owns exactly one AST pool. A command-line invocation compiles
// one source; batch mode will put this pool in an enclosing per-document scope.
var items: Item..[>..] = [];
var source: u8[>..] = [];                // every source file, back to back
var paths: u8[>..] = [];                 // source file names
var source_files: SourceFile[>..] = [];
var include_dirs: u8[>..] = [];          // -i directories, one per line
var tokens: Token[>..] = [];
var markers: Marker[>..] = [];
var labels: Label[>..] = [];
var reserves: Reserve[>..] = [];
// Two open-addressing hash tables in grow-only arrays. A table that fills up
// is rebuilt, twice as large, behind the old one, so references into these
// arrays are never invalidated and nothing ever shrinks.
var label_slots: i64[>..] = [];          // 1 + the newest label of a name
var label_slots_at = 0;
var label_slots_size = 0;
var label_slots_used = 0;
var phandle_slots: u32[>..] = [];        // phandles in use; 0 is empty
var phandle_slots_at = 0;
var phandle_slots_size = 0;
var phandle_slots_used = 0;
var unsupported_seen: u8[>..] = [];

var tp = 0;                              // the parser's next token
var stack_symbols = 0;                   // emulated bison stack depth
var plugin = false;
var boot_cpuid: u32 = 0;
var boot_cpuid_set = false;
var next_phandle: u32 = 1;
var report_unsupported = false;

fn set_next(item: Item.Node&, next: Item..?) { item.next .= next; }
fn set_next(item: Item.Property&, next: Item..?) { item.next .= next; }

fn next_of(item: Item.Node&) -> Item..? { item.next }
fn next_of(item: Item.Property&) -> Item..? { item.next }

fn as_node(item: Item.Node&) -> Item.Node? { item }
fn as_node(item: Item.Property&) -> Item.Node? { null }

fn as_property(item: Item.Node&) -> Item.Property? { null }
fn as_property(item: Item.Property&) -> Item.Property? { item }

fn node_of(item: Item..&) -> Item.Node& {
    let node = as_node(item);
    guard node else { abort("gdtc: internal error: expected a node"); }
    return node;
}

fn property_of(item: Item..&) -> Item.Property& {
    let property = as_property(item);
    guard property else { abort("gdtc: internal error: expected a property"); }
    return property;
}

fn is_dts_space(c: u8) -> bool {
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 11 || c == 12
}

fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }

fn is_hex(c: u8) -> bool {
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

fn hex_value(c: u8) -> u64 {
    if c >= '0' && c <= '9' { return (c - '0'); }
    if c >= 'a' && c <= 'f' { return (c - 'a' + 10); }
    return (c - 'A' + 10);
}

fn is_label_start(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

fn is_label_char(c: u8) -> bool { is_label_start(c) || is_digit(c) }

// PROPNODECHAR in dtc-lexer.l.
fn is_propnode_char(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) ||
    c == ',' || c == '.' || c == '_' || c == '+' || c == '*' || c == '#' ||
    c == '?' || c == '@' || c == '-'
}

// NODECHARS and PROPCHARS in checks.c.
fn is_node_name_char(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) ||
    c == ',' || c == '.' || c == '_' || c == '+' || c == '-' || c == '@'
}

fn is_property_name_char(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) ||
    c == ',' || c == '.' || c == '_' || c == '+' || c == '*' || c == '#' ||
    c == '?' || c == '-'
}

fn name_hash(name: const u8[:]) -> u64 { hash(name) }

fn label_slot(name: const u8[:]) -> i64 {
    let mask = label_slots_size - 1;
    var i = (name_hash(name) as! i64) & mask;
    loop {
        let entry = label_slots[label_slots_at + i];
        if entry == 0 || labels[entry - 1].name == name { return i; }
        i = (i + 1) & mask;
    }
    return 0;
}

fn label_head(name: const u8[:]) -> i64 {
    if label_slots_size == 0 { return -1; }
    return label_slots[label_slots_at + label_slot(name)] - 1;
}

fn set_label_head(name: const u8[:], index: i64) {
    if (label_slots_used + 1) * 2 > label_slots_size {
        let old_at = label_slots_at;
        let old_size = label_slots_size;
        label_slots_at = label_slots.len;
        label_slots_size = if old_size == 0 { 64 } else { old_size * 2 };
        for k in label_slots_size { label_slots.push(0); }
        for k in old_size {
            let entry = label_slots[old_at + k];
            if entry != 0 { label_slots[label_slots_at + label_slot(labels[entry - 1].name)] = entry; }
        }
    }
    let slot = label_slots_at + label_slot(name);
    if label_slots[slot] == 0 { label_slots_used++; }
    label_slots[slot] = index + 1;
}

fn phandle_slot(value: u32) -> i64 {
    let mask = phandle_slots_size - 1;
    var i = (hash(value) as! i64) & mask;
    loop {
        let entry = phandle_slots[phandle_slots_at + i];
        if entry == 0 || entry == value { return i; }
        i = (i + 1) & mask;
    }
    return 0;
}

fn phandle_used(value: u32) -> bool {
    if phandle_slots_size == 0 { return false; }
    return phandle_slots[phandle_slots_at + phandle_slot(value)] == value;
}

fn use_phandle(value: u32) {
    if (phandle_slots_used + 1) * 2 > phandle_slots_size {
        let old_at = phandle_slots_at;
        let old_size = phandle_slots_size;
        phandle_slots_at = phandle_slots.len;
        phandle_slots_size = if old_size == 0 { 64 } else { old_size * 2 };
        for k in phandle_slots_size { phandle_slots.push(0); }
        for k in old_size {
            let entry = phandle_slots[old_at + k];
            if entry != 0 { phandle_slots[phandle_slots_at + phandle_slot(entry)] = entry; }
        }
    }
    let slot = phandle_slots_at + phandle_slot(value);
    if phandle_slots[slot] == 0 { phandle_slots_used++; }
    phandle_slots[slot] = value;
}

fn file_name(file: i64) -> const u8[:] {
    if file < 0 || file >= source_files.len { return "<input>"; }
    let f = source_files[file];
    return paths[f.name_start..f.name_start + f.name_len];
}

fn token_location(at: i64) -> u8[>..] {
    if at < 0 || at >= tokens.len { return str(""); }
    let t = tokens[at];
    return str(file_name(t.file), ":", t.line, ": ");
}

fn fail_at(at: i64, what: const u8[:]) {
    return str("gdtc: ", token_location(at), what) from compile;
}

fn fail(what: const u8[:]) { fail_at(tp, what); }

// A construct that dtc accepts and gdtc does not implement yet. With
// --report-unsupported every such construct is recorded and parsing goes on,
// so a corpus run can tell which features a file needs.
fn unsupported(at: i64, feature: const u8[:]) {
    if !report_unsupported { fail_at(at, str("unsupported: ", feature)); }
    var seen = false;
    each_split(unsupported_seen, '\n') { if it == feature { seen = true; } };
    if !seen {
        unsupported_seen.append(feature);
        unsupported_seen.push('\n');
    }
}

// dtc's get_escape_char: octal escapes take up to three digits and wrap to a
// byte; \x goes through strtol on the next two characters, so it accepts one
// or two digits after optional white space or a sign.
fn decode_escapes(raw: const u8[:], out: u8[>..]&) -> bool {
    var i = 0;
    while i < raw.len {
        let c = raw[i];
        i++;
        if c != '\\' { out.push(c); continue; }
        if i >= raw.len { out.push(0); continue; }
        let e = raw[i];
        i++;
        if e == 'a' { out.push(7); }
        else if e == 'b' { out.push(8); }
        else if e == 't' { out.push(9); }
        else if e == 'n' { out.push(10); }
        else if e == 'v' { out.push(11); }
        else if e == 'f' { out.push(12); }
        else if e == 'r' { out.push(13); }
        else if e >= '0' && e <= '7' {
            var v: u64 = (e - '0') as u64;
            var n = 1;
            while n < 3 && i < raw.len && raw[i] >= '0' && raw[i] <= '7' {
                v = v * 8 + (raw[i] - '0') as u64;
                i++;
                n++;
            }
            out.push(v as! u8);
        }
        else if e == 'x' {
            let a: u8 = if i < raw.len { raw[i] } else { 0 };
            let b: u8 = if i + 1 < raw.len { raw[i + 1] } else { 0 };
            if is_hex(a) {
                if is_hex(b) {
                    out.push((hex_value(a) * 16 + hex_value(b)) as! u8);
                    i += 2;
                }
                else {
                    out.push(hex_value(a) as! u8);
                    i += 1;
                }
            }
            else if is_dts_space(a) && is_hex(b) {
                out.push(hex_value(b) as! u8);
                i += 2;
            }
            else if a == '+' && is_hex(b) {
                out.push(hex_value(b) as! u8);
                i += 2;
            }
            else if a == '-' && is_hex(b) {
                out.push((0 - hex_value(b)) as! u8);
                i += 2;
            }
            else { return false; }
        }
        else { out.push(e); }
    }
    return true;
}

fn add_source_name(name: const u8[:]) -> i64 {
    let index = source_files.len;
    source_files.push(SourceFile { name_start: paths.len, name_len: name.len });
    paths.append(name);
    return index;
}

// dtc's join_path and try_open: a relative name is looked up in the
// including file's directory, then in every -i directory. Returns the new
// source file, -1 if there is no such file, and -2 for a directory, which
// dtc opens and then fails to read.
fn try_read(dir: const u8[:], name: const u8[:]) -> i64 {
    var full: u8[>..] = [];
    if dir.len == 0 || (name.len > 0 && name[0] == '/') { full.append(name); }
    else {
        full.append(dir);
        if dir[dir.len - 1] != '/' { full.push('/'); }
        full.append(name);
    }
    if is_dir(full) { return -2; }
    let before = source.len;
    if !read_file(full, source) { return -1; }
    if source.len < before { return -1; }
    return add_source_name(full);
}

// fopen_any_on_path: the current directory first, then each -i directory.
fn open_on_path(dir: const u8[:], name: const u8[:]) -> i64 {
    var opened = try_read(dir, name);
    if opened != -1 { return opened; }
    each_split(include_dirs, '\n') {
        if opened == -1 && it.len > 0 { opened = try_read(it, name); }
    };
    return opened;
}

fn directory_of(file: i64) -> const u8[:] {
    let name = file_name(file);
    var slash = -1;
    for i in name.len { if name[i] == '/' { slash = i; } }
    if slash < 0 { return ""; }
    if slash == 0 { return "/"; }
    return name[..slash];
}

// Tokenize a whole source tree. dtc's lexer never looks at the parser, so the
// token stream does not depend on when bison asks for its lookahead, and the
// include stack can be handled here.
fn lex(main_path: const u8[:]) {
    var frames: Frame[>..<] = [];
    var begin = 0;
    var pos = 0;
    var end = 0;
    var file: i64 = 0;                    // the name diagnostics use
    var physical: i64 = 0;                // the file actually being read
    var line: i64 = 1;
    var state = LEX_INITIAL;

    fn lex_fail(what: const u8[:]) {
        return str("gdtc: ", file_name(file), ":", line, ": ", what) from compile;
    }

    if main_path == "-" {
        file = add_source_name("<stdin>");
        read_stdin(source);
    }
    else {
        let opened = open_on_path("", main_path);
        if opened < 0 {
            return str("gdtc: cannot read ", main_path) from compile;
        }
        file = opened;
    }
    physical = file;
    end = source.len;

    fn emit(kind: i64, start: i64, len: i64, value: u64) {
        tokens.push(Token {
            kind: kind,
            start: start,
            len: len,
            value: value,
            file: file as! i32,
            line: line as! i32,
        });
    }

    fn match_word(i: i64, word: const u8[:]) -> i64 {
        if i + word.len <= end && source[i..i + word.len] == word { return word.len; }
        return 0;
    }

    fn match_string(i: i64) -> i64 {
        if i >= end || source[i] != '"' { return 0; }
        var j = i + 1;
        while j < end {
            let c = source[j];
            if c == '"' { return j + 1 - i; }
            if c == '\\' {
                if j + 1 >= end || source[j + 1] == '\n' { return 0; }
                j += 2;
            }
            else { j++; }
        }
        return 0;
    }

    fn match_include(i: i64) -> i64 {
        let k = match_word(i, "/include/");
        if k == 0 { return 0; }
        var j = i + k;
        while j < end && is_dts_space(source[j]) { j++; }
        let s = match_string(j);
        if s == 0 { return 0; }
        return j + s - i;
    }

    fn match_blanks(i: i64) -> i64 {
        var j = i;
        while j < end && (source[j] == ' ' || source[j] == '\t') { j++; }
        return j - i;
    }

    fn match_digits(i: i64) -> i64 {
        var j = i;
        while j < end && is_digit(source[j]) { j++; }
        return j - i;
    }

    // ^"#"(line)?[ \t]+[0-9]+[ \t]+{STRING}([ \t]+[0-9]+)*
    fn match_linemarker(i: i64) -> i64 {
        if !(i == begin || source[i - 1] == '\n') { return 0; }
        if i >= end || source[i] != '#' { return 0; }
        var j = i + 1;
        j += match_word(j, "line");
        let b1 = match_blanks(j);
        if b1 == 0 { return 0; }
        j += b1;
        let d1 = match_digits(j);
        if d1 == 0 { return 0; }
        j += d1;
        let b2 = match_blanks(j);
        if b2 == 0 { return 0; }
        j += b2;
        let s = match_string(j);
        if s == 0 { return 0; }
        j += s;
        loop {
            let b = match_blanks(j);
            if b == 0 { break; }
            let d = match_digits(j + b);
            if d == 0 { break; }
            j += b + d;
        }
        return j - i;
    }

    fn match_label(i: i64) -> i64 {
        if i >= end || !is_label_start(source[i]) { return 0; }
        var j = i + 1;
        while j < end && is_label_char(source[j]) { j++; }
        if j < end && source[j] == ':' { return j + 1 - i; }
        return 0;
    }

    // ([0-9]+|0[xX][0-9a-fA-F]+)(U|L|UL|LL|ULL)?
    fn match_integer(i: i64) -> i64 {
        var best = match_digits(i);
        if i + 2 < end && source[i] == '0' && (source[i + 1] == 'x' || source[i + 1] == 'X') &&
                is_hex(source[i + 2]) {
            var j = i + 2;
            while j < end && is_hex(source[j]) { j++; }
            if j - i > best { best = j - i; }
        }
        if best == 0 { return 0; }
        let j = i + best;
        if match_word(j, "ULL") > 0 { return best + 3; }
        if match_word(j, "UL") > 0 || match_word(j, "LL") > 0 { return best + 2; }
        if j < end && (source[j] == 'U' || source[j] == 'L') { return best + 1; }
        return best;
    }

    // '([^']|\\')*' with flex's longest match: an escaped quote may close the
    // literal or continue it, and the first unescaped quote must close it.
    fn match_char_literal(i: i64) -> i64 {
        if i >= end || source[i] != '\'' { return 0; }
        var best = 0;
        var j = i + 1;
        while j < end {
            if source[j] == '\'' {
                best = j + 1 - i;
                if !(j - 1 > i && source[j - 1] == '\\') { break; }
            }
            j++;
        }
        return best;
    }

    fn match_label_ref(i: i64) -> i64 {
        if i + 1 >= end || source[i] != '&' || !is_label_start(source[i + 1]) { return 0; }
        var j = i + 2;
        while j < end && is_label_char(source[j]) { j++; }
        return j - i;
    }

    fn match_path_ref(i: i64) -> i64 {
        if i + 1 >= end || source[i] != '&' || source[i + 1] != '{' { return 0; }
        var j = i + 2;
        while j < end && (is_propnode_char(source[j]) || source[j] == '/') { j++; }
        if j < end && source[j] == '}' { return j + 1 - i; }
        return 0;
    }

    fn match_name(i: i64) -> i64 {
        var j = i;
        if j < end && source[j] == '\\' { j++; }
        let first = j;
        while j < end && is_propnode_char(source[j]) { j++; }
        if j == first { return 0; }
        return j - i;
    }

    fn match_spaces(i: i64) -> i64 {
        var j = i;
        while j < end && is_dts_space(source[j]) { j++; }
        return j - i;
    }

    fn match_comments(i: i64) -> i64 {
        var j = i;
        loop {
            if !(j + 1 < end && source[j] == '/' && source[j + 1] == '*') { break; }
            var k = j + 2;
            var closed = false;
            while k + 1 < end {
                if source[k] == '*' && source[k + 1] == '/' { closed = true; break; }
                k++;
            }
            if !closed { break; }
            j = k + 2;
        }
        return j - i;
    }

    fn match_line_comments(i: i64) -> i64 {
        var j = i;
        loop {
            if !(j + 1 < end && source[j] == '/' && source[j + 1] == '/') { break; }
            var k = j + 2;
            while k < end && source[k] != '\n' { k++; }
            if k >= end { break; }
            j = k + 1;
        }
        return j - i;
    }

    fn match_operator(i: i64) -> i64 {
        if i + 1 >= end { return 0; }
        let pair = source[i..i + 2];
        if pair == "<<" || pair == ">>" || pair == "<=" || pair == ">=" ||
                pair == "==" || pair == "!=" || pair == "&&" || pair == "||" { return 2; }
        return 0;
    }

    fn advance(n: i64) {
        for k in n { if source[pos + k] == '\n' { line++; } }
        pos += n;
    }

    fn push_include(name: const u8[:]) {
        if frames.len + 1 >= MAX_SOURCE_DEPTH { lex_fail("Includes nested too deeply"); }
        let start = source.len;
        let opened = open_on_path(directory_of(physical), name);
        if opened == -2 { lex_fail(str("cannot read \"", name, "\": is a directory")); }
        if opened < 0 { lex_fail(str("Couldn't open \"", name, "\"")); }
        frames.push(Frame {
            begin: begin,
            pos: pos,
            end: end,
            file: file,
            physical: physical,
            line: line,
        });
        file = opened;
        physical = opened;
        line = 1;
        begin = start;
        pos = start;
        end = source.len;
    }

    loop {
        if pos >= end {
            if frames.len == 0 { break; }
            let f = frames.pop();
            begin = f.begin;
            pos = f.pos;
            end = f.end;
            file = f.file;
            physical = f.physical;
            line = f.line;
            continue;
        }

        // Longest match; on a tie the earlier rule in dtc-lexer.l wins.
        var rule = 0;
        var best = 0;
        fn consider(r: i64, n: i64) {
            if n > best { best = n; rule = r; }
        }
        consider(1, match_include(pos));
        consider(2, match_linemarker(pos));
        consider(3, match_string(pos));
        consider(4, match_word(pos, "/dts-v1/"));
        consider(5, match_word(pos, "/plugin/"));
        consider(6, match_word(pos, "/memreserve/"));
        consider(7, match_word(pos, "/bits/"));
        consider(8, match_word(pos, "/delete-property/"));
        consider(9, match_word(pos, "/delete-node/"));
        consider(10, match_word(pos, "/omit-if-no-ref/"));
        consider(11, match_label(pos));
        if state == LEX_V1 { consider(12, match_integer(pos)); }
        consider(13, match_char_literal(pos));
        consider(14, match_label_ref(pos));
        consider(15, match_path_ref(pos));
        if state == LEX_BYTES {
            if pos + 1 < end && is_hex(source[pos]) && is_hex(source[pos + 1]) { consider(16, 2); }
            if source[pos] == ']' { consider(17, 1); }
        }
        if state == LEX_NAME { consider(18, match_name(pos)); }
        if state == LEX_INITIAL || state == LEX_V1 {
            consider(19, match_word(pos, "/incbin/"));
        }
        consider(20, match_spaces(pos));
        consider(21, match_comments(pos));
        consider(22, match_line_comments(pos));
        consider(23, match_operator(pos));
        if best == 0 { rule = 24; best = 1; }

        let start = pos;
        let text = source[start..start + best];
        if rule == 1 {
            let quote = find(text, "\"");
            let raw = text[quote + 1..text.len - 1];
            advance(best);
            push_include(raw);
        }
        else if rule == 2 {
            // A cpp line marker names the file and line of the next line.
            // As in srcpos_set_line, it changes only what diagnostics say:
            // includes still resolve against the file being read.
            var at = 1;
            while !is_digit(text[at]) { at++; }
            var number: i64 = 0;
            while at < text.len && is_digit(text[at]) {
                if number < 1000000000 { number = number * 10 + (text[at] - '0'); }
                at++;
            }
            let open = find(text, "\"");
            let close = rfind(text, "\"");
            var name: u8[>..] = [];
            if !decode_escapes(text[open + 1..close], name) {
                lex_fail("\\x used with no following hex digits");
            }
            for c in name { if c == 0 { lex_fail("nul in line number directive"); } }
            advance(best);
            file = add_source_name(name);
            line = number - 1;
        }
        else if rule == 3 {
            emit(T_STRING, start + 1, best - 2, 0);
            advance(best);
        }
        else if rule == 4 {
            emit(T_V1, start, best, 0);
            state = LEX_V1;
            advance(best);
        }
        else if rule == 5 { emit(T_PLUGIN, start, best, 0); advance(best); }
        else if rule == 6 {
            emit(T_MEMRESERVE, start, best, 0);
            state = LEX_V1;
            advance(best);
        }
        else if rule == 7 {
            emit(T_BITS, start, best, 0);
            state = LEX_V1;
            advance(best);
        }
        else if rule == 8 {
            emit(T_DEL_PROP, start, best, 0);
            state = LEX_NAME;
            advance(best);
        }
        else if rule == 9 {
            emit(T_DEL_NODE, start, best, 0);
            state = LEX_NAME;
            advance(best);
        }
        else if rule == 10 {
            emit(T_OMIT, start, best, 0);
            state = LEX_NAME;
            advance(best);
        }
        else if rule == 11 {
            emit(T_LABEL, start, best - 1, 0);
            advance(best);
        }
        else if rule == 12 {
            // strtoull(text, &e, 0) followed by dtc's suffix and range checks.
            var digits = best;
            while digits > 0 && (text[digits - 1] == 'U' || text[digits - 1] == 'L') { digits--; }
            var base: u64 = 10;
            var at = 0;
            if digits > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X') {
                base = 16;
                at = 2;
            }
            else if text[0] == '0' { base = 8; }
            var value: u64 = 0;
            var overflow = false;
            while at < digits {
                let d = hex_value(text[at]);
                if d >= base { lex_fail(str("Bad integer literal '", text, "'")); }
                if value > (0xffffffffffffffff - d) / base { overflow = true; }
                value = value * base + d;
                at++;
            }
            if overflow { lex_fail(str("Integer literal '", text, "' out of range")); }
            emit(T_LITERAL, start, best, value);
            advance(best);
        }
        else if rule == 13 {
            var bytes: u8[>..] = [];
            if !decode_escapes(text[1..text.len - 1], bytes) {
                lex_fail("\\x used with no following hex digits");
            }
            if bytes.len == 0 { lex_fail("Empty character literal"); }
            if bytes.len > 1 {
                lex_fail(str("Character literal has ", bytes.len, " characters instead of 1"));
            }
            emit(T_CHAR_LITERAL, start, best, bytes[0] as u64);
            advance(best);
        }
        else if rule == 14 {
            emit(T_LABEL_REF, start + 1, best - 1, 0);
            advance(best);
        }
        else if rule == 15 {
            emit(T_PATH_REF, start + 2, best - 3, 0);
            advance(best);
        }
        else if rule == 16 {
            emit(T_BYTE, start, best, hex_value(text[0]) * 16 + hex_value(text[1]));
            advance(best);
        }
        else if rule == 17 {
            emit(T_CHAR, start, best, ']');
            state = LEX_V1;
            advance(best);
        }
        else if rule == 18 {
            let skip = if text[0] == '\\' { 1 } else { 0 };
            emit(T_NAME, start + skip, best - skip, 0);
            state = LEX_V1;
            advance(best);
        }
        else if rule == 19 { emit(T_INCBIN, start, best, 0); advance(best); }
        else if rule >= 20 && rule <= 22 { advance(best); }
        else if rule == 23 {
            let kind = if text == "<<" { T_LSHIFT }
                else if text == ">>" { T_RSHIFT }
                else if text == "<=" { T_LE }
                else if text == ">=" { T_GE }
                else if text == "==" { T_EQ }
                else if text == "!=" { T_NE }
                else if text == "&&" { T_AND }
                else { T_OR };
            emit(kind, start, best, 0);
            advance(best);
        }
        else {
            let c = text[0];
            // flex returns the byte as a (signed) char: bison reads NUL and
            // every byte above 0x7f as the end of the input.
            if c == 0 || c >= 0x80 { break; }
            emit(T_CHAR, start, 1, c as u64);
            if c == '[' { state = LEX_BYTES; }
            if c == '{' || c == ';' { state = LEX_NAME; }
            advance(1);
        }
    }
    emit(T_EOF, pos, 0, 0);
}

// ---------------------------------------------------------------------------
// Parser. Each function mirrors a nonterminal of dtc-parser.y and keeps
// `stack_symbols` equal to the number of symbols bison would hold, so input
// that exhausts bison's stack fails here too instead of recursing on.

fn kind() -> i64 { tokens[tp].kind }

fn is_char(c: u8) -> bool { tokens[tp].kind == T_CHAR && tokens[tp].value == c }

fn token_text(at: i64) -> const u8[:] {
    let t = tokens[at];
    return source[t.start..t.start + t.len];
}

fn grow(n: i64) {
    stack_symbols += n;
    if stack_symbols >= PARSER_STACK_SYMBOLS { fail("memory exhausted"); }
}

fn shrink(n: i64) { stack_symbols -= n; }

fn shift() {
    grow(1);
    tp++;
}

fn syntax_error() {
    if tokens[tp].kind == T_EOF { fail("syntax error at end of input"); }
    fail(str("syntax error at '", source[tokens[tp].start..tokens[tp].start + tokens[tp].len], "'"));
}

fn expect_char(c: u8) {
    if !is_char(c) { syntax_error(); }
    shift();
}

fn expect_kind(k: i64) {
    if kind() != k { syntax_error(); }
    shift();
}

recursive fn integer_expr() -> u64 {
    let cond = binary_expr(PREC_OR);
    if !is_char('?') { return cond; }
    shift();
    let yes = integer_expr();
    expect_char(':');
    let no = integer_expr();
    shrink(4);
    return if cond != 0 { yes } else { no };
}

fn binary_operator() -> i64 {
    let k = kind();
    if k == T_OR { return PREC_OR; }
    if k == T_AND { return PREC_AND; }
    if k == T_EQ || k == T_NE { return PREC_EQUALITY; }
    if k == T_LE || k == T_GE { return PREC_RELATION; }
    if k == T_LSHIFT || k == T_RSHIFT { return PREC_SHIFT; }
    if k != T_CHAR { return 0; }
    let c = tokens[tp].value;
    if c == '|' { return PREC_BIT_OR; }
    if c == '^' { return PREC_BIT_XOR; }
    if c == '&' { return PREC_BIT_AND; }
    if c == '<' || c == '>' { return PREC_RELATION; }
    if c == '+' || c == '-' { return PREC_ADD; }
    if c == '*' || c == '/' || c == '%' { return PREC_MULTIPLY; }
    return 0;
}

fn flag(value: bool) -> u64 { if value { 1 } else { 0 } }

fn apply_operator(op: Token, at: i64, left: u64, right: u64) -> u64 {
    let k = op.kind;
    if k == T_OR { return flag(left != 0 || right != 0); }
    if k == T_AND { return flag(left != 0 && right != 0); }
    if k == T_EQ { return flag(left == right); }
    if k == T_NE { return flag(left != right); }
    if k == T_LE { return flag(left <= right); }
    if k == T_GE { return flag(left >= right); }
    if k == T_LSHIFT { return if right < 64 { left << right } else { 0 }; }
    if k == T_RSHIFT { return if right < 64 { left >> right } else { 0 }; }
    let c = op.value;
    if c == '|' { return left | right; }
    if c == '^' { return left ^ right; }
    if c == '&' { return left & right; }
    if c == '<' { return flag(left < right); }
    if c == '>' { return flag(left > right); }
    if c == '+' { return left + right; }
    if c == '-' { return left - right; }
    if c == '*' { return left * right; }
    if right == 0 { fail_at(at, "Division by zero"); }
    if c == '/' { return left / right; }
    return left % right;
}

recursive fn binary_expr(min_precedence: i64) -> u64 {
    var left = unary_expr();
    loop {
        let precedence = binary_operator();
        if precedence == 0 || precedence < min_precedence { break; }
        let op = tokens[tp];
        let at = tp;
        shift();
        let right = binary_expr(precedence + 1);
        shrink(2);
        left = apply_operator(op, at, left, right);
    }
    return left;
}

// integer_unary: prefix operators, each a stacked symbol, applied innermost
// first. They are consecutive tokens, so no list of them is needed.
fn unary_expr() -> u64 {
    let first = tp;
    while is_char('-') || is_char('~') || is_char('!') { shift(); }
    let count = tp - first;
    var v = integer_prim();
    var k = count;
    while k > 0 {
        k--;
        let c = tokens[first + k].value;
        if c == '-' { v = 0 - v; }
        else if c == '~' { v = ~v; }
        else { v = flag(v == 0); }
    }
    shrink(count);
    return v;
}

recursive fn integer_prim() -> u64 {
    if kind() == T_LITERAL || kind() == T_CHAR_LITERAL {
        let v = tokens[tp].value;
        shift();
        return v;
    }
    if !is_char('(') { syntax_error(); }
    shift();
    let v = integer_expr();
    expect_char(')');
    shrink(2);
    return v;
}

fn append_be32(out: u8[>..]&, value: u32) {
    out.push((value >> 24) as! u8);
    out.push((value >> 16) as! u8);
    out.push((value >> 8) as! u8);
    out.push(value as! u8);
}

fn append_be64(out: u8[>..]&, value: u64) {
    out.push((value >> 56) as! u8);
    out.push((value >> 48) as! u8);
    out.push((value >> 40) as! u8);
    out.push((value >> 32) as! u8);
    out.push((value >> 24) as! u8);
    out.push((value >> 16) as! u8);
    out.push((value >> 8) as! u8);
    out.push(value as! u8);
}

fn append_integer(out: u8[>..]&, value: u64, bits: u64) {
    if bits == 8 { out.push(value as! u8); }
    else if bits == 16 {
        out.push((value >> 8) as! u8);
        out.push(value as! u8);
    }
    else if bits == 32 { append_be32(out, value as! u32); }
    else { append_be64(out, value); }
}

fn add_marker(kind: i64, offset: i64, ref: const u8[:], at: i64) {
    if offset > 0xffffffff { fail_at(at, "property value is outside 32 bits"); }
    markers.push(Marker { kind: kind, offset: offset as! u32, ref: ref, token: at as! u32 });
}

fn value_labels(value: u8[>..]&) {
    while kind() == T_LABEL {
        unsupported(tp, "value-label");
        add_marker(M_LABEL, value.len, token_text(tp), tp);
        shift();
        shrink(1);
    }
}

// propdata: a comma-separated list of strings, cell arrays, byte strings,
// references and binary includes, with labels between them.
fn propdata() -> u8[>..] {
    var value: u8[>..] = [];
    grow(1);                                  // empty propdataprefix
    loop {
        value_labels(value);
        if kind() == T_STRING {
            if !decode_escapes(token_text(tp), value) {
                fail("\\x used with no following hex digits");
            }
            value.push(0);
            shift();
            shrink(1);
        }
        else if is_char('<') || kind() == T_BITS {
            var bits: u64 = 32;
            if kind() == T_BITS {
                shift();
                if kind() != T_LITERAL { syntax_error(); }
                let width_at = tp;
                bits = tokens[tp].value;
                shift();
                expect_char('<');
                shrink(2);
                if bits != 8 && bits != 16 && bits != 32 && bits != 64 {
                    fail_at(width_at, "Array elements must be 8, 16, 32 or 64-bits");
                }
            }
            else { shift(); }
            loop {
                if is_char('>') {
                    shift();
                    shrink(2);
                    break;
                }
                if kind() == T_LABEL_REF || kind() == T_PATH_REF {
                    if bits != 32 {
                        fail("References are only allowed in arrays with 32-bit elements.");
                    }
                    add_marker(M_PHANDLE, value.len, token_text(tp), tp);
                    append_be32(value, 0xffffffff);
                    shift();
                    shrink(1);
                }
                else if kind() == T_LABEL {
                    unsupported(tp, "value-label");
                    add_marker(M_LABEL, value.len, token_text(tp), tp);
                    shift();
                    shrink(1);
                }
                else {
                    let v = integer_prim();
                    shrink(1);
                    append_integer(value, v, bits);
                }
            }
        }
        else if is_char('[') {
            shift();
            grow(1);                          // empty bytestring
            loop {
                if kind() == T_BYTE {
                    value.push(tokens[tp].value as! u8);
                    shift();
                    shrink(1);
                }
                else if kind() == T_LABEL {
                    unsupported(tp, "value-label");
                    add_marker(M_LABEL, value.len, token_text(tp), tp);
                    shift();
                    shrink(1);
                }
                else if is_char(']') {
                    shift();
                    shrink(3);
                    break;
                }
                else { syntax_error(); }
            }
        }
        else if kind() == T_LABEL_REF || kind() == T_PATH_REF {
            add_marker(M_PATH, value.len, token_text(tp), tp);
            shift();
            shrink(1);
        }
        else if kind() == T_INCBIN {
            unsupported(tp, "incbin");
            shift();
            expect_char('(');
            expect_kind(T_STRING);
            var symbols = 4;
            if is_char(',') {
                shift();
                integer_prim();
                expect_char(',');
                integer_prim();
                symbols = 8;
            }
            expect_char(')');
            shrink(symbols);
        }
        else { syntax_error(); }
        value_labels(value);
        if !is_char(',') { break; }
        shift();
        shrink(1);                            // propdata ',' -> propdataprefix
    }
    return value;
}

fn add_label(name: const u8[:], node: Item.Node?, prop: Item.Property?, marker: i64) -> i64 {
    let index = labels.len;
    let same = label_head(name);
    labels.push(Label {
        name: name,
        node: node,
        prop: prop,
        marker: marker,
        deleted: false,
        next_owner: -1,
        next_same: same,
    });
    set_label_head(name, index);
    return index;
}

// dtc's add_label on a node: an existing label of that name is revived.
fn add_node_label(node: Item.Node&, name: const u8[:]) {
    var i = node.labels;
    while i >= 0 {
        if labels[i].name == name {
            labels[i].deleted = false;
            return;
        }
        i = labels[i].next_owner;
    }
    let index = add_label(name, node, null, -1);
    labels[index].next_owner = node.labels;
    node.labels = index;
}

fn add_property_label(property: Item.Property&, name: const u8[:]) {
    var i = property.labels;
    while i >= 0 {
        if labels[i].name == name {
            labels[i].deleted = false;
            return;
        }
        i = labels[i].next_owner;
    }
    let index = add_label(name, null, property, -1);
    labels[index].next_owner = property.labels;
    property.labels = index;
}

fn delete_label_chain(first: i64) {
    var i = first;
    while i >= 0 {
        labels[i].deleted = true;
        i = labels[i].next_owner;
    }
}

fn propdef() -> Item..& {
    let label_start = tp;
    var label_count = 0;
    while kind() == T_LABEL {
        shift();
        label_count++;
    }
    let at = tp;
    var result: Item..? = null;
    if kind() == T_DEL_PROP {
        shift();
        if kind() != T_NAME { syntax_error(); }
        let name = token_text(tp);
        shift();
        expect_char(';');
        shrink(2);
        result .= items.push(Item.Property {
            next: null,
            labels: -1,
            marker_first: 0,
            marker_count: 0,
            token: at as! u32,
            deleted: true,
            name: name,
            value: [],
        });
    }
    else {
        if kind() != T_NAME { syntax_error(); }
        let name = token_text(tp);
        shift();
        if is_char(';') {
            shift();
            shrink(1);
            result .= items.push(Item.Property {
                next: null,
                labels: -1,
                marker_first: 0,
                marker_count: 0,
                token: at as! u32,
                deleted: false,
                name: name,
                value: [],
            });
        }
        else {
            expect_char('=');
            let first_marker = markers.len;
            result .= items.push(Item.Property {
                next: null,
                labels: -1,
                marker_first: 0,
                marker_count: 0,
                token: at as! u32,
                deleted: false,
                name: name,
                value: propdata(),
            });
            expect_char(';');
            shrink(3);
            if markers.len - first_marker > 0xffffffff { fail_at(at, "too many references"); }
            let built = property_of(result);
            built.marker_first = first_marker as! u32;
            built.marker_count = (markers.len - first_marker) as! u32;
        }
    }
    shrink(label_count);
    guard result else { fail_at(at, "internal error: property was not built"); }
    if label_count > 0 {
        unsupported(label_start, "property-label");
        let property = property_of(result);
        for k in label_count { add_property_label(property, token_text(label_start + k)); }
    }
    return result;
}

// Does a propdef start here? Labels may precede both properties and nodes.
fn at_propdef() -> bool {
    var k = tp;
    while tokens[k].kind == T_LABEL { k++; }
    let t = tokens[k];
    if t.kind == T_DEL_PROP { return true; }
    if t.kind != T_NAME { return false; }
    let after = tokens[k + 1];
    return after.kind == T_CHAR && (after.value == '=' || after.value == ';');
}

fn new_node(name: const u8[:], at: i64, deleted: bool) -> Item..& {
    if at > 0xffffffff { fail_at(at, "input has too many tokens"); }
    return items.push(Item.Node {
        next: null,
        props: null,
        children: null,
        parent: null,
        labels: -1,
        phandle: 0,
        token: at as! u32,
        deleted: deleted,
        omit_if_unused: false,
        referenced: false,
        name: name,
    });
}

recursive fn nodedef(name: const u8[:], at: i64) -> Item..& {
    expect_char('{');
    grow(1);                                  // empty proplist
    var first_prop: Item..? = null;
    var last_prop: Item..? = null;
    while at_propdef() {
        let property .= propdef();
        shrink(1);                            // proplist propdef -> proplist
        if last_prop { set_next(last_prop, property); }
        else { first_prop .= property; }
        last_prop .= property;
    }
    var first_child: Item..? = null;
    var last_child: Item..? = null;
    var subnodes = 0;
    while !is_char('}') {
        if at_propdef() {
            if subnodes > 0 { fail("Properties must precede subnodes"); }
            syntax_error();
        }
        let child .= subnode();
        subnodes++;
        if last_child { set_next(last_child, child); }
        else { first_child .= child; }
        last_child .= child;
    }
    grow(1);                                  // empty subnodes
    shrink(subnodes);
    expect_char('}');
    expect_char(';');
    shrink(4);
    let built .= new_node(name, at, false);
    let node = node_of(built);
    node.props .= first_prop;
    node.children .= first_child;
    var child: Item..? = first_child;
    while child {
        let c = node_of(child);
        c.parent .= built;
        child .= c.next;
    }
    return built;
}

fn subnode() -> Item..& {
    let prefix_start = tp;
    var prefix = 0;
    var omit = false;
    while kind() == T_LABEL || kind() == T_OMIT {
        if kind() == T_OMIT { omit = true; }
        shift();
        prefix++;
    }
    let at = tp;
    var result: Item..? = null;
    if kind() == T_DEL_NODE {
        shift();
        if kind() != T_NAME { syntax_error(); }
        let name = token_text(tp);
        shift();
        expect_char(';');
        shrink(2);
        result .= new_node(name, at, true);
    }
    else {
        if kind() != T_NAME { syntax_error(); }
        let name = token_text(tp);
        shift();
        let built .= nodedef(name, at);
        shrink(1);
        result .= built;
    }
    shrink(prefix);
    guard result else { fail_at(at, "internal error: node was not built"); }
    let node = node_of(result);
    if omit { node.omit_if_unused = true; }
    for k in prefix {
        if tokens[prefix_start + k].kind == T_LABEL {
            add_node_label(node, token_text(prefix_start + k));
        }
    }
    return result;
}

// ---------------------------------------------------------------------------
// Tree operations, after dtc's livetree.c.

fn is_live(tree: Item.Node&, node: Item.Node&) -> bool {
    if node.deleted { return false; }
    var top: Item..? = node.parent;
    var last: Item..? = null;
    while top {
        let n = node_of(top);
        if n.deleted { return false; }
        last .= top;
        top .= n.parent;
    }
    guard last else { return node .== tree; }
    return node_of(last) .== tree;
}

fn depth_of(node: Item.Node&) -> i64 {
    var depth = 0;
    var parent = node.parent;
    while parent {
        depth++;
        parent .= node_of(parent).parent;
    }
    return depth;
}

fn ancestor(node: Item.Node&, levels: i64) -> Item.Node& {
    var current .= node;
    for k in levels {
        let parent = current.parent;
        guard parent else { break; }
        current .= node_of(parent);
    }
    return current;
}

// Pre-order position of two distinct nodes in the same tree.
fn precedes(a: Item.Node&, b: Item.Node&) -> bool {
    let da = depth_of(a);
    let db = depth_of(b);
    var x .= ancestor(a, if da > db { da - db } else { 0 });
    var y .= ancestor(b, if db > da { db - da } else { 0 });
    if x .== y { return da < db; }
    loop {
        let px = x.parent;
        let py = y.parent;
        guard px && py else { return false; }
        if px .== py { break; }
        x .= node_of(px);
        y .= node_of(py);
    }
    let parent = x.parent;
    guard parent else { return false; }
    var entry: Item..? = node_of(parent).children;
    while entry {
        let n = node_of(entry);
        if n .== x { return true; }
        if n .== y { return false; }
        entry .= n.next;
    }
    return false;
}

fn get_node_by_label(tree: Item.Node&, name: const u8[:]) -> Item.Node? {
    var best: Item.Node? = null;
    var i = label_head(name);
    while i >= 0 {
        let owner = labels[i].node;
        if !labels[i].deleted && labels[i].marker < 0 && owner && is_live(tree, owner) {
            let current = best;
            if !current { best .= owner; }
            else if owner .!= current && precedes(owner, current) { best .= owner; }
        }
        i = labels[i].next_same;
    }
    return best;
}

fn find_live_child(node: Item.Node&, name: const u8[:]) -> Item.Node? {
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted && child.name == name { return child; }
        entry .= child.next;
    }
    return null;
}

// get_node_by_path: repeated and trailing slashes are skipped.
fn get_node_by_path(start: Item.Node&, path: const u8[:]) -> Item.Node? {
    var current .= start;
    var at = 0;
    loop {
        if at >= path.len {
            if current.deleted { return null; }
            return current;
        }
        while at < path.len && path[at] == '/' { at++; }
        var stop = at;
        while stop < path.len && path[stop] != '/' { stop++; }
        let child = find_live_child(current, path[at..stop]);
        guard child else { return null; }
        if stop >= path.len { return child; }
        current .= child;
        at = stop + 1;
    }
    return null;
}

fn get_node_by_ref(tree: Item.Node&, ref: const u8[:], at: i64) -> Item.Node? {
    if ref == "/" { return tree; }
    if ref.len == 0 { fail_at(at, "empty reference"); }
    if ref[0] == '/' { return get_node_by_path(tree, ref); }
    var slash = -1;
    for k in ref.len { if slash < 0 && ref[k] == '/' { slash = k; } }
    if slash < 0 { return get_node_by_label(tree, ref); }
    unsupported(at, "label-relative-path");
    let base = get_node_by_label(tree, ref[..slash]);
    guard base else { return null; }
    return get_node_by_path(base, ref[slash + 1..]);
}

fn move_node_labels(from: Item.Node&, to: Item.Node&) {
    var i = from.labels;
    while i >= 0 {
        let following = labels[i].next_owner;
        if !labels[i].deleted { add_node_label(to, labels[i].name); }
        labels[i].deleted = true;
        i = following;
    }
    from.labels = -1;
}

fn delete_property(property: Item.Property&) {
    property.deleted = true;
    delete_label_chain(property.labels);
}

recursive fn delete_node(node: Item.Node&) {
    node.deleted = true;
    var child: Item..? = node.children;
    while child {
        let c = node_of(child);
        if !c.deleted { delete_node(c); }
        child .= c.next;
    }
    var entry: Item..? = node.props;
    while entry {
        let p = property_of(entry);
        if !p.deleted { delete_property(p); }
        entry .= p.next;
    }
    delete_label_chain(node.labels);
}

fn append_property(node: Item.Node&, entry: Item..&) {
    var last: Item..? = node.props;
    guard last else { node.props .= entry; return; }
    loop {
        let following = next_of(last);
        guard following else { break; }
        last .= following;
    }
    set_next(last, entry);
}

fn append_child(node: Item.Node&, entry: Item..&, self_ref: Item..&) {
    node_of(entry).parent .= self_ref;
    var last: Item..? = node.children;
    guard last else { node.children .= entry; return; }
    loop {
        let following = next_of(last);
        guard following else { break; }
        last .= following;
    }
    set_next(last, entry);
}

fn item_of(node: Item.Node&) -> Item..& {
    // Every node is an element of `items`; find the generic reference to it
    // through its parent or the root.
    let parent = node.parent;
    if parent {
        var entry: Item..? = node_of(parent).children;
        while entry {
            if node_of(entry) .== node { return entry; }
            entry .= next_of(entry);
        }
    }
    abort("gdtc: internal error: node is not linked");
}

recursive fn merge_nodes(old: Item.Node&, old_item: Item..&, incoming: Item.Node&) {
    old.deleted = false;
    move_node_labels(incoming, old);

    var entry: Item..? = incoming.props;
    incoming.props .= null;
    while entry {
        let property = property_of(entry);
        let following = property.next;
        property.next .= null;
        if property.deleted {
            var cur: Item..? = old.props;
            while cur {
                let existing = property_of(cur);
                if existing.name == property.name {
                    delete_property(existing);
                    break;
                }
                cur .= existing.next;
            }
            delete_label_chain(property.labels);
        }
        else {
            var previous: Item..? = null;
            var cur: Item..? = old.props;
            var replaced = false;
            while cur {
                let existing = property_of(cur);
                if existing.name == property.name {
                    // dtc copies the new value into the old property, which
                    // keeps its position and its labels.
                    var i = existing.labels;
                    while i >= 0 {
                        let next_label = labels[i].next_owner;
                        if !labels[i].deleted { add_property_label(property, labels[i].name); }
                        labels[i].deleted = true;
                        i = next_label;
                    }
                    property.next .= existing.next;
                    if previous { set_next(previous, entry); }
                    else { old.props .= entry; }
                    replaced = true;
                    break;
                }
                previous .= cur;
                cur .= existing.next;
            }
            if !replaced { append_property(old, entry); }
        }
        entry .= following;
    }

    var child: Item..? = incoming.children;
    incoming.children .= null;
    while child {
        let c = node_of(child);
        let following = c.next;
        c.next .= null;
        c.parent .= null;
        if c.deleted {
            var cur: Item..? = old.children;
            while cur {
                let existing = node_of(cur);
                if existing.name == c.name {
                    delete_node(existing);
                    break;
                }
                cur .= existing.next;
            }
            delete_label_chain(c.labels);
        }
        else {
            var matched = false;
            var cur: Item..? = old.children;
            while cur {
                let existing = node_of(cur);
                if existing.name == c.name {
                    merge_nodes(existing, cur, c);
                    matched = true;
                    break;
                }
                cur .= existing.next;
            }
            if !matched { append_child(old, child, old_item); }
        }
        child .= following;
    }
}

// ---------------------------------------------------------------------------
// The top level: headers, memory reservations and tree fragments.

fn parse() -> Item..& {
    var headers = 0;
    var flags = 0;
    while kind() == T_V1 {
        shift();
        expect_char(';');
        var this_flags = 1;
        if kind() == T_PLUGIN {
            shift();
            expect_char(';');
            shrink(2);
            this_flags = 3;
        }
        shrink(1);
        if headers > 0 && this_flags != flags {
            fail("Header flags don't match earlier ones");
        }
        if headers == 0 { flags = this_flags; }
        headers++;
    }
    if headers == 0 { syntax_error(); }
    shrink(headers - 1);
    if flags == 3 {
        plugin = true;
        unsupported(0, "plugin");
    }

    var reservations = 0;
    loop {
        let label_start = tp;
        var label_count = 0;
        while kind() == T_LABEL {
            shift();
            label_count++;
        }
        if kind() != T_MEMRESERVE {
            if label_count > 0 { syntax_error(); }
            break;
        }
        shift();
        let address = integer_prim();
        let size = integer_prim();
        expect_char(';');
        shrink(3 + label_count);
        if label_count > 0 { unsupported(label_start, "memreserve-label"); }
        reserves.push(Reserve { address: address, size: size });
        reservations++;
    }
    grow(1);                                  // empty memreserves
    shrink(reservations);

    var tree_item: Item..? = null;
    if is_char('/') {
        let at = tp;
        shift();
        let built .= nodedef("", at);
        shrink(1);
        tree_item .= built;
    }
    else if kind() == T_LABEL_REF || kind() == T_PATH_REF {
        if !plugin { fail(str("Label or path ", token_text(tp), " not found")); }
        syntax_error();
    }
    else { syntax_error(); }
    guard tree_item else { syntax_error(); }
    let tree = node_of(tree_item);

    loop {
        if kind() == T_EOF { break; }
        if is_char('/') {
            let at = tp;
            shift();
            let fragment .= nodedef("", at);
            shrink(2);
            merge_nodes(tree, tree_item, node_of(fragment));
        }
        else if kind() == T_LABEL || kind() == T_LABEL_REF || kind() == T_PATH_REF {
            var label_at = -1;
            if kind() == T_LABEL {
                label_at = tp;
                shift();
                if kind() != T_LABEL_REF && kind() != T_PATH_REF { syntax_error(); }
            }
            let ref_at = tp;
            let ref = token_text(tp);
            shift();
            let fragment .= nodedef("", ref_at);
            shrink(if label_at >= 0 { 3 } else { 2 });
            let target = get_node_by_ref(tree, ref, ref_at);
            guard target else { fail_at(ref_at, str("Label or path ", ref, " not found")); }
            // devicetree DT_LABEL dt_ref nodedef: label the target, then merge.
            if label_at >= 0 { add_node_label(target, token_text(label_at)); }
            if target .== tree { merge_nodes(target, tree_item, node_of(fragment)); }
            else { merge_nodes(target, item_of(target), node_of(fragment)); }
        }
        else if kind() == T_DEL_NODE || kind() == T_OMIT {
            let omit = kind() == T_OMIT;
            shift();
            if kind() != T_LABEL_REF && kind() != T_PATH_REF { syntax_error(); }
            let ref_at = tp;
            let ref = token_text(tp);
            shift();
            expect_char(';');
            shrink(3);
            let target = get_node_by_ref(tree, ref, ref_at);
            guard target else { fail_at(ref_at, str("Label or path ", ref, " not found")); }
            if omit { target.omit_if_unused = true; }
            else { delete_node(target); }
        }
        else { syntax_error(); }
    }
    return tree_item;
}


// guess_boot_cpuid: the raw first child of /cpus, even a deleted one.
fn guess_boot_cpuid(tree: Item.Node&) {
    let cpus = find_live_child(tree, "cpus");
    guard cpus else { return; }
    let first = cpus.children;
    guard first else { return; }
    let reg = get_property(node_of(first), "reg");
    guard reg else { return; }
    if reg.value.len != 4 { return; }
    boot_cpuid = read_be32(reg.value, 0);
}

fn read_be32(value: const u8[:], at: i64) -> u32 {
    return ((value[at] as u32) << 24) | ((value[at + 1] as u32) << 16) |
           ((value[at + 2] as u32) << 8) | (value[at + 3] as u32);
}

// get_property: the first live property of that name.
fn get_property(node: Item.Node&, name: const u8[:]) -> Item.Property? {
    var entry: Item..? = node.props;
    while entry {
        let p = property_of(entry);
        if !p.deleted && p.name == name { return p; }
        entry .= p.next;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Checks and fixups, in the order of checks.c's check_table. Every check here
// is an ERROR check: a failure stops the compilation without output.

fn node_message(node: Item.Node&, what: const u8[:]) {
    var path: u8[>..] = [];
    append_path(path, node);
    let at: i64 = node.token;
    fail_at(at, str(path, ": ", what));
}

recursive fn append_path(out: u8[>..]&, node: Item.Node&) {
    let parent = node.parent;
    guard parent else { out.push('/'); return; }
    let p = node_of(parent);
    append_path(out, p);
    if p.parent { out.push('/'); }
    out.append(node.name);
}

recursive fn check_names(node: Item.Node&) {
    // duplicate_node_names: a live child against every later sibling.
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted {
            var other: Item..? = child.next;
            while other {
                let o = node_of(other);
                if o.name == child.name { node_message(o, "Duplicate node name"); }
                other .= o.next;
            }
        }
        entry .= child.next;
    }
    // duplicate_property_names
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if !p.deleted {
            var other: Item..? = p.next;
            while other {
                let o = property_of(other);
                if !o.deleted && o.name == p.name {
                    node_message(node, str("Duplicate property name ", p.name));
                }
                other .= o.next;
            }
        }
        pe .= p.next;
    }
    entry .= node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_names(child); }
        entry .= child.next;
    }
}

recursive fn check_name_chars(node: Item.Node&) {
    for c in node.name {
        if !is_node_name_char(c) {
            var what: u8[>..] = str("Bad character '");
            what.push(c);
            what.append("' in node name");
            node_message(node, what);
        }
    }
    var at = -1;
    for k in node.name.len { if at < 0 && node.name[k] == '@' { at = k; } }
    if at >= 0 {
        for k in at + 1..node.name.len {
            if node.name[k] == '@' { node_message(node, "multiple '@' characters in node name"); }
        }
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_name_chars(child); }
        entry .= child.next;
    }
}

recursive fn check_property_chars(node: Item.Node&) {
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if !p.deleted {
            for c in p.name {
                if !is_property_name_char(c) {
                    var what: u8[>..] = str("Bad character '");
                    what.push(c);
                    what.append("' in property name ");
                    what.append(p.name);
                    node_message(node, what);
                }
            }
        }
        pe .= p.next;
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_property_chars(child); }
        entry .= child.next;
    }
}

fn is_one_string(value: const u8[:]) -> bool {
    if value.len == 0 { return false; }
    for k in value.len - 1 { if value[k] == 0 { return false; } }
    return value[value.len - 1] == 0;
}

recursive fn check_name_is_string(node: Item.Node&) {
    let name = get_property(node, "name");
    if name && !is_one_string(name.value) {
        node_message(node, "name: property is not a string");
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_name_is_string(child); }
        entry .= child.next;
    }
}

// name_properties: a "name" property equal to the base name is dropped.
recursive fn check_name_properties(node: Item.Node&) {
    var previous: Item..? = null;
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if p.name == "name" {
            var base = node.name.len;
            for k in node.name.len { if base == node.name.len && node.name[k] == '@' { base = k; } }
            if p.value.len != base + 1 || p.value[..base] != node.name[..base] {
                node_message(node, "\"name\" property is incorrect");
            }
            let following = p.next;
            if previous { set_next(previous, following); }
            else { node.props .= following; }
            delete_label_chain(p.labels);
            break;
        }
        previous .= pe;
        pe .= p.next;
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_name_properties(child); }
        entry .= child.next;
    }
}

fn label_owner_same(a: Label, b: Label) -> bool {
    let an = a.node;
    let bn = b.node;
    let ap = a.prop;
    let bp = b.prop;
    if (an == null) != (bn == null) || (ap == null) != (bp == null) { return false; }
    if an && bn && an .!= bn { return false; }
    if ap && bp && ap .!= bp { return false; }
    return a.marker == b.marker;
}

fn property_owner(tree: Item.Node&, property: Item.Property&) -> Item.Node? {
    return find_property_owner(tree, property);
}

recursive fn find_property_owner(start: Item.Node?, property: Item.Property&) -> Item.Node? {
    guard start else { return null; }
    var pe: Item..? = start.props;
    while pe {
        let p = property_of(pe);
        if p .== property {
            if p.deleted { return null; }
            return start;
        }
        pe .= p.next;
    }
    var entry: Item..? = start.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted {
            let found = find_property_owner(child, property);
            if found { return found; }
        }
        entry .= child.next;
    }
    return null;
}

fn label_is_live(tree: Item.Node&, l: Label) -> bool {
    if l.deleted { return false; }
    let n = l.node;
    if n { return is_live(tree, n); }
    let p = l.prop;
    if p { return property_owner(tree, p) != null; }
    return false;
}

// duplicate_label: every live occurrence of a label must have one owner.
fn check_duplicate_labels(tree: Item.Node&) {
    for l in labels {
        if !label_is_live(tree, l) { continue; }
        var i = label_head(l.name);
        while i >= 0 {
            let other = labels[i];
            if label_is_live(tree, other) && !label_owner_same(l, other) {
                fail(str("Duplicate label '", l.name, "'"));
            }
            i = other.next_same;
        }
    }
}

fn phandle_property_value(tree: Item.Node&, node: Item.Node&, name: const u8[:]) -> u32 {
    let p = get_property(node, name);
    guard p else { return 0; }
    if p.value.len != 4 {
        node_message(node, str("bad length (", p.value.len, ") ", name, " property"));
    }
    let first: i64 = p.marker_first;
    let count: i64 = p.marker_count;
    for m in first..first + count {
        if markers[m].kind == M_PHANDLE {
            let target = get_node_by_ref(tree, markers[m].ref, markers[m].token);
            if !target || target .!= node {
                node_message(node, str(name, " is a reference to another node"));
            }
            return 0;
        }
    }
    let value = read_be32(p.value, 0);
    if value == 0 || value == 0xffffffff {
        node_message(node, str("bad value (", value, ") in ", name, " property"));
    }
    return value;
}

recursive fn check_explicit_phandles(tree: Item.Node&, node: Item.Node&) {
    let primary = phandle_property_value(tree, node, "phandle");
    let legacy = phandle_property_value(tree, node, "linux,phandle");
    if primary != 0 || legacy != 0 {
        if primary != 0 && legacy != 0 && primary != legacy {
            node_message(node, "mismatching 'phandle' and 'linux,phandle' properties");
        }
        let value = if primary != 0 { primary } else { legacy };
        if phandle_used(value) {
            node_message(node, str("duplicated phandle ", value));
        }
        node.phandle = value;
        use_phandle(value);
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { check_explicit_phandles(tree, child); }
        entry .= child.next;
    }
}

fn new_phandle_property(value: u32) -> Item..& {
    var cell: u8[>..] = [];
    append_be32(cell, value);
    return items.push(Item.Property {
        next: null,
        labels: -1,
        marker_first: 0,
        marker_count: 0,
        token: 0,
        deleted: false,
        name: "phandle",
        value: cell,
    });
}

// get_node_phandle: allocate the lowest unused value at or above the last.
fn node_phandle(node: Item.Node&) -> u32 {
    if node.phandle != 0 && node.phandle != 0xffffffff { return node.phandle; }
    while phandle_used(next_phandle) { next_phandle++; }
    let value = next_phandle;
    node.phandle = value;
    use_phandle(value);
    if !get_property(node, "phandle") {
        append_property(node, new_phandle_property(value));
    }
    return value;
}

recursive fn fixup_phandle_references(tree: Item.Node&, node: Item.Node&) {
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if !p.deleted {
            let first: i64 = p.marker_first;
            let count: i64 = p.marker_count;
            for m in first..first + count {
                if markers[m].kind != M_PHANDLE { continue; }
                let target = get_node_by_ref(tree, markers[m].ref, markers[m].token);
                guard target else {
                    fail_at(markers[m].token as i64,
                        str("Reference to non-existent node or label \"", markers[m].ref, "\""));
                }
                let value = node_phandle(target);
                let at = markers[m].offset as i64;
                p.value[at] = (value >> 24) as! u8;
                p.value[at + 1] = (value >> 16) as! u8;
                p.value[at + 2] = (value >> 8) as! u8;
                p.value[at + 3] = value as! u8;
                target.referenced = true;
            }
        }
        pe .= p.next;
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { fixup_phandle_references(tree, child); }
        entry .= child.next;
    }
}

// fixup_path_references: a reference outside a cell list becomes the
// target's full path. A property value cannot grow in place, so the
// expanded value goes into a new property that takes the old one's place.
fn has_path_markers(p: Item.Property&) -> bool {
    let first: i64 = p.marker_first;
    let count: i64 = p.marker_count;
    for m in first..first + count { if markers[m].kind == M_PATH { return true; } }
    return false;
}

fn expanded_value(tree: Item.Node&, p: Item.Property&) -> u8[>..] {
    var value: u8[>..] = [];
    var cursor = 0;
    let first: i64 = p.marker_first;
    let count: i64 = p.marker_count;
    for m in first..first + count {
        if markers[m].kind != M_PATH { continue; }
        let target = get_node_by_ref(tree, markers[m].ref, markers[m].token);
        guard target else {
            fail_at(markers[m].token,
                str("Reference to non-existent node or label \"", markers[m].ref, "\""));
        }
        let offset: i64 = markers[m].offset;
        value.append(p.value[cursor..offset]);
        append_path(value, target);
        value.push(0);
        cursor = offset;
        target.referenced = true;
    }
    value.append(p.value[cursor..]);
    return value;
}

fn expanded_property(tree: Item.Node&, p: Item.Property&) -> Item..& {
    let built .= items.push(Item.Property {
        next: p.next,
        labels: p.labels,
        marker_first: p.marker_first,
        marker_count: p.marker_count,
        token: p.token,
        deleted: false,
        name: p.name[..],
        value: expanded_value(tree, p),
    });
    let replacement = property_of(built);
    var i = p.labels;
    while i >= 0 {
        labels[i].prop .= replacement;
        i = labels[i].next_owner;
    }
    return built;
}

recursive fn fixup_path_references(tree: Item.Node&, node: Item.Node&) {
    var previous: Item..? = null;
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if !p.deleted && has_path_markers(p) {
            let replacement .= expanded_property(tree, p);
            if previous { set_next(previous, replacement); }
            else { node.props .= replacement; }
            pe .= replacement;
        }
        previous .= pe;
        pe .= next_of(pe);
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { fixup_path_references(tree, child); }
        entry .= child.next;
    }
}

// fixup_omit_unused_nodes: an /omit-if-no-ref/ node that no live property
// referred to is deleted. The flag belongs to the node it was written on;
// merging a flagged node into an existing one does not pass it on.
recursive fn omit_unused_nodes(node: Item.Node&) {
    if node.omit_if_unused && !node.referenced {
        delete_node(node);
        return;
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { omit_unused_nodes(child); }
        entry .= child.next;
    }
}

fn check_tree(tree: Item.Node&) {
    check_names(tree);
    check_name_chars(tree);
    check_property_chars(tree);
    check_name_is_string(tree);
    check_name_properties(tree);
    check_duplicate_labels(tree);
    check_explicit_phandles(tree, tree);
    fixup_phandle_references(tree, tree);
    fixup_path_references(tree, tree);
    omit_unused_nodes(tree);
}

// ---------------------------------------------------------------------------
// Flattening.

fn align4(out: u8[>..]&) {
    while out.len % 4 != 0 { out.push(0); }
}

fn fdt_u32(value: i64, what: const u8[:]) -> u32 {
    if value < 0 || value > 0xffffffff {
        return str("gdtc: ", what, " is outside the 32-bit DTB format") from compile;
    }
    return value as! u32;
}

// Match dtc's stringtable_insert exactly, including reuse of a suffix inside
// an earlier property name (it tests strcmp at every byte offset).
fn string_offset(strings: u8[>..]&, name: const u8[:]) -> u32 {
    fdt_u32(strings.len, "string table size");
    for i in strings.len {
        if i + name.len >= strings.len { break; }
        if strings[i + name.len] != 0 { continue; }
        var same = true;
        for j in name.len {
            if strings[i + j] != name[j] { same = false; break; }
        }
        if same { return fdt_u32(i, "string offset"); }
    }
    let offset = fdt_u32(strings.len, "string offset");
    strings.append(name);
    strings.push(0);
    return offset;
}

recursive fn emit_node(node: Item.Node&, structure: u8[>..]&, strings: u8[>..]&) {
    append_be32(structure, FDT_BEGIN_NODE);
    structure.append(node.name);
    structure.push(0);
    align4(structure);
    var pe: Item..? = node.props;
    while pe {
        let p = property_of(pe);
        if !p.deleted {
            let offset = string_offset(strings, p.name);
            append_be32(structure, FDT_PROP);
            append_be32(structure, fdt_u32(p.value.len, "property size"));
            append_be32(structure, offset);
            structure.append(p.value);
            align4(structure);
        }
        pe .= p.next;
    }
    var entry: Item..? = node.children;
    while entry {
        let child = node_of(entry);
        if !child.deleted { emit_node(child, structure, strings); }
        entry .= child.next;
    }
    append_be32(structure, FDT_END_NODE);
}

fn emit(tree: Item.Node&, out: u8[>..]&) {
    var structure: u8[>..] = [];
    var strings: u8[>..] = [];
    // flatten_tree skips a deleted node, and that includes a deleted root.
    if !tree.deleted { emit_node(tree, structure, strings); }
    append_be32(structure, FDT_END);

    let reserve_size = (reserves.len + 1) * FDT_RESERVE_SIZE;
    let struct_offset = FDT_HEADER_SIZE + reserve_size;
    let strings_offset = struct_offset + structure.len;
    let total_size = strings_offset + strings.len;

    append_be32(out, FDT_MAGIC);
    append_be32(out, fdt_u32(total_size, "total size"));
    append_be32(out, fdt_u32(struct_offset, "structure offset"));
    append_be32(out, fdt_u32(strings_offset, "string table offset"));
    append_be32(out, FDT_HEADER_SIZE);
    append_be32(out, FDT_VERSION);
    append_be32(out, FDT_LAST_COMP_VERSION);
    append_be32(out, boot_cpuid);
    append_be32(out, fdt_u32(strings.len, "string table size"));
    append_be32(out, fdt_u32(structure.len, "structure size"));
    for reserve in reserves {
        append_be64(out, reserve.address);
        append_be64(out, reserve.size);
    }
    for i in FDT_RESERVE_SIZE { out.push(0); }   // terminating reserve entry
    out.append(structure);
    out.append(strings);
}

var blob: u8[>..] = [];

fn compile(path: const u8[:]) -> u8[>..] {
    lex(path);
    let tree = node_of(parse());
    if report_unsupported { return str(""); }
    if !boot_cpuid_set { guess_boot_cpuid(tree); }
    check_tree(tree);
    emit(tree, blob);
    return str("");
}

fn usage() {
    write_stderr("usage: gdtc [-I dts] [-O dtb] [-o output] [-i dir] [-b cpu] [-q] input\n");
    exit(2);
}

fn main() {
    let argv = args();
    var input_at = -1;
    var output_at = -1;
    var i = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "-o" {
            i++;
            if i >= argv.len { usage(); }
            output_at = i;
        }
        else if a == "-I" {
            i++;
            if i >= argv.len || argv[i] != "dts" { usage(); }
        }
        else if a == "-O" {
            i++;
            if i >= argv.len || argv[i] != "dtb" { usage(); }
        }
        else if a == "-i" {
            i++;
            if i >= argv.len { usage(); }
            include_dirs.append(argv[i]);
            include_dirs.push('\n');
        }
        else if a == "-b" {
            i++;
            if i >= argv.len { usage(); }
            let v, ok = parse_int(argv[i]);
            if !ok || v < 0 || v > 0xffffffff { usage(); }
            boot_cpuid = v as! u32;
            boot_cpuid_set = true;
        }
        else if a == "-q" { }
        else if a == "--report-unsupported" { report_unsupported = true; }
        else if a.len > 0 && a[0] == '-' && a != "-" { usage(); }
        else {
            if input_at >= 0 { usage(); }
            input_at = i;
        }
        i++;
    }
    if input_at < 0 { usage(); }

    let error = compile(argv[input_at]);
    if report_unsupported {
        // One line on stdout naming every unsupported feature, then any
        // other error on stderr. Exit 3 if a feature is missing.
        var list: u8[>..] = [];
        each_split(unsupported_seen, '\n') {
            if it.len > 0 {
                if list.len > 0 { list.push(' '); }
                list.append(it);
            }
        };
        write_stdout(str("unsupported:", if list.len > 0 { " " } else { "" }, list, "\n"));
        if error.len > 0 { write_stderr(str(error, "\n")); }
        if unsupported_seen.len > 0 { exit(3); }
        exit(if error.len > 0 { 1 } else { 0 });
    }
    if error.len > 0 {
        write_stderr(str(error, "\n"));
        exit(1);
    }
    if output_at >= 0 {
        if !write_file(argv[output_at], blob) {
            write_stderr(str("gdtc: cannot write ", argv[output_at], "\n"));
            exit(1);
        }
    }
    else { write_stdout(blob); }
}
