#!/usr/bin/env python3
"""strip_comments.py - the copy of a wrapper that ships, without its comments.

The loose start-*.ps1 / start-*.sh files keep their comments for review. What an
egg embeds (and what a server ends up with in _primal/) is ship_copy(name, bytes):
the same script with every comment removed and the blank lines that leaves
dropped. Strings, here-strings and the shebang are kept as they are.

The stripper is a small lexer, not a parser, so strip_comments_test.py proves
each result against the real interpreter: PowerShell's own tokenizer must see
the same tokens minus comments, and bash's `declare -f` must print the same
function body.

    python isles/strip_comments.py <file>    # print the ship copy to stdout
"""
import sys

# Comment lines PowerShell itself reads.
PS_KEEP_PREFIXES = ("#requires",)


def _is_blank(line):
    return line.strip() == ""


class _Out:
    """Collects the kept text, recording which lines held a removed comment."""

    def __init__(self):
        self.parts = []
        self.commented_lines = set()
        self.line = 0

    def add(self, s):
        self.parts.append(s)
        self.line += s.count("\n")

    def drop(self, s):
        self.commented_lines.add(self.line)
        nl = s.count("\n")
        for k in range(1, nl + 1):
            self.commented_lines.add(self.line + k)
        # A multi-line block comment still ends the line it started on.
        self.parts.append("\n" * nl)
        self.line += nl

    def text(self):
        return "".join(self.parts)


def _finish(text, commented_lines, code_lines):
    """Trim trailing spaces left by a removed comment and drop the lines that
    are now empty. A blank line is dropped only when it starts and ends in code
    or held a comment, so a blank line inside a string is never touched."""
    out = []
    lines = text.split("\n")
    final_newline = lines[-1] == ""
    for i, line in enumerate(lines[:-1] if final_newline else lines):
        if i in commented_lines:
            line = line.rstrip(" \t")
        if _is_blank(line) and (i in code_lines or i in commented_lines):
            continue
        out.append(line)
    return "\n".join(out) + ("\n" if final_newline else "")


# --------------------------------------------------------------------------
# PowerShell
# --------------------------------------------------------------------------

def strip_ps1(src):
    o = _Out()
    code_lines = set()
    n = len(src)

    def at_token_start(j):
        if j == 0:
            return True
        return src[j - 1] in " \t\r\n;{}()|,="

    def dq_string(j, here):
        """j points just past the opening quote; returns index past the close."""
        while j < n:
            c = src[j]
            if c == "`":
                j += 2
                continue
            if here:
                if c == "\n" and src.startswith('"@', j + 1):
                    return j + 3
            elif c == '"':
                if j + 1 < n and src[j + 1] == '"':
                    j += 2
                    continue
                return j + 1
            if c == "$" and j + 1 < n and src[j + 1] == "(":
                j = code(j + 2, ")")
                continue
            j += 1
        return j

    def sq_string(j, here):
        while j < n:
            c = src[j]
            if here:
                if c == "\n" and src.startswith("'@", j + 1):
                    return j + 3
            elif c == "'":
                if j + 1 < n and src[j + 1] == "'":
                    j += 2
                    continue
                return j + 1
            j += 1
        return j

    def code(j, closer):
        """Scan code from j. At the top level (closer None) emit output; inside
        a subexpression just skip to past the closer."""
        depth = 0
        top = closer is None
        last = j
        while j < n:
            c = src[j]
            if not top and c in "({":
                depth += 1
            elif not top and c in ")}":
                if depth == 0 and c == closer:
                    return j + 1
                depth -= 1
            if c == "\n" and top:
                o.add(src[last:j + 1])
                last = j + 1
                mark_code_line_end_for(o.line - 1)
                j += 1
                continue
            if c == "`":
                j += 2
                continue
            if c == "@" and j + 1 < n and src[j + 1] in "'\"" and _here_open(src, j + 2):
                q = src[j + 1]
                j = (dq_string if q == '"' else sq_string)(j + 2, True)
                continue
            if c == '"':
                j = dq_string(j + 1, False)
                continue
            if c == "'":
                j = sq_string(j + 1, False)
                continue
            if c == "<" and j + 1 < n and src[j + 1] == "#" and at_token_start(j):
                end = src.find("#>", j + 2)
                end = n if end < 0 else end + 2
                if top:
                    o.add(src[last:j])
                    o.drop(src[j:end])
                    last = end
                j = end
                continue
            if c == "#" and at_token_start(j):
                end = src.find("\n", j)
                end = n if end < 0 else end
                body = src[j:end]
                keep = body.lower().startswith(PS_KEEP_PREFIXES)
                if top and not keep:
                    o.add(src[last:j])
                    o.drop(body)
                    last = end
                j = end
                continue
            j += 1
        if top:
            o.add(src[last:j])
            mark_code_line_end_for(o.line)
        return j

    def mark_code_line_end_for(line_no):
        # The line's newline was reached in top-level code. It is droppable when
        # blank only if it also began in code, i.e. the previous line ended in
        # code (or it is the first line).
        if line_no == 0 or (line_no - 1) in ended_in_code:
            code_lines.add(line_no)
        ended_in_code.add(line_no)

    ended_in_code = set()
    code(0, None)
    return _finish(o.text(), o.commented_lines, code_lines)


