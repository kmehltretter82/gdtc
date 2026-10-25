// SPDX-License-Identifier: GPL-2.0-or-later
//
// A deliberately Goose-native DTS -> DTB compiler. Nodes and properties share
// one compact, variable-size pool. The links are four-byte offsets inside that
// pool, not native pointers. Children are built before their parent, as in the
// Goose JSON sample, and linked in source order.

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

// Pratt-parser operator tags. Their numeric values are deliberately unrelated
// to precedence; expr_precedence is the one source of that ordering.
let OP_NONE = 0;
let OP_TERNARY = 1;
let OP_LOGICAL_OR = 2;
let OP_LOGICAL_AND = 3;
let OP_BIT_OR = 4;
let OP_BIT_XOR = 5;
let OP_BIT_AND = 6;
let OP_EQUAL = 7;
let OP_NOT_EQUAL = 8;
let OP_LESS = 9;
let OP_LESS_EQUAL = 10;
let OP_GREATER = 11;
let OP_GREATER_EQUAL = 12;
let OP_SHIFT_LEFT = 13;
let OP_SHIFT_RIGHT = 14;
let OP_ADD = 15;
let OP_SUBTRACT = 16;
let OP_MULTIPLY = 17;
let OP_DIVIDE = 18;
let OP_REMAINDER = 19;

enum Item {
    Node {
        next: Item..&<u32 in items>?,
        first: Item..&<u32 in items>?,
        name: u8[varint],
        phandle: u32,
        deleted: bool,
    },
    Property {
        next: Item..&<u32 in items>?,
        name: u8[varint],
        value: u8[varint],
        deleted: bool,
    },
}

struct Reserve {
    address: u64,
    size: u64,
}

struct Label {
    name: u8[varint],
    defined: bool,
    group: u32,
    node: Item.Node?,
}

struct Fixup {
    target: u8[varint],
    property: Item.Property?,
    offset: u32,
    owner: u32,
    is_path: bool,
}

// A compilation owns exactly one AST pool. A command-line invocation compiles
// one source; batch mode will put this pool in an enclosing per-document scope.
var items: Item..[>..] = [];
var reserves: Reserve[>..] = [];
var labels: Label[>..] = [];
var fixups: Fixup[>..] = [];
var used_phandles: u32[>..] = [];
var next_phandle: u32 = 1;
var next_label_group: u32 = 1;
var next_fixup_owner: u32 = 1;

fn set_next(item: Item.Node&, next: Item..&) { item.next .= next; }
fn set_next(item: Item.Property&, next: Item..&) { item.next .= next; }

fn clear_next(item: Item.Node&) { item.next .= null; }
fn clear_next(item: Item.Property&) { item.next .= null; }

fn next_of(item: Item.Node&) -> Item..? { item.next }
fn next_of(item: Item.Property&) -> Item..? { item.next }

fn as_node(item: Item.Node&) -> Item.Node? { item }
fn as_node(item: Item.Property&) -> Item.Node? { null }

fn as_property(item: Item.Node&) -> Item.Property? { null }
fn as_property(item: Item.Property&) -> Item.Property? { item }

fn find_label(name: u8[:]) -> Label? {
    for label in labels {
        if label.name == name { return label; }
    }
    return null;
}

fn is_dts_space(c: u8) -> bool {
    c == ' ' || c == '\t' || c == '\r' || c == '\n'
}

fn is_hex(c: u8) -> bool {
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
    (c >= 'A' && c <= 'F')
}

fn hex_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    return c - 'A' + 10;
}

