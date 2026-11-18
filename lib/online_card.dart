import 'package:material_ui/material_ui.dart';

/// Fixed-size overview; optional settings replace the body inside the same
/// bounds, so opening a card never creates a tall column of empty neighbours.
class OnlineCard extends StatefulWidget {
  const OnlineCard({
    super.key,
    required this.title,
    required this.child,
    this.details,
  });
  final String title;
  final Widget child;
  final Widget? details;
  @override
  State<OnlineCard> createState() => _OnlineCardState();
}

class _OnlineCardState extends State<OnlineCard> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('online-card-${widget.title}'),
    width: 310,
    height:
        280 +
        (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0, 64) * 16,
    child: Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height:
                  44 +
                  (MediaQuery.textScalerOf(context).scale(17) - 17).clamp(
                    0,
                    64,
                  ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (widget.details != null)
                    IconButton(
                      key: ValueKey('online-detail-${widget.title}'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      tooltip: '${widget.title}${expanded ? "收起" : "设置"}',
                      onPressed: () => setState(() => expanded = !expanded),
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.tune,
                        size: 20,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: expanded && widget.details != null
                  ? SingleChildScrollView(child: widget.details!)
                  : widget.child,
            ),
          ],
        ),
      ),
    ),
  );
}
