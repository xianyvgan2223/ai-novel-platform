import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:deepseekapp/game/novel_game/model/db/novel_db_helper.dart';
import 'package:deepseekapp/game/novel_game/controller/novel_game_controller.dart';
import 'package:deepseekapp/game/novel_game/view/page/novel_game_main_page.dart';
import 'package:deepseekapp/game/novel_game/novel_global_state.dart';

class NovelGamePage extends StatefulWidget {
  const NovelGamePage({super.key});

  @override
  State<NovelGamePage> createState() => _NovelGamePageState();
}

class _NovelGamePageState extends State<NovelGamePage> {
  final NovelGameController _controller = NovelGameController();
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await NovelDbHelper().database;
      await _controller.loadData();
      // 从数据库读取未读计数
      final unreadCount = _controller.copies
          .where((c) => c.unreadRecord == 1)
          .length;
      NovelGlobalState().setUnreadCount(unreadCount);
      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('小说书架')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('初始化失败: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _error = null;
                    _initialized = false;
                  });
                  _init();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_initialized) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在初始化小说模块...'),
            ],
          ),
        ),
      );
    }

    return NovelGameMainPage(controller: _controller);
  }
}
