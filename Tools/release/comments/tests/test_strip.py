import os
import re
import unittest

from support import quiet, TempDirTestCase, dedent, lexers, strip, strip_comments


class SwiftStripTests(unittest.TestCase):
    def test_removes_comments_and_keeps_strings(self):
        source = dedent('''
            // header
            import Foundation

            /// Doc.
            struct A {
                let url = "https://example.com//x" // trailing
                let glob = "Prompts/*.txt"   /* block */
                let raw = #"// not a comment"#
            }
        ''')
        self.assertEqual(strip(source).stripped, dedent('''
            import Foundation

            struct A {
                let url = "https://example.com//x"
                let glob = "Prompts/*.txt"
                let raw = #"// not a comment"#
            }
        '''))

    def test_inline_block_comments_keep_tokens_apart(self):
        self.assertEqual(strip("let a = b/*x*/+c\n").stripped, "let a = b +c\n")
        self.assertEqual(strip("let a = f(/* x */ 1)\n").stripped, "let a = f(1)\n")
        self.assertEqual(strip("call() /* a */ // b\n").stripped, "call()\n")
        self.assertEqual(strip("foo /* x\n y */ bar\n").stripped, "foo\nbar\n")

    def test_compiler_directives_survive(self):
        source = "#if DEBUG\n// debug only\nlet a = 1\n#endif\n"
        self.assertEqual(strip(source).stripped, "#if DEBUG\nlet a = 1\n#endif\n")

    def test_allow_list(self):
        source = dedent('''
            // swift-tools-version: 6.4
            // swiftlint:disable:next force_cast
            // explanation that goes
            let a = b as! C
            // Why: Gmail drops the header otherwise.
            let h = 1
            // MARK: - Section
            let m = 1
        ''')
        result = strip(source, path="Package.swift")
        self.assertEqual(result.stripped, dedent('''
            // swift-tools-version: 6.4
            // swiftlint:disable:next force_cast
            let a = b as! C
            // Why: Gmail drops the header otherwise.
            let h = 1
            let m = 1
        '''))
        self.assertEqual(result.kept_reasons(), {"directive": 2, "why": 1})
        kept_mark = strip(source, path="Package.swift", keep_mark=True)
        self.assertIn("// MARK: - Section\n", kept_mark.stripped)

    def test_generator_markers_and_keep_patterns(self):
        source = dedent('''
            public struct A {   // no-generated-init
                // generated-init: Tools/ci/gen-public-inits.py
                public init() {}
                // end generated-init
                // prose
                // @custom-marker keep me
            }
        ''')
        result = strip(source, keep_patterns=[re.compile(r"@custom-marker")])
        self.assertEqual(result.stripped, source.replace("    // prose\n", ""))
        self.assertEqual(result.kept_reasons(), {"directive": 3, "keep-pattern": 1})

    def test_license_word_alone_is_not_a_license_header(self):
        self.assertEqual(strip("// Needs `tool license` accepted first.\nlet a = 1\n").stripped, "let a = 1\n")
        self.assertEqual(strip("// Licensed under the Apache License, Version 2.0\nlet a = 1\n").kept_reasons(),
                         {"license": 1})

    def test_license_header_is_kept_only_before_code(self):
        source = dedent('''
            // Copyright 2026 Example Contributors
            // SPDX-License-Identifier: Apache-2.0

            import Foundation
            // This license text is not a header.
            let a = 1
        ''')
        result = strip(source)
        self.assertTrue(result.stripped.startswith("// Copyright 2026 Example Contributors\n// SPDX"))
        self.assertNotIn("not a header", result.stripped)

    def test_long_or_multi_line_why_is_kept_and_flagged(self):
        result = strip("// Why: " + "x" * 200 + "\nlet a = 1\n// Why: one\n// and two\nlet b = 2\n")
        self.assertEqual([b.flag for b in result.blocks], ["why-too-long", "why-too-long"])
        self.assertEqual(strip("// Why: short.\nlet a = 1\n").blocks[0].flag, None)

    def test_public_doc_option(self):
        source = dedent('''
            /// Kept when asked.
            @MainActor public final class A {}
            /// Not public.
            func f() {}
            /// Two lines
            /// are too many.
            public func g() {}
            /// Setter scope does not hide public.
            public private(set) var v = 1
        ''')
        self.assertNotIn("///", strip(source).stripped)
        kept = strip(source, keep_public_doc=True).stripped
        self.assertIn("/// Kept when asked.", kept)
        self.assertIn("/// Setter scope does not hide public.", kept)
        self.assertNotIn("Not public", kept)
        self.assertNotIn("too many", kept)

    def test_keep_file_entries(self):
        source = "let a = 1\n// first\n// block\nlet b = 2\n// second\nlet c = 3\n"
        result = strip(source, path="Sources/A.swift",
                       keep_entries=[("Sources/A.swift", "3"), ("Sources/A.swift", "second")])
        self.assertEqual(result.stripped, source)
        self.assertEqual(result.kept_reasons(), {"keep-file": 2})

    def test_generated_files_are_skipped(self):
        source = "// GENERATED by a tool. Do not edit.\nlet a = 1 // x\n"
        result = strip(source)
        self.assertEqual(result.skipped, "generated")
        self.assertEqual(result.stripped, source)

    def test_nested_comments_are_left_and_flagged(self):
        result = strip('let s = "\\(x /* inner */ + 1)"\n')
        self.assertEqual(result.stripped, 'let s = "\\(x /* inner */ + 1)"\n')
        self.assertEqual([b.flag for b in result.blocks], ["nested-comment"])

    def test_blank_lines_left_by_removed_comments(self):
        self.assertEqual(strip("import A\n\n// c\n\nlet x = 1\n").stripped, "import A\n\nlet x = 1\n")
        self.assertEqual(strip("func f() {\n    // c\n\n    return\n}\n").stripped, "func f() {\n    return\n}\n")
        self.assertEqual(strip("func f() {\n    x()\n\n    // c\n}\n").stripped, "func f() {\n    x()\n}\n")
        self.assertEqual(strip("// header\n\nimport A\n").stripped, "import A\n")
        self.assertEqual(strip("let a = 1\n\n// c\n").stripped, "let a = 1\n")

    def test_idempotent(self):
        source = "// a\nlet a = 1 // b\n/* c */\nlet s = \"//\"\n"
        once = strip(source).stripped
        self.assertEqual(strip(once).stripped, once)
        self.assertEqual(strip(once).counts()["removed"], 0)


