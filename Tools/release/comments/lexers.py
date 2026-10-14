"""Comment-aware lexers for Swift, Python, shell and YAML, and the edit engine that removes comments.

Every lexer returns a `Lexed`: the comments it found (character offsets into the source), the spans of string-like
literals, and a token stream that ignores comments and layout. Two sources with equal token streams differ only in
comments and whitespace that carries no meaning for that language.
"""
from __future__ import annotations

import ast
import io
import os
import re
import tokenize
from dataclasses import dataclass, field
from typing import List, Optional, Sequence, Tuple


class LexError(Exception):
    pass


@dataclass
class Comment:
    start: int
    end: int
    style: str
    text: str
    line: int = 0
    end_line: int = 0

    @property
    def is_doc(self) -> bool:
        return self.style.startswith("doc")


@dataclass
class Lexed:
    language: str
    comments: List[Comment] = field(default_factory=list)
    strings: List[Tuple[int, int]] = field(default_factory=list)
    nested: List[Comment] = field(default_factory=list)
    tokens: List[tuple] = field(default_factory=list)
    token_offsets: List[int] = field(default_factory=list)


_SHELL_SHEBANG = re.compile(r"^#!\s*\S*/(?:env\s+)?(?:ba)?sh\b")
_PYTHON_SHEBANG = re.compile(r"^#!\s*\S*/(?:env\s+)?python[0-9.]*\b")


def detect_language(path: str, head: str = "") -> Optional[str]:
    name = os.path.basename(path)
    ext = os.path.splitext(name)[1].lower()
    if ext == ".swift":
        return "swift"
    if ext == ".py":
        return "python"
    if ext in (".sh", ".bash"):
        return "shell"
    if ext in (".yml", ".yaml"):
        return "yaml"
    if ext == "" and head.startswith("#!"):
        first = head.split("\n", 1)[0]
        if _SHELL_SHEBANG.match(first):
            return "shell"
        if _PYTHON_SHEBANG.match(first):
            return "python"
    return None


def line_starts(text: str) -> List[int]:
    starts = [0]
    for m in re.finditer("\n", text):
        starts.append(m.end())
    return starts


def offset_to_line(starts: Sequence[int], offset: int) -> int:
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1


def _number_lines(text: str, lexed: Lexed) -> Lexed:
    starts = line_starts(text)
    for c in lexed.comments + lexed.nested:
        c.line = offset_to_line(starts, c.start)
        c.end_line = offset_to_line(starts, max(c.start, c.end - 1))
    return lexed


def lex(language: str, text: str) -> Lexed:
    if language == "swift":
        lexed = SwiftLexer(text).run()
    elif language == "python":
        lexed = lex_python(text)
    elif language == "shell":
        lexed = ShellLexer(text).run()
    elif language == "yaml":
        lexed = lex_yaml(text)
    else:
        raise LexError("unsupported language " + language)
    return _number_lines(text, lexed)


_SWIFT_OPERATOR_CHARS = set("/=-+!*%<>&|^~?")
_SWIFT_PUNCT = set("()[]{},;:@\\")
_SWIFT_LEFT_SPACE = set("([{,;:")
_SWIFT_RIGHT_SPACE = set(" \t\r\n\f\v)]},;:")
_SWIFT_REGEX_PREFIX_KEYWORDS = {
    "return", "case", "in", "where", "if", "guard", "while", "throw", "try", "await", "else", "switch", "for",
    "repeat", "is", "as", "yield", "then", "each", "some", "any",
}


def _is_ident_start(c: str) -> bool:
    return c.isalpha() or c == "_" or (ord(c) > 127 and not c.isspace())


def _is_ident_char(c: str) -> bool:
    return c.isalnum() or c == "_" or (ord(c) > 127 and not c.isspace())


