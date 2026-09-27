//// An image the composer holds, as data.
////
//// The record is separate from `tui/image_drop`, which reads a dropped file
//// from disk, because the composer and the transcript only carry and show
//// an image that has already been read. Keeping the file read out of this
//// module keeps the composer free of the file system.

/// The largest image file admitted before a prompt frame is constructed.
pub const max_image_bytes = 20_971_520

/// One locally admitted image attachment.
pub type Image {
  Image(
    /// The local path used only for later presentation and removal.
    local_path: String,
    /// The path's final component shown in the composer.
    filename: String,
    /// The media type established from magic bytes, not the extension.
    mime_type: String,
    /// The exact file size read into the attachment.
    byte_size: Int,
    /// Base64-encoded image bytes sent through the typed user-block codec.
    data: String,
  )
}
