import 'package:flutter_test/flutter_test.dart';
import 'package:relayfast/src/update_service.dart';

void main() {
  test('релиз выбирается по префиксу тега и номеру, а не по дате', () {
    final list = [
      {'tag_name': 'windows-3'},
      {'tag_name': 'build-12'},
      {'tag_name': 'build-9'},
      {'tag_name': 'build-20', 'prerelease': true},
      {'tag_name': 'v1.0'},
    ];
    expect(UpdateService.pickRelease(list, 'build-')?['tag_name'], 'build-12');
    expect(UpdateService.pickRelease(list, 'windows-')?['tag_name'], 'windows-3');
    expect(UpdateService.pickRelease(list, 'foo-'), isNull);
  });

  test('номер сборки из тега и ABI по номеру сборки', () {
    expect(UpdateService.buildOfTag('build-7', 'build-'), 7);
    expect(UpdateService.buildOfTag('windows-7', 'build-'), isNull);
    expect(UpdateService.abiFor(2013), 'arm64-v8a');
    expect(UpdateService.abiFor(1013), 'armeabi-v7a');
    expect(UpdateService.abiFor(4013), 'x86_64');
  });

  test('теги из ленты релизов и выбор самого нового', () {
    const atom = '''<feed>
<entry><link rel="alternate" href="https://github.com/o/r/releases/tag/windows-4"/></entry>
<entry><link rel="alternate" href="https://github.com/o/r/releases/tag/build-15"/></entry>
<entry><link rel="alternate" href="https://github.com/o/r/releases/tag/build-9"/></entry>
</feed>''';
    final tags = UpdateService.tagsFromAtom(atom);
    expect(tags, ['windows-4', 'build-15', 'build-9']);
    expect(UpdateService.newestTag(tags, 'build-'), 'build-15');
    expect(UpdateService.newestTag(tags, 'windows-'), 'windows-4');
  });
}