class SwiftLexer:
    def __init__(self, text: str):
        self.text = text
        self.n = len(text)
        self.out = Lexed("swift")

    def run(self) -> Lexed:
        i = 0
        if self.text.startswith("#!"):
            end = self._line_end(0)
            self.out.comments.append(Comment(0, end, "shebang", self.text[0:end]))
            i = end
        self._scan(i, record=True, stop_at_paren=False)
        return self.out

    def _line_end(self, i: int) -> int:
        j = self.text.find("\n", i)
        return self.n if j < 0 else j

    def _scan(self, i: int, record: bool, stop_at_paren: bool) -> int:
        t = self.text
        n = self.n
        depth = 0
        newline_pending = False
        ws_before = True
        prev_kind: Optional[str] = None
        prev_text = ""
        tokens = self.out.tokens if record else []
        offsets = self.out.token_offsets if record else []

        def emit(kind: str, start: int, end: int):
            nonlocal newline_pending, ws_before, prev_kind, prev_text
            text = t[start:end]
            line_break = newline_pending and prev_kind is not None
            if kind == "op":
                left = not ws_before and not (prev_kind == "punct" and prev_text in _SWIFT_LEFT_SPACE)
                right = end < n and not (t[end] in _SWIFT_RIGHT_SPACE or t.startswith("//", end)
                                         or t.startswith("/*", end))
                tokens.append((kind, text, left, right, line_break))
            else:
                tokens.append((kind, text, line_break))
            offsets.append(start)
            newline_pending = False
            ws_before = False
            prev_kind, prev_text = kind, text

        while i < n:
            c = t[i]
            if c == "\n":
                newline_pending = True
                ws_before = True
                i += 1
                continue
            if c in " \t\r\f\v\0":
                ws_before = True
                i += 1
                continue
            if c == "/" and i + 1 < n and t[i + 1] == "/":
                end = self._line_end(i)
                body = t[i:end]
                style = "doc-line" if body.startswith("///") and not body.startswith("////") else "line"
                (self.out.comments if record else self.out.nested).append(Comment(i, end, style, body))
                ws_before = True
                i = end
                continue
            if c == "/" and i + 1 < n and t[i + 1] == "*":
                end = self._block_comment_end(i)
                body = t[i:end]
                is_doc = body.startswith("/**") and not body.startswith("/**/")
                (self.out.comments if record else self.out.nested).append(
                    Comment(i, end, "doc-block" if is_doc else "block", body))
                if "\n" in t[i:end]:
                    newline_pending = True
                ws_before = True
                i = end
                continue
            if c == '"' or (c == "#" and self._raw_string_ahead(i)):
                end = self._string_end(i)
                if record:
                    self.out.strings.append((i, end))
                emit("str", i, end)
                i = end
                continue
            if c == "#" and self._extended_regex_ahead(i):
                end = self._extended_regex_end(i)
                if record:
                    self.out.strings.append((i, end))
                emit("regex", i, end)
                i = end
                continue
            if c == "/" and self._bare_regex_ok(i, prev_kind, prev_text, ws_before):
                end = self._bare_regex_end(i)
                if end is not None:
                    if record:
                        self.out.strings.append((i, end))
                    emit("regex", i, end)
                    i = end
                    continue
            if c == "#":
                j = i + 1
                while j < n and _is_ident_char(t[j]):
                    j += 1
                emit("pound", i, j)
                i = j
                continue
            if c == "`":
                j = t.find("`", i + 1)
                if j < 0 or "\n" in t[i:j]:
                    emit("punct", i, i + 1)
                    i += 1
                else:
                    emit("ident", i, j + 1)
                    i = j + 1
                continue
            if c == "$" or _is_ident_start(c):
                j = i + 1
                while j < n and _is_ident_char(t[j]):
                    j += 1
                emit("ident", i, j)
                i = j
                continue
            if c.isdigit():
                j = self._number_end(i)
                emit("num", i, j)
                i = j
                continue
            if c == "." and not (i + 1 < n and (t[i + 1] == "." or t[i + 1] in _SWIFT_OPERATOR_CHARS)):
                emit("punct", i, i + 1)
                i += 1
                continue
            if c in _SWIFT_OPERATOR_CHARS or c == ".":
                j = i + 1
                dot_operator = c == "."
                while j < n:
                    d = t[j]
                    if d == "/" and j + 1 < n and t[j + 1] in "/*":
                        break
                    if d in _SWIFT_OPERATOR_CHARS or (dot_operator and d == "."):
                        j += 1
                        continue
                    break
                emit("op", i, j)
                i = j
                continue
            if c in _SWIFT_PUNCT:
                if stop_at_paren:
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        if depth == 0:
                            return i + 1
                        depth -= 1
                emit("punct", i, i + 1)
                i += 1
                continue
            emit("other", i, i + 1)
            i += 1
        if stop_at_paren:
            raise LexError("unterminated string interpolation")
        return i

    def _block_comment_end(self, i: int) -> int:
        t = self.text
        depth = 0
        j = i
        while j < self.n:
            if t.startswith("/*", j):
                depth += 1
                j += 2
            elif t.startswith("*/", j):
                depth -= 1
                j += 2
                if depth == 0:
                    return j
            else:
                j += 1
        raise LexError("unterminated block comment")

    def _raw_string_ahead(self, i: int) -> bool:
        j = i
        while j < self.n and self.text[j] == "#":
            j += 1
        return j < self.n and self.text[j] == '"'

    def _string_end(self, i: int) -> int:
        t = self.text
        hashes = 0
        while t[i + hashes] == "#":
            hashes += 1
        j = i + hashes
        multiline = t.startswith('"""', j)
        j += 3 if multiline else 1
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        while j < self.n:
            if t.startswith(escape, j):
                k = j + len(escape)
                if k < self.n and t[k] == "(":
                    j = self._scan(k + 1, record=False, stop_at_paren=True)
                    continue
                j = k + 1
                continue
            if t.startswith(close, j):
                return j + len(close)
            if not multiline and t[j] == "\n":
                raise LexError("unterminated string literal")
            j += 1
        raise LexError("unterminated string literal")

    def _extended_regex_ahead(self, i: int) -> bool:
        j = i
        while j < self.n and self.text[j] == "#":
            j += 1
        return j > i and j < self.n and self.text[j] == "/"

    def _extended_regex_end(self, i: int) -> int:
        t = self.text
        hashes = 0
        while t[i + hashes] == "#":
            hashes += 1
        j = i + hashes + 1
        close = "/" + "#" * hashes
        multiline = j < self.n and t[j] == "\n"
        while j < self.n:
            if t[j] == "\\" and j + 1 < self.n:
                j += 2
                continue
            if t.startswith(close, j):
                return j + len(close)
            if t[j] == "\n" and not multiline:
                raise LexError("unterminated regex literal")
            j += 1
        raise LexError("unterminated regex literal")

    def _bare_regex_ok(self, i: int, prev_kind: Optional[str], prev_text: str, ws_before: bool) -> bool:
        t = self.text
        if i + 1 >= self.n or t[i + 1] in " \t\r\n/*":
            return False
        if prev_kind is None:
            return True
        if prev_kind == "punct":
            return prev_text in _SWIFT_LEFT_SPACE
        if prev_kind == "op":
            return ws_before or prev_text in ("=",)
        if prev_kind == "ident":
            return prev_text in _SWIFT_REGEX_PREFIX_KEYWORDS
        return False

    def _bare_regex_end(self, i: int) -> Optional[int]:
        t = self.text
        j = i + 1
        in_class = 0
        while j < self.n:
            d = t[j]
            if d == "\n":
                return None
            if d == "\\":
                j += 2
                continue
            if d == "[":
                in_class += 1
            elif d == "]" and in_class:
                in_class -= 1
            elif d == "/" and not in_class:
                if t[j - 1] in " \t":
                    return None
                return j + 1
            j += 1
        return None

    def _number_end(self, i: int) -> int:
        t = self.text
        j = i
        hexa = t.startswith(("0x", "0X"), i)
        while j < self.n:
            d = t[j]
            if d.isalnum() or d == "_":
                if d in "eEpP" and j + 1 < self.n and t[j + 1] in "+-" and (d in "pP" or not hexa):
                    j += 2
                    continue
                j += 1
                continue
            if d == "." and j + 1 < self.n and t[j + 1].isdigit():
                j += 1
                continue
            break
        return j


