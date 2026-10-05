import 'package:flutter_test/flutter_test.dart';
import 'package:shooting_app/widgets/link_signal.dart';

void main() {
  test('путь сообщений: P2P > RT > SB', () {
    expect(linkMode(direct: true, live: true), LinkMode.p2p);
    expect(linkMode(direct: false, live: true), LinkMode.rt);
    expect(linkMode(direct: false, live: false), LinkMode.sb);
  });
}
