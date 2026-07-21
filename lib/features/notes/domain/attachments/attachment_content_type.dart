import 'package:forge/features/notes/domain/attachments/attachment_rejection.dart';

/// A content type detected from a file's leading magic bytes.
final class DetectedContentType {
  const DetectedContentType({required this.mime, required this.safeForPreview});

  final String mime;

  /// Whether the type is on the safe in-app preview allowlist (R-NOTE-006).
  /// Types outside the allowlist can still be exported via a confirmed external
  /// open, but are never rendered inline.
  final bool safeForPreview;
}

/// Magic-byte content-type detection and the accepted-type policy for managed
/// attachments (R-NOTE-006).
///
/// Import trusts the *content*, not the file name: the type is sniffed from the
/// leading bytes and, when the caller supplies a declared MIME, the declared
/// value must agree with what the bytes actually are. This defeats a source
/// that lies about its type to slip past a preview allowlist. The policy is a
/// pure function of the bytes so it is exhaustively unit- and property-testable
/// without any IO.
final class AttachmentTypePolicy {
  const AttachmentTypePolicy();

  /// Minimum number of leading bytes the pipeline must present for a confident
  /// decision. Files shorter than this can still be sniffed but only match
  /// signatures that fit within the available bytes.
  static const int sniffLength = 16;

  /// The safe in-app preview allowlist.
  static const Set<String> previewAllowlist = <String>{
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'application/pdf',
  };

  /// All accepted managed-attachment content types.
  static const Set<String> acceptedMimes = <String>{
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'application/pdf',
  };

  /// Detects the content type from [header] (the file's leading bytes), or null
  /// when the bytes match no accepted signature.
  DetectedContentType? detect(List<int> header) {
    if (_matches(header, const <int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ])) {
      return _accepted('image/png');
    }
    if (_matches(header, const <int>[0xff, 0xd8, 0xff])) {
      return _accepted('image/jpeg');
    }
    if (_matches(header, const <int>[0x47, 0x49, 0x46, 0x38])) {
      // "GIF8" — both GIF87a and GIF89a.
      return _accepted('image/gif');
    }
    if (_matches(header, const <int>[0x25, 0x50, 0x44, 0x46, 0x2d])) {
      // "%PDF-"
      return _accepted('application/pdf');
    }
    if (_isWebp(header)) {
      return _accepted('image/webp');
    }
    return null;
  }

  /// Validates [header] against the accepted set and, if [declaredMime] is
  /// non-empty, confirms it agrees with the detected type. Returns the detected
  /// type or throws [AttachmentRejected].
  DetectedContentType validate({
    required List<int> header,
    required String declaredMime,
  }) {
    final DetectedContentType? detected = detect(header);
    if (detected == null) {
      throw const AttachmentRejected(AttachmentRejectionReason.unsupportedType);
    }
    final String declared = declaredMime.trim().toLowerCase();
    if (declared.isNotEmpty && declared != detected.mime) {
      throw AttachmentRejected(
        AttachmentRejectionReason.declaredTypeMismatch,
        'declared=$declared detected=${detected.mime}',
      );
    }
    return detected;
  }

  DetectedContentType _accepted(String mime) => DetectedContentType(
    mime: mime,
    safeForPreview: previewAllowlist.contains(mime),
  );

  bool _matches(List<int> header, List<int> signature) {
    if (header.length < signature.length) {
      return false;
    }
    for (int i = 0; i < signature.length; i += 1) {
      if (header[i] != signature[i]) {
        return false;
      }
    }
    return true;
  }

  bool _isWebp(List<int> header) {
    // "RIFF" .... "WEBP"
    if (header.length < 12) {
      return false;
    }
    const List<int> riff = <int>[0x52, 0x49, 0x46, 0x46];
    const List<int> webp = <int>[0x57, 0x45, 0x42, 0x50];
    for (int i = 0; i < 4; i += 1) {
      if (header[i] != riff[i] || header[8 + i] != webp[i]) {
        return false;
      }
    }
    return true;
  }
}
