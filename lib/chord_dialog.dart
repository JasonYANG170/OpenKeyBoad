import 'package:material_ui/material_ui.dart';

class ChordDialog extends StatefulWidget {
  const ChordDialog({super.key, required this.catalog});
  final Map<String, int> catalog;
  @override
  State<ChordDialog> createState() => _ChordDialogState();
}

class _ChordDialogState extends State<ChordDialog> {
  final Set<int> modifiers = {};
  String text = 'KC_C';
  String? error;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('组合键'),
    content: SizedBox(
      width: 410,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('选择修饰键，输入一个或多个基础键码。组合将保存到键盘宏槽。'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (var i = 0; i < 8; i++)
                FilterChip(
                  label: Text(
                    [
                      '左 Ctrl',
                      '左 Shift',
                      '左 Alt',
                      '左 Win',
                      '右 Ctrl',
                      '右 Shift',
                      '右 Alt',
                      '右 Win',
                    ][i],
                  ),
                  selected: modifiers.contains(0xe0 + i),
                  onSelected: (value) => setState(() {
                    if (value) {
                      modifiers.add(0xe0 + i);
                    } else {
                      modifiers.remove(0xe0 + i);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextFormField(
            initialValue: text,
            onChanged: (value) => text = value,
            decoration: InputDecoration(
              labelText: '基础键码，空格分隔',
              hintText: 'KC_C 或 KC_A KC_B',
              errorText: error,
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final keys = <int>[];
          for (final token in text.trim().toUpperCase().split(RegExp(r'\s+'))) {
            final code =
                widget.catalog[token] ??
                widget.catalog['KC_$token'] ??
                (token.startsWith('0X')
                    ? int.tryParse(token.substring(2), radix: 16)
                    : null);
            if (code == null || code < 4 || code > 0xe7) {
              setState(() => error = '请输入基础键码，例如 KC_C、KC_F1。');
              return;
            }
            keys.add(code);
          }
          if (modifiers.length + keys.toSet().length > 14) {
            setState(() => error = '最多同时按下 14 个基础键。');
            return;
          }
          Navigator.pop(context, [...modifiers, ...keys]);
        },
        child: const Text('分配到键位'),
      ),
    ],
  );
}
