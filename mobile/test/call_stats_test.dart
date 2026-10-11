import 'package:flutter_test/flutter_test.dart';
import 'package:lastochka/calls/call_stats.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

StatsReport r(String id, String type, Map<String, dynamic> v) => StatsReport(id, type, 0, {'id': id, 'type': type, ...v});

void main() {
  test('сводка: соединение через TURN, задержка, потери, кодек', () {
    final s = CallStats.summarize([
      r('T1', 'transport', {'selectedCandidatePairId': 'CP1'}),
      r('CP1', 'candidate-pair', {'localCandidateId': 'L1', 'remoteCandidateId': 'R1', 'currentRoundTripTime': 0.085, 'state': 'succeeded'}),
      r('L1', 'local-candidate', {'candidateType': 'relay', 'protocol': 'udp'}),
      r('R1', 'remote-candidate', {'candidateType': 'srflx'}),
      r('IN', 'inbound-rtp', {'kind': 'audio', 'packetsLost': 10, 'packetsReceived': 990, 'jitter': 0.012, 'codecId': 'C1'}),
      r('C1', 'codec', {'mimeType': 'audio/opus'}),
      r('OUT', 'outbound-rtp', {'kind': 'audio', 'packetsSent': 1000}),
    ]);
    expect(s, contains('через сервер TURN (udp)'));
    expect(s, contains('задержка 85 мс'));
    expect(s, contains('потери звука 1.0% (10 из 1000)'));
    expect(s, contains('кодек opus'));
    expect(s, isNot(contains('микрофон')));
  });

  test('сводка: нет звука в обе стороны', () {
    final s = CallStats.summarize([
      r('IN', 'inbound-rtp', {'kind': 'audio', 'packetsLost': 0, 'packetsReceived': 0}),
      r('OUT', 'outbound-rtp', {'kind': 'audio', 'packetsSent': 0}),
    ]);
    expect(s, contains('соединение: не выбрано'));
    expect(s, contains('звук от собеседника не приходил'));
    expect(s, contains('ваш микрофон ничего не передавал'));
  });
}