_PY_DIRECTIVE = re.compile(r"^#\s*(?:type:|noqa|pragma\b|fmt:|pylint:|mypy:|isort:|pyright:|ruff:)")


def lex_python(text: str) -> Lexed:
    out = Lexed("python")
    starts = line_starts(text)
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, IndentationError, SyntaxError) as exc:
        raise LexError("python tokenize failed: %s" % exc)
    skip = {tokenize.COMMENT, tokenize.NL, tokenize.ENCODING}
    for tok in toks:
        (row, col), (erow, ecol) = tok.start, tok.end
        start = starts[row - 1] + col
        if tok.type == tokenize.COMMENT:
            end = start + len(tok.string)
            style = "line"
            if row == 1 and col == 0 and tok.string.startswith("#!"):
                style = "shebang"
            elif row <= 2 and re.match(r"^#.*coding[:=]\s*[-\w.]+", tok.string):
                style = "encoding"
            out.comments.append(Comment(start, end, style, tok.string))
            continue
        if tok.type in skip:
            continue
        if tok.type == tokenize.STRING:
            out.strings.append((start, starts[erow - 1] + ecol))
        name = tokenize.tok_name.get(tok.type, str(tok.type))
        if name.startswith("FSTRING") or name.startswith("TSTRING"):
            out.strings.append((start, starts[erow - 1] + ecol))
        out.tokens.append((name, tok.string))
        out.token_offsets.append(start)
    return out


