import 'package:aterm_client/domain/models.dart';

const hosts = [
  HostRecord(
    id: 'a',
    name: 'Alpha',
    address: '192.0.2.20',
    protocol: HostProtocol.vnc,
  ),
  HostRecord(id: 'b', name: 'beta', address: '192.0.2.3', isFavorite: true),
  HostRecord(
    id: 'z',
    name: 'Zulu',
    address: '192.0.2.10',
    protocol: HostProtocol.rdp,
  ),
];
