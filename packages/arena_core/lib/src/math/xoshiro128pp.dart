/// Cross-platform deterministic PRNG (Xoshiro128++ over 32-bit unsigned lanes).
///
/// Uses strictly 32-bit masked additions, XORs, and bit-rotations with zero
/// 64-bit multiplications, guaranteeing bit-for-bit identical sequences across
/// Dart VM (ARM64/x64), dart2wasm, and dart2js (IEEE-754 53-bit integers).
final class Xoshiro128PlusPlus {
  int _s0;
  int _s1;
  int _s2;
  int _s3;

  Xoshiro128PlusPlus.fromState(int s0, int s1, int s2, int s3)
      : _s0 = s0 & 0xFFFFFFFF,
        _s1 = s1 & 0xFFFFFFFF,
        _s2 = s2 & 0xFFFFFFFF,
        _s3 = s3 & 0xFFFFFFFF {
    if ((_s0 | _s1 | _s2 | _s3) == 0) {
      _s0 = 0x9E3779B9;
      _s1 = 0x243F6A88;
      _s2 = 0x85A308D3;
      _s3 = 0x13198A2E;
    }
  }

  /// Seeds deterministically from two 32-bit integers (or a 64-bit seed split into hi/lo).
  factory Xoshiro128PlusPlus.fromSeed(int seedLo, [int seedHi = 0x6A09E667]) {
    int state = (seedLo ^ 0x9E3779B9) & 0xFFFFFFFF;
    int mix() {
      state = (state + 0x9E3779B9) & 0xFFFFFFFF;
      int z = state ^ (state >>> 16);
      z = _imul32(z, 0x85EBCA6B);
      z = (z ^ (z >>> 13)) & 0xFFFFFFFF;
      z = _imul32(z, 0xC2B2AE35);
      return (z ^ (z >>> 16)) & 0xFFFFFFFF;
    }

    final int a = mix();
    state = (state ^ (seedHi & 0xFFFFFFFF)) & 0xFFFFFFFF;
    final int b = mix();
    final int c = mix();
    final int d = mix();
    return Xoshiro128PlusPlus.fromState(a, b, c, d);
  }

  /// Seeds deterministically from an arbitrary string (e.g. `"HLS-DAILY-2026-11-11"`).
  factory Xoshiro128PlusPlus.fromString(String key) {
    final int lo = fnv1a32(key.codeUnits, 0x811C9DC5);
    final int hi = fnv1a32(key.codeUnits.reversed, 0x01000193 ^ lo);
    return Xoshiro128PlusPlus.fromSeed(lo, hi);
  }

  Xoshiro128PlusPlus clone() =>
      Xoshiro128PlusPlus.fromState(_s0, _s1, _s2, _s3);

  /// Generates the next unsigned 32-bit integer in `[0, 0xFFFFFFFF]`.
  int nextUint32() {
    final int sum = (_s0 + _s3) & 0xFFFFFFFF;
    final int result = (_rotl32(sum, 7) + _s0) & 0xFFFFFFFF;

    final int t = (_s1 << 9) & 0xFFFFFFFF;

    _s2 = (_s2 ^ _s0) & 0xFFFFFFFF;
    _s3 = (_s3 ^ _s1) & 0xFFFFFFFF;
    _s1 = (_s1 ^ _s2) & 0xFFFFFFFF;
    _s0 = (_s0 ^ _s3) & 0xFFFFFFFF;

    _s2 = (_s2 ^ t) & 0xFFFFFFFF;
    _s3 = _rotl32(_s3, 11);

    return result;
  }

  /// Generates a uniform integer in `[0, max)` using rejection sampling.
  int nextInt(int max) {
    if (max <= 0) {
      throw ArgumentError.value(max, 'max', 'Must be positive');
    }
    if ((max & (max - 1)) == 0) {
      return nextUint32() & (max - 1);
    }
    final int threshold = (0x100000000 - max) % max;
    while (true) {
      final int r = nextUint32();
      if (r >= threshold) {
        return r % max;
      }
    }
  }

  /// Generates a uniform integer in `[minInclusive, maxExclusive)`.
  int nextRange(int minInclusive, int maxExclusive) =>
      minInclusive + nextInt(maxExclusive - minInclusive);

  /// Generates a double in `[0.0, 1.0)`.
  double nextDouble() => nextUint32() / 4294967296.0;

  /// Returns `true` with probability [probability] in `[0.0, 1.0]`.
  bool nextBool([double probability = 0.5]) => nextDouble() < probability;

  /// Deterministically shuffles [list] in place (Fisher-Yates).
  void shuffle<T>(List<T> list) {
    for (int i = list.length - 1; i > 0; i--) {
      final int j = nextInt(i + 1);
      final T tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
  }

  static int _rotl32(int x, int k) =>
      ((x << k) | ((x & 0xFFFFFFFF) >>> (32 - k))) & 0xFFFFFFFF;

  /// Safe 32-bit unsigned multiplication avoiding >2^53 precision loss in JS.
  static int _imul32(int a, int b) {
    final int ah = (a >>> 16) & 0xFFFF;
    final int al = a & 0xFFFF;
    final int bh = (b >>> 16) & 0xFFFF;
    final int bl = b & 0xFFFF;
    return ((al * bl) + (((ah * bl + al * bh) & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }

  /// Computes deterministic 32-bit FNV-1a hash over a byte/code-unit sequence.
  static int fnv1a32(Iterable<int> bytes, [int basis = 0x811C9DC5]) {
    int hash = basis & 0xFFFFFFFF;
    for (final int byte in bytes) {
      hash = (hash ^ (byte & 0xFF)) & 0xFFFFFFFF;
      hash = _imul32(hash, 0x01000193);
    }
    return hash;
  }
}