def python_docstrings(text: str) -> List[Tuple[int, int]]:
    try:
        tree = ast.parse(text)
    except SyntaxError:
        return []
    found = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)) and node.body:
            first = node.body[0]
            if isinstance(first, ast.Expr) and isinstance(getattr(first, "value", None), ast.Constant) \
                    and isinstance(first.value.value, str):
                found.append((first.lineno, getattr(first, "end_lineno", first.lineno)))
    return sorted(found)


_SHELL_META = set(";&|()<>")
_SHELL_WS = set(" \t")


class ShellLexer:
    def __init__(self, text: str):
        self.text = text
        self.n = len(text)
        self.out = Lexed("shell")
        self.pending_heredocs: List[Tuple[str, bool]] = []

    def run(self) -> Lexed:
        i = 0
        if self.text.startswith("#!"):
            end = self._line_end(0)
            self.out.comments.append(Comment(0, end, "shebang", self.text[0:end]))
            i = end
        self._scan(i, record=True, stop_char=None)
        return self.out

    def _line_end(self, i: int) -> int:
        j = self.text.find("\n", i)
        return self.n if j < 0 else j

    def _emit(self, record: bool, kind: str, start: int, end: int):
        if not record:
            return
        if kind == "nl" and (not self.out.tokens or self.out.tokens[-1][0] == "nl"):
            return
        self.out.tokens.append((kind, self.text[start:end] if kind != "nl" else "\n"))
        self.out.token_offsets.append(start)

    def _scan(self, i: int, record: bool, stop_char: Optional[str]) -> int:
        t = self.text
        n = self.n
        word_start: Optional[int] = None
        paren_depth = 0

        def end_word(at: int):
            nonlocal word_start
            if word_start is not None:
                self._emit(record, "word", word_start, at)
                word_start = None

        while i < n:
            c = t[i]
            if stop_char is not None and c == ")" and paren_depth == 0:
                end_word(i)
                return i + 1
            if c == "\n":
                end_word(i)
                self._emit(record, "nl", i, i + 1)
                i += 1
                if self.pending_heredocs:
                    i = self._heredoc_bodies(i, record)
                continue
            if c in _SHELL_WS:
                end_word(i)
                i += 1
                continue
            if c == "#" and word_start is None:
                end = self._line_end(i)
                (self.out.comments if record else self.out.nested).append(Comment(i, end, "line", t[i:end]))
                i = end
                continue
            if c == "\\":
                if i + 1 < n and t[i + 1] == "\n":
                    end_word(i)
                    i += 2
                    continue
                if word_start is None:
                    word_start = i
                i += 2
                continue
            if c == "'":
                if word_start is None:
                    word_start = i
                j = t.find("'", i + 1)
                if j < 0:
                    raise LexError("unterminated single quote")
                self._record_string(record, i, j + 1)
                i = j + 1
                continue
            if c == '"':
                if word_start is None:
                    word_start = i
                j = self._double_quote_end(i)
                self._record_string(record, i, j)
                i = j
                continue
            if c == "`":
                if word_start is None:
                    word_start = i
                j = i + 1
                while j < n and t[j] != "`":
                    j += 2 if t[j] == "\\" else 1
                if j >= n:
                    raise LexError("unterminated backquote")
                i = j + 1
                continue
            if c == "$" and i + 1 < n:
                if word_start is None:
                    word_start = i
                i = self._dollar(i, record)
                continue
            if c == "<" and t.startswith("<<", i) and not t.startswith("<<<", i):
                end_word(i)
                i = self._heredoc_operator(i, record)
                continue
            if c in _SHELL_META:
                end_word(i)
                j = i + 1
                while j < n and t[j] in _SHELL_META and t[j] not in "()" and c not in "()":
                    j += 1
                if stop_char is not None:
                    if c == "(":
                        paren_depth += 1
                    elif c == ")":
                        paren_depth -= 1
                self._emit(record, "op", i, j)
                i = j
                continue
            if word_start is None:
                word_start = i
            i += 1
        end_word(i)
        if stop_char is not None:
            raise LexError("unterminated command substitution")
        return i

    def _record_string(self, record: bool, start: int, end: int):
        if record:
            self.out.strings.append((start, end))

    def _double_quote_end(self, i: int) -> int:
        t = self.text
        j = i + 1
        while j < self.n:
            d = t[j]
            if d == "\\":
                j += 2
                continue
            if d == '"':
                return j + 1
            if d == "$" and j + 1 < self.n:
                j = self._dollar(j, record=False)
                continue
            if d == "`":
                k = j + 1
                while k < self.n and t[k] != "`":
                    k += 2 if t[k] == "\\" else 1
                j = k + 1
                continue
            j += 1
        raise LexError("unterminated double quote")

    def _dollar(self, i: int, record: bool) -> int:
        t = self.text
        nxt = t[i + 1]
        if t.startswith("$((", i):
            return self._balanced(i + 3, "(", ")", 2)
        if nxt == "(":
            return self._scan(i + 2, record=False, stop_char=")")
        if nxt == "{":
            return self._balanced(i + 2, "{", "}", 1)
        if nxt == "'":
            j = i + 2
            while j < self.n and t[j] != "'":
                j += 2 if t[j] == "\\" else 1
            if j >= self.n:
                raise LexError("unterminated $'...'")
            return j + 1
        if nxt == '"':
            return self._double_quote_end(i + 1)
        return i + 2 if not (nxt.isalnum() or nxt == "_") else self._name_end(i + 1)

    def _name_end(self, j: int) -> int:
        t = self.text
        if t[j].isdigit():
            return j + 1
        while j < self.n and (t[j].isalnum() or t[j] == "_"):
            j += 1
        return j

    def _balanced(self, j: int, opener: str, closer: str, need: int) -> int:
        t = self.text
        depth = need
        while j < self.n:
            d = t[j]
            if d == "\\":
                j += 2
                continue
            if d == "'" and opener == "{":
                k = t.find("'", j + 1)
                j = (k + 1) if k >= 0 else self.n
                continue
            if d == '"':
                j = self._double_quote_end(j)
                continue
            if d == "$" and j + 1 < self.n and t[j + 1] in "({":
                j = self._dollar(j, record=False)
                continue
            if d == opener:
                depth += 1
            elif d == closer:
                depth -= 1
                if (opener == "(" and depth == 0) or (opener == "{" and depth == 0):
                    return j + 1
            j += 1
        raise LexError("unterminated expansion")

    def _heredoc_operator(self, i: int, record: bool) -> int:
        t = self.text
        j = i + 2
        strip_tabs = False
        if j < self.n and t[j] == "-":
            strip_tabs = True
            j += 1
        while j < self.n and t[j] in _SHELL_WS:
            j += 1
        k = j
        delim = []
        while k < self.n and t[k] not in " \t\n;&|()<>":
            if t[k] in "'\"":
                q = t[k]
                e = t.find(q, k + 1)
                if e < 0:
                    raise LexError("unterminated heredoc delimiter")
                delim.append(t[k + 1:e])
                k = e + 1
                continue
            if t[k] == "\\":
                if k + 1 < self.n:
                    delim.append(t[k + 1])
                k += 2
                continue
            delim.append(t[k])
            k += 1
        if not delim:
            self._emit(record, "op", i, j)
            return j
        self.pending_heredocs.append(("".join(delim), strip_tabs))
        self._emit(record, "op", i, i + (3 if strip_tabs else 2))
        self._emit(record, "word", j, k)
        return k

    def _heredoc_bodies(self, i: int, record: bool) -> int:
        t = self.text
        while self.pending_heredocs:
            delim, strip_tabs = self.pending_heredocs.pop(0)
            start = i
            while True:
                if i >= self.n:
                    raise LexError("unterminated heredoc " + delim)
                end = self._line_end(i)
                line = t[i:end]
                if (line.lstrip("\t") if strip_tabs else line) == delim:
                    self._emit(record, "heredoc", start, end)
                    i = min(end + 1, self.n)
                    break
                i = end + 1
        return i