class OtherLanguageStripTests(unittest.TestCase):
    def test_python(self):
        source = dedent('''
            #!/usr/bin/env python3
            # -*- coding: utf-8 -*-
            """Docstring stays."""
            import os  # trailing
            x = "# not a comment"
            # full line


            def f():
                # inside
                return 1  # type: ignore
        ''')
        result = strip(source, path="tool.py")
        self.assertEqual(result.stripped, dedent('''
            #!/usr/bin/env python3
            # -*- coding: utf-8 -*-
            """Docstring stays."""
            import os
            x = "# not a comment"


            def f():
                return 1  # type: ignore
        '''))
        self.assertEqual(result.docstrings, 1)

    def test_shell(self):
        source = dedent('''
            #!/usr/bin/env bash
            # header
            set -euo pipefail
            echo "# not" a#b $# # trailing
            cat <<EOF
            # heredoc stays
            EOF
            # shellcheck disable=SC2086
            echo $x
        ''')
        self.assertEqual(strip(source, path="run.sh").stripped, dedent('''
            #!/usr/bin/env bash
            set -euo pipefail
            echo "# not" a#b $#
            cat <<EOF
            # heredoc stays
            EOF
            # shellcheck disable=SC2086
            echo $x
        '''))

    def test_shell_help_printed_from_the_script_is_kept_and_flagged(self):
        source = dedent('''
            #!/usr/bin/env bash
            # Usage: run.sh [--help]
            #   prints this text
            set -e
            # internal note
            [[ "${1:-}" == --help ]] && { sed -n '2,3p' "$0"; exit 0; }
            awk '{ print $0 }' file # awk's $0 is not the script
        ''')
        result = strip(source, path="run.sh")
        self.assertIn("# Usage: run.sh [--help]\n#   prints this text\n", result.stripped)
        self.assertNotIn("internal note", result.stripped)
        self.assertEqual([b.flag for b in result.blocks if b.flag], ["reads-own-source"])
        awk_help = dedent('''
            #!/usr/bin/env bash
            # Usage: sweep.sh
            #   -h, --help
            set -e
            # note
            usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
        ''')
        kept = strip(awk_help, path="sweep.sh")
        self.assertIn("# Usage: sweep.sh\n#   -h, --help\n", kept.stripped)
        self.assertNotIn("# note", kept.stripped)
        other = strip("#!/bin/bash\n# header\necho x # c\nawk '{ print $0 }' f\n", path="x.sh")
        self.assertEqual(other.stripped, "#!/bin/bash\necho x\nawk '{ print $0 }' f\n")

    def test_awk_program_inside_command_substitution_is_not_a_self_read(self):
        source = (
            "#!/usr/bin/env bash\n# header\nM=\"$(printf x | awk 'NF { print substr($0, 2) }')\"\n"
        )
        result = strip(source, path="id.sh")
        self.assertEqual(result.stripped, "#!/usr/bin/env bash\nM=\"$(printf x | awk 'NF { print substr($0, 2) }')\"\n")
        self.assertEqual([b.flag for b in result.blocks if b.flag], [])

    def test_shell_without_shebang_verifies(self):
        source = "# header\n\necho hi # c\n"
        stripped = strip(source, path="lib.sh").stripped
        self.assertEqual(stripped, "echo hi\n")
        self.assertEqual(lexers.lex("shell", source).tokens, lexers.lex("shell", stripped).tokens)

    def test_yaml_keeps_blank_lines(self):
        source = "a: |\n  text\n\n# c\nb: x # d\n"
        self.assertEqual(strip(source, path="x.yml").stripped, "a: |\n  text\n\nb: x\n")

    def test_markdown_is_not_touched(self):
        result = strip("```swift\n// code\n```\n", path="README.md")
        self.assertEqual(result.skipped, "unsupported")


class TreeTests(TempDirTestCase):
    def test_check_mode_and_write(self):
        self.write("Sources/A.swift", "// remove me\nlet a = 1\n")
        self.write("notes.md", "// untouched\n")
        root = self.tmp
        self.assertEqual(quiet(strip_comments.main, ["--root", root, "--check", "Sources", "notes.md"]), 1)
        self.assertEqual(quiet(strip_comments.main, ["--root", root, "--write", "Sources", "notes.md"]), 0)
        with open(os.path.join(root, "Sources/A.swift")) as handle:
            self.assertEqual(handle.read(), "let a = 1\n")
        with open(os.path.join(root, "notes.md")) as handle:
            self.assertEqual(handle.read(), "// untouched\n")
        self.assertEqual(quiet(strip_comments.main, ["--root", root, "--check", "Sources"]), 0)

    def test_lex_errors_leave_the_file_alone(self):
        self.write("Bad.swift", 'let a = "open\n// c\n')
        results = strip_comments.process_tree(self.tmp, ["Bad.swift"], write=True)
        self.assertTrue(results[0].error)
        with open(os.path.join(self.tmp, "Bad.swift")) as handle:
            self.assertIn("// c", handle.read())


if __name__ == "__main__":
    unittest.main()