// Parse one source file. Parser helpers are nested so a syntax error at any
// depth can return directly from this function with one checked `return from`.
fn parse(text: u8[:]) -> Item..?, u8[>..] {
    var pos = 0;

    fn message(what: const u8[:]) -> u8[>..] {
        str("gdtc: ", what, " at byte ", pos)
    }

    fn fail(what: const u8[:]) {
        return null, message(what) from parse;
    }

    fn skip_space() {
        loop {
            while pos < text.len && is_dts_space(text[pos]) { pos++; }
            if pos + 1 < text.len && text[pos] == '/' && text[pos + 1] == '/' {
                pos += 2;
                while pos < text.len && text[pos] != '\n' { pos++; }
                continue;
            }
            if pos + 1 < text.len && text[pos] == '/' && text[pos + 1] == '*' {
                pos += 2;
                var closed = false;
                while pos + 1 < text.len {
                    if text[pos] == '*' && text[pos + 1] == '/' {
                        pos += 2;
                        closed = true;
                        break;
                    }
                    pos++;
                }
                if !closed { fail("unterminated block comment"); }
                continue;
            }
            break;
        }
    }

    fn peek() -> u8 {
        skip_space();
        if pos < text.len { text[pos] } else { 0 }
    }

    fn expect(c: u8) {
        skip_space();
        if pos >= text.len || text[pos] != c {
            var why: u8[>..] = [];
            format(why, "expected '");
            why.push(c);
            why.push('\'');
            fail(why);
        }
        pos++;
    }

    fn expect_text(want: const u8[:]) {
        skip_space();
        if pos + want.len > text.len || text[pos..pos + want.len] != want {
            fail(str("expected ", want));
        }
        pos += want.len;
    }

    fn name() -> u8[:] {
        skip_space();
        let start = pos;
        while pos < text.len {
            let c = text[pos];
            if is_dts_space(c) || c == '{' || c == '}' || c == ';' || c == '=' || c == ':' {
                break;
            }
            pos++;
        }
        if pos == start { fail("expected node or property name"); }
        return text[start..pos];
    }

    fn escaped_string() -> u8[>..] {
        expect('"');
        var out: u8[>..] = [];
        loop {
            if pos >= text.len { fail("unterminated string"); }
            let c = text[pos];
            pos++;
            if c == '"' { break; }
            if c != '\\' { out.push(c); continue; }
            if pos >= text.len { fail("unterminated escape"); }
            let e = text[pos];
            pos++;
            if e == 'n' { out.push('\n'); }
            else if e == 'r' { out.push('\r'); }
            else if e == 't' { out.push('\t'); }
            else if e == 'a' { out.push(7); }
            else if e == 'b' { out.push(8); }
            else if e == 'f' { out.push(12); }
            else if e == 'v' { out.push(11); }
            else if e == 'x' {
                if pos + 2 > text.len || !is_hex(text[pos]) || !is_hex(text[pos + 1]) {
                    fail("bad hexadecimal escape");
                }
                out.push((hex_value(text[pos]) * 16 + hex_value(text[pos + 1])) as! u8);
                pos += 2;
            }
            else if e >= '0' && e <= '7' {
                var v = (e - '0') as i64;
                var n = 1;
                while n < 3 && pos < text.len && text[pos] >= '0' && text[pos] <= '7' {
                    v = v * 8 + (text[pos] - '0');
                    pos++;
                    n++;
                }
                if v > 255 { fail("octal escape is outside one byte"); }
                out.push(v as! u8);
            }
            else { out.push(e); }
        }
        return out;
    }

    fn character_number() -> u64 {
        pos++;                              // opening quote
        if pos >= text.len { fail("unterminated character literal"); }
        var value: u64 = 0;
        if text[pos] != '\\' {
            value = text[pos];
            pos++;
        }
        else {
            pos++;
            if pos >= text.len { fail("unterminated character escape"); }
            let e = text[pos];
            pos++;
            if e == 'n' { value = '\n'; }
            else if e == 'r' { value = '\r'; }
            else if e == 't' { value = '\t'; }
            else if e == 'a' { value = 7; }
            else if e == 'b' { value = 8; }
            else if e == 'f' { value = 12; }
            else if e == 'v' { value = 11; }
            else if e == 'x' {
                if pos + 2 > text.len || !is_hex(text[pos]) || !is_hex(text[pos + 1]) {
                    fail("bad hexadecimal character escape");
                }
                value = (hex_value(text[pos]) * 16 + hex_value(text[pos + 1])) as! u64;
                pos += 2;
            }
            else if e >= '0' && e <= '7' {
                value = e - '0';
                var n = 1;
                while n < 3 && pos < text.len && text[pos] >= '0' && text[pos] <= '7' {
                    value = value * 8 + (text[pos] - '0');
                    pos++;
                    n++;
                }
                if value > 255 { fail("octal character escape is outside one byte"); }
            }
            else { value = e; }
        }
        if pos >= text.len || text[pos] != '\'' {
            fail("character literal must contain exactly one byte");
        }
        pos++;
        return value;
    }

    // DTS reserve entries are unsigned 64-bit values. std.parse_int is signed,
    // so parse these directly and reject overflow before unsigned arithmetic
    // could wrap in an optimized build.
    fn unsigned_number() -> u64 {
        skip_space();
        if pos < text.len && text[pos] == '\'' { return character_number(); }
        var base: u64 = 10;
        if pos + 2 <= text.len && text[pos] == '0' &&
                (text[pos + 1] == 'x' || text[pos + 1] == 'X') {
            base = 16;
            pos += 2;
        }
        else if pos + 1 < text.len && text[pos] == '0' &&
                text[pos + 1] >= '0' && text[pos + 1] <= '9' {
            base = 8;
        }
        let start = pos;
        var value: u64 = 0;
        while pos < text.len {
            let c = text[pos];
            var digit = -1;
            if c >= '0' && c <= '9' { digit = c - '0'; }
            else if c >= 'a' && c <= 'f' { digit = c - 'a' + 10; }
            else if c >= 'A' && c <= 'F' { digit = c - 'A' + 10; }
            else { break; }
            if digit as! u64 >= base { fail("digit is outside the integer base"); }
            let d = digit as! u64;
            if value > (0xffffffffffffffff - d) / base {
                fail("unsigned integer is outside 64 bits");
            }
            value = value * base + d;
            pos++;
        }
        if pos == start { fail("expected unsigned integer"); }
        return value;
    }

    fn number() -> u32 {
        let value = unsigned_number();
        if value > 0xffffffff { fail("expected an unsigned 32-bit integer"); }
        return value as! u32;
    }

    fn expression_operator(stop_gt: bool) -> i64 {
        skip_space();
        if pos + 2 <= text.len {
            let pair = text[pos..pos + 2];
            if pair == "||" { return OP_LOGICAL_OR; }
            if pair == "&&" { return OP_LOGICAL_AND; }
            if pair == "==" { return OP_EQUAL; }
            if pair == "!=" { return OP_NOT_EQUAL; }
            if pair == "<=" { return OP_LESS_EQUAL; }
            if pair == ">=" { return OP_GREATER_EQUAL; }
            if pair == "<<" { return OP_SHIFT_LEFT; }
            if pair == ">>" { return OP_SHIFT_RIGHT; }
        }
        if pos >= text.len { return OP_NONE; }
        let c = text[pos];
        if c == '?' { return OP_TERNARY; }
        if c == '|' { return OP_BIT_OR; }
        if c == '^' { return OP_BIT_XOR; }
        if c == '&' { return OP_BIT_AND; }
        if c == '<' { return OP_LESS; }
        if c == '>' {
            if stop_gt { return OP_NONE; }
            return OP_GREATER;
        }
        if c == '+' { return OP_ADD; }
        if c == '-' { return OP_SUBTRACT; }
        if c == '*' { return OP_MULTIPLY; }
        if c == '/' { return OP_DIVIDE; }
        if c == '%' { return OP_REMAINDER; }
        return OP_NONE;
    }

    fn expression_precedence(op: i64) -> i64 {
        if op == OP_TERNARY { return 1; }
        if op == OP_LOGICAL_OR { return 2; }
        if op == OP_LOGICAL_AND { return 3; }
        if op == OP_BIT_OR { return 4; }
        if op == OP_BIT_XOR { return 5; }
        if op == OP_BIT_AND { return 6; }
        if op == OP_EQUAL || op == OP_NOT_EQUAL { return 7; }
        if op == OP_LESS || op == OP_LESS_EQUAL ||
                op == OP_GREATER || op == OP_GREATER_EQUAL { return 8; }
        if op == OP_SHIFT_LEFT || op == OP_SHIFT_RIGHT { return 9; }
        if op == OP_ADD || op == OP_SUBTRACT { return 10; }
        return 11;                          // multiply, divide, remainder
    }

    fn expression_operator_size(op: i64) -> i64 {
        if op == OP_LOGICAL_OR || op == OP_LOGICAL_AND ||
                op == OP_EQUAL || op == OP_NOT_EQUAL ||
                op == OP_LESS_EQUAL || op == OP_GREATER_EQUAL ||
                op == OP_SHIFT_LEFT || op == OP_SHIFT_RIGHT { return 2; }
        return 1;
    }

    fn expression_bool(value: bool) -> u64 {
        if value { 1 } else { 0 }
    }

    fn apply_expression_operator(op: i64, left: u64, right: u64) -> u64 {
        if op == OP_LOGICAL_OR { return expression_bool(left != 0 || right != 0); }
        if op == OP_LOGICAL_AND { return expression_bool(left != 0 && right != 0); }
        if op == OP_BIT_OR { return left | right; }
        if op == OP_BIT_XOR { return left ^ right; }
        if op == OP_BIT_AND { return left & right; }
        if op == OP_EQUAL { return expression_bool(left == right); }
        if op == OP_NOT_EQUAL { return expression_bool(left != right); }
        if op == OP_LESS { return expression_bool(left < right); }
        if op == OP_LESS_EQUAL { return expression_bool(left <= right); }
        if op == OP_GREATER { return expression_bool(left > right); }
        if op == OP_GREATER_EQUAL { return expression_bool(left >= right); }
        if op == OP_SHIFT_LEFT {
            if right >= 64 { return 0; }
            return left << right;
        }
        if op == OP_SHIFT_RIGHT {
            if right >= 64 { return 0; }
            return left >> right;
        }
        if op == OP_ADD { return left + right; }
        if op == OP_SUBTRACT { return left - right; }
        if op == OP_MULTIPLY { return left * right; }
        if op == OP_DIVIDE {
            if right == 0 { fail("division by zero in integer expression"); }
            return left / right;
        }
        if op == OP_REMAINDER {
            if right == 0 { fail("division by zero in integer expression"); }
            return left % right;
        }
        fail("internal expression operator error");
        return 0;
    }

    recursive fn integer_expression(min_precedence: i64, stop_gt: bool) -> u64 {
        skip_space();
        if pos >= text.len { fail("expected integer expression"); }

        var left: u64 = 0;
        let c = text[pos];
        if c == '-' {
            pos++;
            left = 0 - integer_expression(12, stop_gt);
        }
        else if c == '~' {
            pos++;
            left = ~integer_expression(12, stop_gt);
        }
        else if c == '!' {
            pos++;
            left = expression_bool(integer_expression(12, stop_gt) == 0);
        }
        else if c == '(' {
            pos++;
            left = integer_expression(1, false);
            expect(')');
        }
        else { left = unsigned_number(); }

        loop {
            let op = expression_operator(stop_gt);
            if op == OP_NONE { break; }
            let precedence = expression_precedence(op);
            if precedence < min_precedence { break; }
            pos += expression_operator_size(op);
            if op == OP_TERNARY {
                let yes = integer_expression(1, stop_gt);
                expect(':');
                let no = integer_expression(precedence, stop_gt);
                left = if left != 0 { yes } else { no };
            }
            else {
                let right = integer_expression(precedence + 1, stop_gt);
                left = apply_expression_operator(op, left, right);
            }
        }
        return left;
    }

    fn be32(out: u8[>..]&, value: u32) {
        out.push((value >> 24) as! u8);
        out.push((value >> 16) as! u8);
        out.push((value >> 8) as! u8);
        out.push(value as! u8);
    }

    fn label_reference() -> u8[:] {
        skip_space();
        let start = pos;
        while pos < text.len {
            let c = text[pos];
            if is_dts_space(c) || c == '>' || c == ',' || c == '{' || c == ';' { break; }
            pos++;
        }
        if pos == start { fail("expected label after '&'"); }
        if text[start] == '{' { fail("expected a label rather than a path"); }
        return text[start..pos];
    }

    fn path_reference() -> u8[:] {
        skip_space();
        expect('{');
        let start = pos;
        while pos < text.len && text[pos] != '}' { pos++; }
        if pos >= text.len { fail("unterminated path reference"); }
        if pos == start || text[start] != '/' {
            fail("path reference must be absolute");
        }
        let path = text[start..pos];
        pos++;
        return path;
    }

    fn note_label_reference(label_name: u8[:]) {
        if find_label(label_name) { return; }
        labels.push(Label {
            name: label_name,
            defined: false,
            group: 0,
            node: null,
        });
    }

    fn define_label(label_name: u8[:], group: u32) {
        let found = find_label(label_name);
        if found {
            if found.defined { fail(str("duplicate label ", label_name)); }
            found.defined = true;
            found.group = group;
            return;
        }
        labels.push(Label {
            name: label_name,
            defined: true,
            group: group,
            node: null,
        });
    }

    fn bind_label_group(group: u32, node: Item.Node&) {
        for label in labels {
            if label.defined && label.group == group { label.node .= node; }
        }
    }

    fn cells(out: u8[>..]&, width: u32, fixup_owner: u32) {
        expect('<');
        loop {
            skip_space();
            if peek() == '>' { pos++; break; }
            if peek() == '&' {
                if width != 32 { fail("phandle references require 32-bit cells"); }
                pos++;
                let is_path = peek() == '{';
                let target = if is_path { path_reference() } else { label_reference() };
                if !is_path { note_label_reference(target); }
                if out.len > 0xffffffff { fail("property value is outside 32 bits"); }
                fixups.push(Fixup {
                    target: target,
                    property: null,
                    offset: out.len as! u32,
                    owner: fixup_owner,
                    is_path: is_path,
                });
                be32(out, 0);
            }
            else {
                let value = integer_expression(1, true);
                if width == 8 {
                    out.push(value as! u8);
                }
                else if width == 16 {
                    out.push((value >> 8) as! u8);
                    out.push(value as! u8);
                }
                else if width == 32 {
                    be32(out, value as! u32);
                }
                else { append_be64(out, value); }
            }
        }
    }

    fn bytes(out: u8[>..]&) {
        expect('[');
        loop {
            skip_space();
            if peek() == ']' { pos++; break; }
            if pos + 2 > text.len || !is_hex(text[pos]) || !is_hex(text[pos + 1]) {
                fail("expected a two-digit byte");
            }
            out.push((hex_value(text[pos]) * 16 + hex_value(text[pos + 1])) as! u8);
            pos += 2;
        }
    }

    fn property_data(fixup_owner: u32) -> u8[>..] {
        var value: u8[>..] = [];
        loop {
            let c = peek();
            if c == ';' { pos++; break; }
            if c == ',' { pos++; continue; }
            if c == '"' {
                value.append(escaped_string());
                value.push(0);
            }
            else if c == '<' { cells(value, 32, fixup_owner); }
            else if c == '[' { bytes(value); }
            else if c == '/' {
                expect_text("/bits/");
                let width = number();
                if width != 8 && width != 16 && width != 32 && width != 64 {
                    fail("/bits/ width must be 8, 16, 32, or 64");
                }
                cells(value, width, fixup_owner);
            }
            else { fail("unsupported property value"); }
        }
        return value;
    }

    fn property(prop_name: u8[:]) -> Item..& {
        if next_fixup_owner == 0xffffffff { fail("too many properties"); }
        let fixup_owner = next_fixup_owner;
        next_fixup_owner++;
        skip_space();
        var result: Item..? = null;
        if peek() == ';' {
            pos++;
            result .= items.push(Item.Property {
                next: null,
                name: prop_name,
                value: [],
                deleted: false,
            });
        }
        else {
            expect('=');
            result .= items.push(Item.Property {
                next: null,
                name: prop_name,
                value: property_data(fixup_owner),
                deleted: false,
            });
        }
        guard result else { fail("internal error: property was not constructed"); }
        let built = as_property(result);
        guard built else { fail("internal error: constructed property is not a property"); }
        for fixup in fixups {
            if fixup.owner == fixup_owner { fixup.property .= built; }
        }
        return result;
    }

    recursive fn node(node_name: u8[:]) -> Item..& {
        expect('{');
        var first: Item..? = null;
        var last: Item..? = null;
        var saw_child = false;
        loop {
            skip_space();
            if peek() == '}' { pos++; break; }
            let token = name();
            let entry: Item..& = if token == "/delete-property/" {
                if saw_child { fail("properties must precede child nodes"); }
                let deleted_name = name();
                expect(';');
                items.push(Item.Property {
                    next: null,
                    name: deleted_name,
                    value: [],
                    deleted: true,
                })
            }
            else if token == "/delete-node/" {
                saw_child = true;
                let deleted_name = name();
                expect(';');
                items.push(Item.Node {
                    next: null,
                    first: null,
                    name: deleted_name,
                    phandle: 0,
                    deleted: true,
                })
            }
            else if peek() == ':' {
                if next_label_group == 0xffffffff { fail("too many labeled nodes"); }
                let group = next_label_group;
                next_label_group++;
                pos++;
                define_label(token, group);
                var entry_name = name();
                while peek() == ':' {
                    pos++;
                    define_label(entry_name, group);
                    entry_name = name();
                }
                if peek() != '{' { fail("only node labels are implemented"); }
                saw_child = true;
                let labeled .= node(entry_name);
                let built = as_node(labeled);
                guard built else { fail("internal error: labeled entry is not a node"); }
                bind_label_group(group, built);
                labeled
            }
            else if peek() == '{' {
                saw_child = true;
                node(token)
            }
            else {
                if saw_child { fail("properties must precede child nodes"); }
                property(token)
            };
            if last { set_next(last, entry); }
            else { first .= entry; }
            last .= entry;
        }
        expect(';');
        let result .= items.push(Item.Node {
            next: null,
            first: first,
            name: node_name,
            phandle: 0,
            deleted: false,
        });
        return result;
    }

    fn append_entry(target: Item.Node&, entry: Item..&) {
        let first = target.first;
        if first {
            var last: Item..? = first;
            while last {
                let following = next_of(last);
                if following { last .= following; }
                else { set_next(last, entry); return; }
            }
        }
        else { target.first .= entry; }
    }

    fn find_live_child(target: Item.Node&, child_name: u8[:]) -> Item.Node? {
        var result: Item.Node? = null;
        var entry: Item..? = target.first;
        while entry {
            match entry {
                Node &child => {
                    if child.name == child_name && !child.deleted { result .= child; }
                },
                Property &p => {},
            }
            entry .= next_of(entry);
        }
        return result;
    }

    fn find_deleted_child(target: Item.Node&, child_name: u8[:]) -> Item.Node? {
        var result: Item.Node? = null;
        var entry: Item..? = target.first;
        while entry {
            match entry {
                Node &child => {
                    if child.name == child_name && child.deleted { result .= child; }
                },
                Property &p => {},
            }
            entry .= next_of(entry);
        }
        return result;
    }

    fn find_node_by_path(root: Item.Node&, path: u8[:]) -> Item.Node? {
        if path == "/" { return root; }
        if path.len < 2 || path[0] != '/' { return null; }
        var current: Item.Node? = root;
        var start = 1;
        while start < path.len {
            var end = start;
            while end < path.len && path[end] != '/' { end++; }
            if end == start { return null; }
            guard current else { return null; }
            let child = find_live_child(current, path[start..end]);
            guard child else { return null; }
            current .= child;
            start = end + 1;
        }
        return current;
    }

    fn retarget_node_labels(from: Item.Node&, to: Item.Node&) {
        for label in labels {
            let bound = label.node;
            if label.defined && bound && bound .== from { label.node .= to; }
        }
    }

    recursive fn undefine_node_labels(node: Item.Node&) {
        for label in labels {
            let bound = label.node;
            if label.defined && bound && bound .== node {
                label.defined = false;
                label.node .= null;
            }
        }
        var entry: Item..? = node.first;
        while entry {
            match entry {
                Node &child => undefine_node_labels(child),
                Property &property => {},
            }
            entry .= next_of(entry);
        }
    }

    recursive fn merge_nodes(target: Item.Node&, incoming: Item.Node&) {
        retarget_node_labels(incoming, target);
        target.deleted = false;
        var entry: Item..? = incoming.first;
        while entry {
            let following = next_of(entry);
            clear_next(entry);
            match entry {
                Property &property => {
                    if property.deleted {
                        let existing = latest_property(target, property.name);
                        if existing { append_entry(target, entry); }
                    }
                    else { append_entry(target, entry); }
                },
                Node &child => {
                    let existing = find_live_child(target, child.name);
                    if child.deleted {
                        if existing {
                            undefine_node_labels(existing);
                            existing.deleted = true;
                        }
                    }
                    else if existing { merge_nodes(existing, child); }
                    else {
                        // dtc keeps a deleted node's original position if a
                        // later fragment recreates it, but replaces all of its
                        // old contents with the new node.
                        let deleted = find_deleted_child(target, child.name);
                        if deleted {
                            retarget_node_labels(child, deleted);
                            deleted.first .= child.first;
                            deleted.phandle = child.phandle;
                            deleted.deleted = false;
                        }
                        else { append_entry(target, entry); }
                    }
                },
            }
            entry .= following;
        }
    }

    fn find_node_by_label(label_name: u8[:]) -> Item.Node? {
        let label = find_label(label_name);
        if !label || !label.defined { return null; }
        let node = label.node;
        if node && !node.deleted { return node; }
        return null;
    }

    fn phandle_used(value: u32) -> bool {
        for used in used_phandles {
            if used == value { return true; }
        }
        return false;
    }

    fn explicit_phandle_value(property: Item.Property&) -> u32 {
        if property.value.len != 4 {
            fail(str(property.name, " property must contain exactly one cell"));
        }
        let value = ((property.value[0] as u32) << 24) |
                ((property.value[1] as u32) << 16) |
                ((property.value[2] as u32) << 8) |
                property.value[3];
        if value == 0 || value == 0xffffffff {
            fail(str("invalid value in ", property.name, " property"));
        }
        return value;
    }

    fn node_explicit_phandle(node: Item.Node&) -> u32 {
        var primary: u32 = 0;
        var linux_value: u32 = 0;
        let primary_property = latest_live_property(node, "phandle");
        if primary_property { primary = explicit_phandle_value(primary_property); }
        let linux_property = latest_live_property(node, "linux,phandle");
        if linux_property { linux_value = explicit_phandle_value(linux_property); }
        if primary != 0 && linux_value != 0 && primary != linux_value {
            fail("mismatching phandle and linux,phandle properties");
        }
        if primary != 0 { return primary; }
        return linux_value;
    }

    recursive fn collect_explicit_phandles(node: Item.Node&) {
        if node.deleted { return; }
        let value = node_explicit_phandle(node);
        if value != 0 {
            if phandle_used(value) { fail(str("duplicate phandle ", value)); }
            node.phandle = value;
            used_phandles.push(value);
        }
        var entry: Item..? = node.first;
        while entry {
            match entry {
                Node &child => collect_explicit_phandles(child),
                Property &property => {},
            }
            entry .= next_of(entry);
        }
    }

    fn allocate_phandle(node: Item.Node&) -> u32 {
        if node.phandle != 0 { return node.phandle; }
        while next_phandle != 0xffffffff && phandle_used(next_phandle) {
            next_phandle++;
        }
        if next_phandle == 0xffffffff { fail("no phandles remain"); }
        let value = next_phandle;
        next_phandle++;
        node.phandle = value;
        used_phandles.push(value);
        return value;
    }

    recursive fn property_is_live(node: Item.Node&, property: Item.Property&) -> bool {
        if node.deleted { return false; }
        let latest = latest_live_property(node, property.name);
        if latest && latest .== property { return true; }
        var entry: Item..? = node.first;
        while entry {
            match entry {
                Node &child => {
                    if property_is_live(child, property) { return true; }
                },
                Property &candidate => {},
            }
            entry .= next_of(entry);
        }
        return false;
    }

    skip_space();
    expect_text("/dts-v1/");
    expect(';');
    skip_space();
    while pos + 12 <= text.len && text[pos..pos + 12] == "/memreserve/" {
        pos += 12;
        let address = unsigned_number();
        let size = unsigned_number();
        expect(';');
        reserves.push(Reserve { address: address, size: size });
        skip_space();
    }
    expect('/');
    let root .= node("");
    loop {
        skip_space();
        if pos == text.len { break; }
        let root_node = as_node(root);
        guard root_node else { fail("internal error: root is not a node"); }
        if pos + 13 <= text.len && text[pos..pos + 13] == "/delete-node/" {
            pos += 13;
            expect('&');
            let is_path = peek() == '{';
            let target_name = if is_path { path_reference() } else { label_reference() };
            let target = if is_path {
                find_node_by_path(root_node, target_name)
            }
            else { find_node_by_label(target_name) };
            guard target else { fail(str("delete target not found: ", target_name)); }
            undefine_node_labels(target);
            target.deleted = true;
            expect(';');
        }
        else if text[pos] == '/' {
            pos++;
            let fragment .= node("");
            let fragment_node = as_node(fragment);
            guard fragment_node else { fail("internal error: root fragment is not a node"); }
            merge_nodes(root_node, fragment_node);
        }
        else if text[pos] == '&' {
            pos++;
            let is_path = peek() == '{';
            let target_name = if is_path { path_reference() } else { label_reference() };
            let target = if is_path {
                find_node_by_path(root_node, target_name)
            }
            else { find_node_by_label(target_name) };
            guard target else { fail(str("merge target not found: ", target_name)); }
            let fragment .= node("");
            let fragment_node = as_node(fragment);
            guard fragment_node else { fail("internal error: merge fragment is not a node"); }
            merge_nodes(target, fragment_node);
        }
        else { fail("expected a root or label merge fragment"); }
    }
    let final_root = as_node(root);
    guard final_root else { fail("internal error: root is not a node"); }
    collect_explicit_phandles(final_root);
    for fixup in fixups {
        let property = fixup.property;
        guard property else { fail("internal error: unbound property reference"); }
        if !property_is_live(final_root, property) { continue; }
        let target = if fixup.is_path {
            find_node_by_path(final_root, fixup.target)
        }
        else { find_node_by_label(fixup.target) };
        guard target else {
            let kind = if fixup.is_path { "path" } else { "label" };
            fail(str("undefined ", kind, " ", fixup.target));
        }
        let value = allocate_phandle(target);
        let at: i64 = fixup.offset;
        if at + 4 > property.value.len {
            fail("internal error: property reference offset is outside its value");
        }
        property.value[at] = (value >> 24) as! u8;
        property.value[at + 1] = (value >> 16) as! u8;
        property.value[at + 2] = (value >> 8) as! u8;
        property.value[at + 3] = value as! u8;
    }
    return root, str("");
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

fn append_zeroes(out: u8[>..]&, count: i64) {
    for i in count { out.push(0); }
}

fn align4(out: u8[>..]&) {
    while out.len % 4 != 0 { out.push(0); }
}

fn fdt_u32(value: i64, what: const u8[:]) -> u32 {
    if value < 0 || value > 0xffffffff {
        abort(str("gdtc: ", what, " is outside the 32-bit DTB format"));
    }
    return value as! u32;
}

// Match dtc's stringtable_insert exactly, including reuse of a suffix inside
// an earlier property name (it tests strcmp at every byte offset).
fn string_offset(strings: u8[>..]&, name: const u8[:]) -> u32 {
    fdt_u32(strings.len, "string table size");
    for i in strings.len {
        if i + name.len >= strings.len { continue; }
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

fn emit_property(prop: Item.Property&, structure: u8[>..]&, strings: u8[>..]&) {
    let offset = string_offset(strings, prop.name);
    append_be32(structure, FDT_PROP);
    append_be32(structure, fdt_u32(prop.value.len, "property size"));
    append_be32(structure, offset);
    structure.append(prop.value);
    align4(structure);
}

fn emit_phandle(value: u32, structure: u8[>..]&, strings: u8[>..]&) {
    append_be32(structure, FDT_PROP);
    append_be32(structure, 4);
    append_be32(structure, string_offset(strings, "phandle"));
    append_be32(structure, value);
}

fn phandle_of(node: Item.Node&) -> u32 {
    if latest_live_property(node, "phandle") ||
            latest_live_property(node, "linux,phandle") { return 0; }
    return node.phandle;
}

fn is_first_property(node: Item.Node&, property: Item.Property&) -> bool {
    var entry: Item..? = node.first;
    while entry {
        match entry {
            Property &candidate => {
                if candidate.name == property.name {
                    return candidate .== property;
                }
            },
            Node &child => {},
        }
        entry .= next_of(entry);
    }
    return false;
}

fn latest_property(node: Item.Node&, property_name: u8[:]) -> Item.Property? {
    var result: Item.Property? = null;
    var entry: Item..? = node.first;
    while entry {
        match entry {
            Property &candidate => {
                if candidate.name == property_name { result .= candidate; }
            },
            Node &child => {},
        }
        entry .= next_of(entry);
    }
    return result;
}

fn latest_live_property(node: Item.Node&, property_name: u8[:]) -> Item.Property? {
    let property = latest_property(node, property_name);
    if property && !property.deleted { return property; }
    return null;
}

recursive fn emit_node(node: Item.Node&, structure: u8[>..]&, strings: u8[>..]&) {
    append_be32(structure, FDT_BEGIN_NODE);
    structure.append(node.name);
    structure.push(0);
    align4(structure);

    // Merged properties may physically follow children in the pool. Emit the
    // first occurrence's position with the last occurrence's value, exactly as
    // dtc's merge_nodes replaces a colliding property in place.
    var entry: Item..? = node.first;
    while entry {
        match entry {
            Property &property => {
                if is_first_property(node, property) {
                    let latest = latest_property(node, property.name);
                    if latest && !latest.deleted {
                        emit_property(latest, structure, strings);
                    }
                }
            },
            Node &child => {},
        }
        entry .= next_of(entry);
    }

    let phandle = phandle_of(node);
    if phandle != 0 { emit_phandle(phandle, structure, strings); }

    entry .= node.first;
    while entry {
        match entry {
            Node &child => {
                if !child.deleted { emit_node(child, structure, strings); }
            },
            Property &property => {},
        }
        entry .= next_of(entry);
    }
    append_be32(structure, FDT_END_NODE);
}

fn emit(root: Item..&) -> u8[>..] {
    var structure: u8[>..] = [];
    var strings: u8[>..] = [];
    match root {
        Node &n => emit_node(n, structure, strings),
        Property &p => abort(str("internal error: property root ", p.name)),
    }
    append_be32(structure, FDT_END);

    let reserve_size = (reserves.len + 1) * FDT_RESERVE_SIZE;
    let struct_offset = FDT_HEADER_SIZE + reserve_size;
    let strings_offset = struct_offset + structure.len;
    let total_size = strings_offset + strings.len;

    var out: u8[>..] = [];
    append_be32(out, FDT_MAGIC);
    append_be32(out, fdt_u32(total_size, "total size"));
    append_be32(out, fdt_u32(struct_offset, "structure offset"));
    append_be32(out, fdt_u32(strings_offset, "string table offset"));
    append_be32(out, FDT_HEADER_SIZE);
    append_be32(out, FDT_VERSION);
    append_be32(out, FDT_LAST_COMP_VERSION);
    append_be32(out, 0);                         // boot_cpuid_phys
    append_be32(out, fdt_u32(strings.len, "string table size"));
    append_be32(out, fdt_u32(structure.len, "structure size"));
    for reserve in reserves {
        append_be64(out, reserve.address);
        append_be64(out, reserve.size);
    }
    append_zeroes(out, FDT_RESERVE_SIZE);        // terminating reserve entry
    out.append(structure);
    out.append(strings);
    return out;
}

fn usage() {
    write_stderr("usage: gdtc [-I dts] [-O dtb] [-o output] input\n");
    exit(2);
}

fn main() {
    let argv = args();
    var input_at = -1;
    var output_at = -1;
    var i = 1;
    while i < argv.len {
        if argv[i] == "-o" {
            i++;
            if i >= argv.len { usage(); }
            output_at = i;
        }
        else if argv[i] == "-I" {
            i++;
            if i >= argv.len || argv[i] != "dts" { usage(); }
        }
        else if argv[i] == "-O" {
            i++;
            if i >= argv.len || argv[i] != "dtb" { usage(); }
        }
        else if argv[i].len > 0 && argv[i][0] == '-' && argv[i] != "-" {
            usage();
        }
        else {
            if input_at >= 0 { usage(); }
            input_at = i;
        }
        i++;
    }
    if input_at < 0 { usage(); }

    var source: u8[>..] = [];
    if argv[input_at] == "-" { read_stdin(source); }
    else if !read_file(argv[input_at], source) {
        write_stderr(str("gdtc: cannot read ", argv[input_at], "\n"));
        exit(1);
    }

    let root, error = parse(source);
    guard root else {
        write_stderr(str(error, "\n"));
        exit(1);
    }
    let blob = emit(root);
    if output_at >= 0 {
        if !write_file(argv[output_at], blob) {
            write_stderr(str("gdtc: cannot write ", argv[output_at], "\n"));
            exit(1);
        }
    }
    else { write_stdout(blob); }
}
