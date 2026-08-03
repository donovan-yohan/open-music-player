class StemChannel {
  const StemChannel({
    required this.id,
    required this.label,
    required this.gain,
    required this.muted,
  });

  final String id;
  final String label;
  final double gain;
  final bool muted;
}

/// Narrow adapter for the future stems5-v1 contract.
abstract class StemChannelSource {
  bool get isAvailable;
  bool get isPending;
  List<StemChannel> get channels;
  Future<void> setGain(String id, double gain);
  Future<void> setMute(String id, bool muted);
}

class UnavailableStemChannelSource implements StemChannelSource {
  const UnavailableStemChannelSource({this.isPending = false});

  @override
  final bool isPending;
  @override
  bool get isAvailable => false;
  @override
  List<StemChannel> get channels => const [];
  @override
  Future<void> setGain(String id, double gain) async {}
  @override
  Future<void> setMute(String id, bool muted) async {}
}
