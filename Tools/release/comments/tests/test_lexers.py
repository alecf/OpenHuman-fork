import unittest

from support import dedent, lexers


def comment_texts(language, text):
    return [c.text for c in lexers.lex(language, text).comments]


class SwiftLexerTests(unittest.TestCase):
    def test_comment_markers_inside_strings_are_not_comments(self):
        source = dedent('''
            let url = "https://example.com/a//b" // trailing
            let glob = "Prompts/*.txt"
            let raw = #"a "quoted" // not /* nor */ this"#
            let block = """
                // inside a multi-line string
                /* also inside */ \\(value + 1) "\\("inner // x")"
                """
            let rawBlock = #"""
                \\#(x) // text "# still text
                """#
        ''')
        self.assertEqual(comment_texts("swift", source), ["// trailing"])

    def test_interpolation_closes_on_the_matching_parenthesis(self):
        source = 'let s = "a \\(f(g(1), ")")) /* not a comment b" // real\n'
        self.assertEqual(comment_texts("swift", source), ["// real"])

    def test_comments_inside_interpolations_are_reported_as_nested(self):
        lexed = lexers.lex("swift", 'let s = "\\(x /* inner */ + 1)" // outer\n')
        self.assertEqual([c.text for c in lexed.comments], ["// outer"])
        self.assertEqual([c.text for c in lexed.nested], ["/* inner */"])

    def test_nested_block_comments(self):
        source = "/* outer /* nested */ still outer */ let a = 1\n"
        self.assertEqual(comment_texts("swift", source), ["/* outer /* nested */ still outer */"])

    def test_regex_literals_hide_slashes(self):
        source = dedent('''
            let a = #/\\/\\/ (?<x>[a-z]+)/#
            let b = #/~/\\.ssh|/Users/[^/]+/#
            let c = text.matches(of: /a\\/b/) // after regex
            let d = x / y / z // division
        ''')
        self.assertEqual(comment_texts("swift", source), ["// after regex", "// division"])

    def test_doc_comment_styles(self):
        lexed = lexers.lex("swift", "/// doc\n//// not doc\n/** block doc */\n/**/\n// plain\n")
        self.assertEqual([c.style for c in lexed.comments], ["doc-line", "line", "doc-block", "block", "line"])

    def test_pound_directives_are_tokens_not_comments(self):
        lexed = lexers.lex("swift", "#if DEBUG\nlet a = 1\n#endif\n")
        self.assertEqual(lexed.comments, [])
        self.assertIn(("pound", "#if", False), lexed.tokens)

    def test_operator_tokens_record_spacing_with_comments_as_space(self):
        tokens = lexers.lex("swift", "a/*c*/+b\n").tokens
        self.assertIn(("op", "+", False, True, False), tokens)
        self.assertEqual(lexers.lex("swift", "a +b\n").tokens, tokens)

    def test_line_numbers(self):
        lexed = lexers.lex("swift", "let a = 1\n/* two\nlines */\n// four\n")
        self.assertEqual([(c.line, c.end_line) for c in lexed.comments], [(2, 3), (4, 4)])

    def test_unterminated_string_is_an_error(self):
        with self.assertRaises(lexers.LexError):
            lexers.lex("swift", 'let a = "open\n')


class PythonLexerTests(unittest.TestCase):
    def test_hash_inside_strings_is_not_a_comment(self):
        source = dedent('''
            #!/usr/bin/env python3
            x = "# not"  # real
            y = f"{x}#{'#'}"
            z = """
            # inside a docstring-like string
            """
        ''')
        lexed = lexers.lex("python", source)
        self.assertEqual([(c.style, c.text) for c in lexed.comments], [("shebang", "#!/usr/bin/env python3"),
                                                                       ("line", "# real")])

    def test_encoding_line(self):
        lexed = lexers.lex("python", "# -*- coding: utf-8 -*-\nx = 1\n")
        self.assertEqual(lexed.comments[0].style, "encoding")

    def test_docstrings_are_found(self):
        self.assertEqual(lexers.python_docstrings('"""Module."""\ndef f():\n    """F."""\n'), [(1, 1), (3, 3)])


class ShellLexerTests(unittest.TestCase):
    def test_hash_that_does_not_start_a_word(self):
        source = dedent('''
            #!/usr/bin/env bash
            echo "# not" '# not' a#b $# ${#arr[@]} ${x#pre} $((16#ff)) # real
            [[ $x == *#* ]] && echo ok;# after semicolon
        ''')
        lexed = lexers.lex("shell", source)
        self.assertEqual([c.text for c in lexed.comments],
                         ["#!/usr/bin/env bash", "# real", "# after semicolon"])

    def test_heredoc_bodies_are_not_comments(self):
        source = dedent('''
            cat <<EOF
            # heredoc text
            EOF
            cat <<-'END'
            \t# indented heredoc text
            \tEND
            # real
        ''')
        self.assertEqual(comment_texts("shell", source), ["# real"])

    def test_comment_inside_command_substitution_is_nested(self):
        lexed = lexers.lex("shell", "x=$(echo hi # inner\n)\n# outer\n")
        self.assertEqual([c.text for c in lexed.comments], ["# outer"])
        self.assertEqual([c.text for c in lexed.nested], ["# inner"])

    def test_language_detection_by_shebang(self):
        self.assertEqual(lexers.detect_language("bin/tool", "#!/bin/bash\n"), "shell")
        self.assertEqual(lexers.detect_language("bin/tool", "#!/usr/bin/env python3\n"), "python")
        self.assertIsNone(lexers.detect_language("notes.md", "# Title\n"))


class YamlLexerTests(unittest.TestCase):
    def test_comments_quotes_and_block_scalars(self):
        source = dedent('''
            # top
            name: Mail # trailing
            url: https://example.com/page#fragment
            quoted: "a # b"
            single: 'it''s # fine'
            plain: a#b
            steps:
              - run: |
                  # shell text, not YAML
                  echo hi
              - |
                # also text
            flow: { path: ../x }   # after flow
            next: value
        ''')
        self.assertEqual(comment_texts("yaml", source), ["# top", "# trailing", "# after flow"])

    def test_multiline_quoted_scalar(self):
        source = 'a: "first # line\n  second" # real\n'
        self.assertEqual(comment_texts("yaml", source), ["# real"])


if __name__ == "__main__":
    unittest.main()
