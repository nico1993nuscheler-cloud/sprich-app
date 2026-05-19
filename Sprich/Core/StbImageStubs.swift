import Foundation

/// stb_image symbol stubs for the Release-config link.
///
/// Why this file exists: the LocalLLMClient Swift Package's
/// `LocalLLMClientLlama/stb_image.swift` provides `stbi_load`,
/// `stbi_load_from_memory`, and `stbi_image_free` via `@_silgen_name`,
/// renaming the Swift functions with C-style symbol names so the package's
/// C++ multimodal helper (`mtmd_helper_bitmap_init_from_buf` in
/// `LocalLLMClientLlamaC`) can call them.
///
/// In Debug those Swift functions emit unconditionally and the C++ side
/// links cleanly. In Release, Swift's whole-module optimizer sees no Swift
/// caller of the `stb_image.swift` functions and dead-strips them before
/// the linker runs — `@_silgen_name` only renames, it doesn't force-emit.
/// The C++ symbols then become undefined at link time and the Release
/// build fails:
///
///     Undefined symbols for architecture arm64:
///       "_stbi_image_free", referenced from:
///           _mtmd_helper_bitmap_init_from_buf in LocalLLMClientLlamaC.o
///       …
///
/// Sprich is text-only — it never invokes `mtmd_helper_bitmap_init_from_buf`
/// or any other multimodal path. So we ship trivially-correct no-op stubs
/// here that satisfy the linker. If a future code path ever does call them,
/// it'll get `nil` back (and the C++ helper already handles `nil` from
/// stbi_load_from_memory as "decode failed").
///
/// The stubs are emitted Release-only — Debug uses the package's own
/// implementations to avoid duplicate-symbol errors.
#if !DEBUG

@_cdecl("stbi_load_from_memory")
func _sprichStub_stbi_load_from_memory(
    _ buffer: UnsafePointer<UInt8>?,
    _ len: UInt64,
    _ x: UnsafeMutablePointer<Int32>?,
    _ y: UnsafeMutablePointer<Int32>?,
    _ comp: UnsafeMutablePointer<Int32>?,
    _ reqComp: Int32
) -> UnsafeMutableRawPointer? {
    return nil
}

@_cdecl("stbi_load")
func _sprichStub_stbi_load(
    _ filename: UnsafePointer<CChar>?,
    _ x: UnsafeMutablePointer<Int32>?,
    _ y: UnsafeMutablePointer<Int32>?,
    _ comp: UnsafeMutablePointer<Int32>?,
    _ reqComp: Int32
) -> UnsafeMutableRawPointer? {
    return nil
}

@_cdecl("stbi_image_free")
func _sprichStub_stbi_image_free(_ buffer: UnsafeMutableRawPointer?) {
    // No-op. Sprich never reaches `mtmd_helper_bitmap_init_from_buf`, so
    // there is nothing allocated to free.
}

#endif
