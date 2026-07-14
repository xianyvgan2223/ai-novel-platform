import 'package:flutter/material.dart';
import 'package:deepseekapp/game/controller/novel_game_controller.dart';
import 'package:deepseekapp/game/model/entity/character_entity.dart';
import 'package:deepseekapp/game/view/page/novel_game_main_page.dart';
import 'package:deepseekapp/game/view/page/copy_detail_page.dart';
import 'package:deepseekapp/game/view/page/character_edit_page.dart';

class NovelRoutes {
  static const String gameMain = '/novel/main';
  static const String copyDetail = '/novel/copy_detail';
  static const String characterEdit = '/novel/character_edit';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case gameMain:
        return MaterialPageRoute(
          builder: (_) => NovelGameMainPage(controller: NovelGameController()),
        );
      case copyDetail:
        final copyId = settings.arguments as int;
        return MaterialPageRoute(
          builder: (_) => CopyDetailPage(copyId: copyId),
        );
      case characterEdit:
        final character = settings.arguments as CharacterEntity;
        return MaterialPageRoute(
          builder: (_) => CharacterEditPage(character: character),
        );
      default:
        return MaterialPageRoute(
          builder: (_) => NovelGameMainPage(controller: NovelGameController()),
        );
    }
  }
}
