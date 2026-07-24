/// Formats a byte count with binary unit thresholds for storage displays.
///
/// Unit labels retain the existing product vocabulary (KB/MB/GB), while each
/// threshold is a power of 1024.
String formatBytes(int sizeInBytes) {
  const kibibyte = 1024;
  const mebibyte = kibibyte * 1024;
  const gibibyte = mebibyte * 1024;

  if (sizeInBytes < kibibyte) return '$sizeInBytes B';
  if (sizeInBytes < mebibyte) {
    return '${(sizeInBytes / kibibyte).toStringAsFixed(1)} KB';
  }
  if (sizeInBytes < gibibyte) {
    return '${(sizeInBytes / mebibyte).toStringAsFixed(1)} MB';
  }
  return '${(sizeInBytes / gibibyte).toStringAsFixed(2)} GB';
}
