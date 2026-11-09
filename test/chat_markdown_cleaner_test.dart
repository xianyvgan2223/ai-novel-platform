import 'package:flutter_test/flutter_test.dart';

import 'package:deepseekapp/features/chat/presentation/markdown_cleaner.dart';

/// 聊天内容展示层清洗：模型输出 Markdown 时，气泡里不再出现明显的原始符号。
///
/// 这里只测「清洗成纯文本」这一层；气泡组件里的接入见
/// `chat_message_rendering_test.dart`。
void main() {
  group('标题 / 引用 / 分隔线', () {
    test('去掉 # 标题前缀，保留文字', () {
      expect(stripMarkdownForChat('# 一级标题\n## 二级标题'), '一级标题\n二级标题');
    });

    test('去掉引用 > 前缀', () {
      expect(stripMarkdownForChat('> 引用第一行\n> 引用第二行'), '引用第一行\n引用第二行');
    });

    test('分隔线整行去掉，不留下多余空行', () {
      expect(stripMarkdownForChat('上面\n\n---\n\n下面'), '上面\n\n下面');
      expect(stripMarkdownForChat('上面\n***\n下面'), '上面\n下面');
    });
  });

  group('强调与行内标记', () {
    test('粗体 / 斜体 / 删除线去掉包裹符号', () {
      expect(stripMarkdownForChat('这是**重点**内容'), '这是重点内容');
      expect(stripMarkdownForChat('这是*斜体*内容'), '这是斜体内容');
      expect(stripMarkdownForChat('这是__粗体__内容'), '这是粗体内容');
      expect(stripMarkdownForChat('这是~~删除~~内容'), '这是删除内容');
    });

    test('行内代码去掉反引号', () {
      expect(
        stripMarkdownForChat('运行 `flutter test` 即可'),
        '运行 flutter test 即可',
      );
    });

    test('单个下划线不处理（避免误伤 snake_case 标识符）', () {
      expect(
        stripMarkdownForChat('变量 snake_case_name 保持原样'),
        '变量 snake_case_name 保持原样',
      );
    });
  });

  group('列表', () {
    test('无序列表统一成 •', () {
      expect(
        stripMarkdownForChat('- 第一\n- 第二\n  * 缩进项'),
        '• 第一\n• 第二\n  • 缩进项',
      );
    });

    test('有序列表保留数字', () {
      expect(stripMarkdownForChat('1. 第一\n2. 第二'), '1. 第一\n2. 第二');
    });
  });

  group('代码块 / 链接 / 表格', () {
    test('代码围栏去掉，代码正文保留', () {
      const input = '先跑这个：\n\n```dart\nfinal a = 1;\n```\n\n完成。';
      expect(stripMarkdownForChat(input), '先跑这个：\n\nfinal a = 1;\n\n完成。');
    });

    test('链接只保留可读文字，图片同理', () {
      expect(
        stripMarkdownForChat('参见[官方文档](https://example.com/doc)'),
        '参见官方文档',
      );
      expect(stripMarkdownForChat('![架构图](https://example.com/a.png)'), '架构图');
      // 文字为空时保留 URL
      expect(
        stripMarkdownForChat('[](https://example.com)'),
        'https://example.com',
      );
    });

    test('简单表格的竖线换成 · 分隔，分隔行丢掉', () {
      const input = '| 名称 | 数量 |\n| --- | --- |\n| 苹果 | 3 |\n| 香蕉 | 5 |';
      expect(stripMarkdownForChat(input), '名称 · 数量\n苹果 · 3\n香蕉 · 5');
    });
  });

  group('整体容错', () {
    test('换行统一为 \\n，多余空行合并，首尾空白去掉', () {
      expect(stripMarkdownForChat('  第一行\r\n\r\n\r\n\r\n第二行  '), '第一行\n\n第二行');
    });

    test('纯文本原样返回', () {
      const plain = '这是一段普通回答，没有任何标记符号。\n第二行也正常。';
      expect(stripMarkdownForChat(plain), plain);
    });

    test('空串原样返回', () {
      expect(stripMarkdownForChat(''), '');
    });

    test('反斜杠转义还原', () {
      expect(stripMarkdownForChat(r'这是 \*不是斜体\*'), '这是 *不是斜体*');
    });
  });
}
