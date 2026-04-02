/// Prefix for logging / UI previews without [RangeError] when [s] is shorter than [maxLen].
String safePrefix(String s, int maxLen) {
  if (maxLen <= 0) return '';
  if (s.length <= maxLen) return s;
  return s.substring(0, maxLen);
}
