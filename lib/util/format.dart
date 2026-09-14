/// 字节数展示。此前在调试面板、两个查看器里各写了一份，
/// 大小与保留位数还不完全一致，统一在这里。
String formatBytes(num? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)}MB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)}KB';
  return '${bytes}B';
}
