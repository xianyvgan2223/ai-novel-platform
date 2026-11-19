import 'package:deepseekapp/core/config/user_setting.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「显示缓存命中」设置：默认开启，关掉后要能持久化；老库没有该列时按开启处理。
void main() {
  group('显示缓存命中设置', () {
    test('默认开启', () {
      expect(const UserSetting().showCacheHit, isTrue);
    });

    test('toMap / fromMap 往返，关闭时写 0', () {
      const off = UserSetting(showCacheHit: false);
      expect(off.toMap()['show_cache_hit'], 0);
      expect(UserSetting.fromMap(off.toMap()).showCacheHit, isFalse);

      const on = UserSetting(showCacheHit: true);
      expect(on.toMap()['show_cache_hit'], 1);
      expect(UserSetting.fromMap(on.toMap()).showCacheHit, isTrue);
    });

    test('老库没有 show_cache_hit 列时按开启处理', () {
      // V49 及更早的库里没有这一列；升级后默认展示，不能突然少一块信息。
      expect(UserSetting.fromMap({}).showCacheHit, isTrue);
      expect(
        UserSetting.fromMap({'show_cache_hit': null}).showCacheHit,
        isTrue,
      );
    });

    test('copyWith 只改开关，不影响其他字段', () {
      const s = UserSetting(showCacheHit: true, model: 'deepseek-pro');
      final off = s.copyWith(showCacheHit: false);
      expect(off.showCacheHit, isFalse);
      expect(off.model, 'deepseek-pro');
    });
  });
}