def lex_yaml(text: str) -> Lexed:
    out = Lexed("yaml")
    offset = 0
    block_parent: Optional[int] = None
    in_quote: Optional[str] = None
    for raw_line in text.split("\n"):
        line = raw_line.rstrip("\r")
        line_offset = offset
        offset += len(raw_line) + 1
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if block_parent is not None:
            if stripped == "":
                out.tokens.append(("block", line))
                out.token_offsets.append(line_offset)
                continue
            if indent > block_parent:
                out.tokens.append(("block", line))
                out.token_offsets.append(line_offset)
                continue
            block_parent = None
        comment_at, in_quote, block_parent = _yaml_scan_line(line, in_quote, out, line_offset)
        content = line[:comment_at] if comment_at is not None else line
        if comment_at is not None:
            out.comments.append(Comment(line_offset + comment_at, line_offset + len(line), "line", line[comment_at:]))
        if content.strip() != "" or in_quote is not None:
            out.tokens.append(("line", content.rstrip()))
            out.token_offsets.append(line_offset)
    if in_quote is not None:
        raise LexError("unterminated YAML quoted scalar")
    return out


_YAML_BLOCK_INDICATOR = re.compile(r"[|>][-+0-9]*\s*(?:#.*)?$")


def _yaml_scan_line(line: str, in_quote: Optional[str], out: Lexed, line_offset: int):
    j = 0
    n = len(line)
    scalar_start = True
    key_column = len(line) - len(line.lstrip(" "))
    dash_column = key_column
    last_structure = None
    quote_from = 0 if in_quote else None
    while j < n:
        c = line[j]
        if in_quote == '"':
            if c == "\\":
                j += 2
                continue
            if c == '"':
                in_quote = None
                out.strings.append((line_offset + (quote_from or 0), line_offset + j + 1))
                scalar_start = False
            j += 1
            continue
        if in_quote == "'":
            if c == "'" and j + 1 < n and line[j + 1] == "'":
                j += 2
                continue
            if c == "'":
                in_quote = None
                out.strings.append((line_offset + (quote_from or 0), line_offset + j + 1))
                scalar_start = False
            j += 1
            continue
        if c == "#" and (j == 0 or line[j - 1] in " \t"):
            return j, None, None
        if c in " \t":
            j += 1
            continue
        if scalar_start and c in "\"'":
            in_quote = c
            quote_from = j
            j += 1
            continue
        if scalar_start and c in "|>" and _YAML_BLOCK_INDICATOR.match(line, j):
            m = re.search(r"\s#", line[j:])
            comment_at = (j + m.start() + 1) if m else None
            parent = dash_column if last_structure == "-" else key_column
            return comment_at, None, parent
        if c == "-" and (j + 1 == n or line[j + 1] in " \t") and scalar_start:
            dash_column = j
            last_structure = "-"
            j += 1
            k = j
            while k < n and line[k] == " ":
                k += 1
            key_column = k
            continue
        if c in "[{,":
            scalar_start = True
            j += 1
            continue
        if c == ":" and (j + 1 == n or line[j + 1] in " \t"):
            scalar_start = True
            last_structure = ":"
            j += 1
            continue
        if c == "?" and (j + 1 == n or line[j + 1] in " \t") and scalar_start:
            j += 1
            continue
        scalar_start = False
        j += 1
    if in_quote is not None and quote_from is not None:
        out.strings.append((line_offset + quote_from, line_offset + n))
    return None, in_quote, None