def _here_open(src, j):
    """A here-string opener is @' or @" followed only by spaces to end of line."""
    k = src.find("\n", j)
    return k >= 0 and src[j:k].strip(" \t\r") == ""


# --------------------------------------------------------------------------
# bash
# --------------------------------------------------------------------------

def strip_sh(src):
    o = _Out()
    n = len(src)
    ended_in_code = set()
    code_lines = set()

    def at_word_start(j):
        if j == 0:
            return True
        return src[j - 1] in " \t\n;&|()<>"

    def sq(j):
        k = src.find("'", j)
        return n if k < 0 else k + 1

    def ansi_c(j):
        while j < n:
            if src[j] == "\\":
                j += 2
                continue
            if src[j] == "'":
                return j + 1
            j += 1
        return j

    def dq(j):
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == '"':
                return j + 1
            if c == "$" and j + 1 < n and src[j + 1] == "(":
                j = sub(j + 2)
                continue
            if c == "$" and j + 1 < n and src[j + 1] == "{":
                j = brace(j + 2)
                continue
            if c == "`":
                j = backtick(j + 1)
                continue
            j += 1
        return j

    def backtick(j):
        while j < n:
            if src[j] == "\\":
                j += 2
                continue
            if src[j] == "`":
                return j + 1
            j += 1
        return j

    def brace(j):
        """${...}: '#' inside is an operator, never a comment."""
        depth = 0
        while j < n:
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == "'":
                j = sq(j + 1)
                continue
            if c == '"':
                j = dq(j + 1)
                continue
            if c == "$" and j + 1 < n and src[j + 1] == "{":
                j = brace(j + 2)
                continue
            if c == "$" and j + 1 < n and src[j + 1] == "(":
                j = sub(j + 2)
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                if depth == 0:
                    return j + 1
                depth -= 1
            j += 1
        return j

    def sub(j):
        return code(j, ")")

    def code(j, closer):
        top = closer is None
        depth = 0
        last = j
        while j < n:
            c = src[j]
            if c == "\n" and top:
                o.add(src[last:j + 1])
                last = j + 1
                line_no = o.line - 1
                if line_no == 0 or (line_no - 1) in ended_in_code:
                    code_lines.add(line_no)
                ended_in_code.add(line_no)
                j += 1
                continue
            if c == "\\":
                j += 2
                continue
            if c == "'":
                j = ansi_c(j + 1) if j > 0 and src[j - 1] == "$" else sq(j + 1)
                continue
            if c == '"':
                j = dq(j + 1)
                continue
            if c == "`":
                j = backtick(j + 1)
                continue
            if c == "$" and j + 1 < n and src[j + 1] == "{":
                j = brace(j + 2)
                continue
            if c == "$" and j + 1 < n and src[j + 1] == "#":
                j += 2
                continue
            if src.startswith("<<<", j):
                j += 3
                continue
            if src.startswith("<<", j):
                raise ValueError(f"heredoc at offset {j}: strip_sh does not handle heredocs")
            if not top:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        return j + 1
                    depth -= 1
            if c == "#" and at_word_start(j):
                end = src.find("\n", j)
                end = n if end < 0 else end
                if top and not (j == 0 and src.startswith("#!")):
                    o.add(src[last:j])
                    o.drop(src[j:end])
                    last = end
                j = end
                continue
            j += 1
        if top:
            o.add(src[last:j])
        return j

    code(0, None)
    return _finish(o.text(), o.commented_lines, code_lines)


def ship_copy(name, data):
    """The bytes an egg embeds for the loose file `name`."""
    text = data.decode("utf-8")
    if name.endswith(".ps1"):
        return strip_ps1(text).encode("utf-8")
    if name.endswith(".sh"):
        return strip_sh(text).encode("utf-8")
    return data


if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, "rb") as fh:
        sys.stdout.buffer.write(ship_copy(path, fh.read()))
