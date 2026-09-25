//// `lsp/range` — positions and edits exactly as the language server
//// states them, before the harness converts them.
////
//// These are the protocol's own coordinates: zero-based lines and
//// zero-based character offsets counted in **UTF-16 code units**, which
//// is what LSP means when neither side negotiates a `positionEncoding`
//// (both measured servers negotiate none — ADR-013). They exist as their
//// own module so the wire decoders (`lsp/protocol`) and the pure text
//// arithmetic that converts and applies them (`lsp/text`) share one
//// definition without either importing the other.
////
//// Nothing outside `packages/lsp` should hold one of these. The harness
//// speaks `lsp/query.Site`, 1-based and counted in codepoints; the
//// conversion happens once, in `lsp/text`, against the document text the
//// position was computed on.

/// A position in a document, in the server's coordinates.
pub type Position {
  Position(
    /// Zero-based line.
    line: Int,
    /// Zero-based offset into the line, in UTF-16 code units.
    character: Int,
  )
}

/// A half-open span `[start, end)` in a document.
pub type Range {
  Range(start: Position, end: Position)
}

/// One replacement the server asks for: the text in `range` becomes
/// `new_text`. An empty range is an insertion; an empty `new_text` is a
/// deletion.
pub type TextEdit {
  TextEdit(range: Range, new_text: String)
}