def _pieces(text: str, comments: Sequence[Comment], remove: Sequence[bool]):
    pieces = []
    pos = 0
    for comment, drop in zip(comments, remove):
        _split_code(text, pos, comment.start, pieces)
        pieces.append(["comment", text[comment.start:comment.end], drop])
        pos = comment.end
    _split_code(text, pos, len(text), pieces)
    return pieces


_CODE_SPLIT = re.compile(r"\n|[ \t\r\f\v]+|[^ \t\r\f\v\n]+")


def _split_code(text: str, start: int, end: int, pieces: list):
    for m in _CODE_SPLIT.finditer(text, start, end):
        s = m.group(0)
        if s == "\n":
            pieces.append(["nl", s, False])
        elif s[0] in " \t\r\f\v":
            pieces.append(["ws", s, False])
        else:
            pieces.append(["code", s, False])


_OPENING_LINE_END = ("{", "(", "[")


def remove_comments(text: str, comments: Sequence[Comment], remove: Sequence[bool], language: str) -> str:
    if not any(remove):
        return text
    order = sorted(range(len(comments)), key=lambda k: comments[k].start)
    comments = [comments[k] for k in order]
    remove = [remove[k] for k in order]
    pieces = _pieces(text, comments, remove)
    lines: List[list] = [[]]
    terminated: List[bool] = []
    for p in pieces:
        if p[0] == "nl":
            terminated.append(True)
            lines.append([])
        else:
            lines[-1].append(p)
    terminated.append(False)
    if not lines[-1] and len(lines) > 1:
        lines.pop()
        terminated.pop()
    dropped = [False] * len(lines)
    touched = [False] * len(lines)
    for idx, line in enumerate(lines):
        if not any(p[0] == "comment" and p[2] for p in line):
            continue
        touched[idx] = True
        if all(p[0] == "ws" or (p[0] == "comment" and p[2]) for p in line):
            dropped[idx] = True
            continue
        lines[idx] = _rebuild_line(line)
    if language != "yaml":
        _cleanup_blank_lines(lines, dropped, touched, language)
    out = []
    for idx, line in enumerate(lines):
        if dropped[idx]:
            continue
        out.append("".join(p[1] for p in line))
        if terminated[idx]:
            out.append("\n")
    result = "".join(out)
    if text.endswith("\n") and result and not result.endswith("\n"):
        result += "\n"
    return result


