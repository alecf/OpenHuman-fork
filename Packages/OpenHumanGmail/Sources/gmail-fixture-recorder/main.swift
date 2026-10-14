import Foundation

FileHandle.standardError.write(Data("""
gmail-fixture-recorder: disabled stub. No recording against real accounts is implemented; nothing was read or written.

""".utf8))
exit(64)
