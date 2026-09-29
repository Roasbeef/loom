//// The composer's editor and form, for `<loom-composer>`.
////
//// The server draws the editor, an uncontrolled `textarea`, and the form
//// around it, and the browser owns the text as the operator types. The
//// component needs four things from the page that no Gleam library offers
//// on the JavaScript target: `gleam_stdlib` has no DOM, and Lustre's effects
//// hand a component its shadow root but neither write another element's
//// value nor submit a form. So these functions are JavaScript, in
//// `composer.mjs` beside this module. They write the editor's value, submit
//// the composer's own form and read the text of a child the server drew;
//// none of them reads what the operator typed, and each finds its elements
//// from the component's own shadow root, never from the document.

import gleam/dynamic.{type Dynamic}

/// Replaces the editor's draft with `text`, puts the caret after it and
/// gives the editor focus. The component's own shadow root is `root`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_composer.place(root, "/compact")
/// ```
@external(javascript, "./composer.mjs", "place")
pub fn place(root: Dynamic, text: String) -> Nil

/// Submits the form the component sits in, as a press of its first submit
/// button does.
///
/// ## Examples
///
/// ```gleam
/// // ffi_composer.send(root)
/// ```
@external(javascript, "./composer.mjs", "send")
pub fn send(root: Dynamic) -> Nil

/// Brings the prompts the server drew in the `returned` slot into the
/// editor, oldest first, each as the draft when the editor is empty and
/// below what the operator has typed, after a blank line, when it is not.
/// Prompts numbered up to `baseline`, and any this element has taken before,
/// are left where they are, so a second call for the same prompts adds
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_composer.restore(root, 0)
/// ```
@external(javascript, "./composer.mjs", "restore")
pub fn restore(root: Dynamic, baseline: Int) -> Nil

/// Scrolls the completion list so its highlighted row is inside it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_composer.reveal(root)
/// ```
@external(javascript, "./composer.mjs", "reveal")
pub fn reveal(root: Dynamic) -> Nil