def _rebuild_line(line: list) -> list:
    line = [list(p) for p in line]
    while True:
        k = next((i for i, p in enumerate(line) if p[0] == "comment" and p[2]), None)
        if k is None:
            break
        prev = line[k - 1] if k > 0 else None
        nxt = line[k + 1] if k + 1 < len(line) else None
        multiline = "\n" in line[k][1]
        prev_code = prev is not None and prev[0] != "ws"
        next_code = nxt is not None and nxt[0] != "ws"
        if nxt is None:
            del line[k]
            while line and line[-1][0] == "ws":
                line.pop()
            continue
        if prev_code and next_code:
            line[k] = ["ws", "\n" if multiline else " ", False]
            continue
        if multiline and prev is not None and any(p[0] != "ws" for p in line[:k]) and \
                any(p[0] != "ws" for p in line[k + 1:]):
            line[k] = ["ws", "\n", False]
            if prev[0] == "ws":
                del line[k - 1]
                k -= 1
            if k + 1 < len(line) and line[k + 1][0] == "ws":
                del line[k + 1]
            continue
        if prev is None or prev[0] == "ws":
            if nxt[0] == "ws":
                del line[k:k + 2]
            elif prev is not None and nxt[1][:1] in ")]},;" and k >= 2:
                del line[k - 1:k + 1]
            else:
                del line[k]
            continue
        if prev[1][-1:] in "([{" and nxt[0] == "ws" and k + 2 < len(line):
            del line[k:k + 2]
            continue
        del line[k]
    return line


def _is_blank(line: list) -> bool:
    return all(p[0] == "ws" for p in line)


def _cleanup_blank_lines(lines: List[list], dropped: List[bool], touched: List[bool], language: str):
    n = len(lines)
    idx = 0
    openers = _OPENING_LINE_END + ((":",) if language == "python" else ())
    while idx < n:
        if not (dropped[idx] and touched[idx]):
            idx += 1
            continue
        end = idx
        while end + 1 < n and dropped[end + 1] and touched[end + 1]:
            end += 1
        p = idx - 1
        while p >= 0 and dropped[p]:
            p -= 1
        q = end + 1
        while q < n and dropped[q]:
            q += 1
        prev_blank = p >= 0 and _is_blank(lines[p])
        next_blank = q < n and _is_blank(lines[q])
        prev_text = "".join(x[1] for x in lines[p]).rstrip() if p >= 0 else ""
        next_text = "".join(x[1] for x in lines[q]).lstrip() if q < n else ""
        if p < 0 or prev_text.endswith(openers):
            k = q
            while k < n and not dropped[k] and _is_blank(lines[k]):
                dropped[k] = True
                k += 1
                while k < n and dropped[k]:
                    k += 1
        elif q >= n or next_text.startswith(("}", ")", "]")):
            k = p
            while k >= 0 and _is_blank(lines[k]) and not dropped[k]:
                dropped[k] = True
                k -= 1
                while k >= 0 and dropped[k]:
                    k -= 1
        elif prev_blank and next_blank:
            dropped[q] = True
        idx = end + 1
