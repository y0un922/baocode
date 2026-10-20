import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../composer/composer_files.dart' show splitCodeAppendix;

/// The user's messages down the conversation's right edge, a dash each (as
/// ChatGPT's table of contents): the one being read brighter. With the
/// pointer over the dashes, a list of the messages beside them; a click on
/// a dash or a line scrolls to its message.
///
/// Light however long the conversation: the dashes are painted (more than
/// fit, an even sample of them, each place standing for the messages
/// there), and only the lines of the list in sight are built.
class ChatMessageRail extends StatefulWidget {
  const ChatMessageRail({
    super.key,
    required this.rows,
    required this.labelAt,
    required this.current,
    required this.moved,
    required this.scrolling,
    required this.onPick,
    this.onPointerDown,
    this.onPointerSignal,
    this.onPointerPanZoomStart,
    this.onPointerPanZoomUpdate,
    this.onPointerPanZoomEnd,
  });

  /// Each message's row in the history, in order.
  final List<int> rows;

  /// What the list shows of the message at [row]: its first line.
  final String Function(int row) labelAt;

  /// The row at the middle of the view, as laid out (the one being read);
  /// null when none is.
  final int? Function() current;

  /// Notifies when the view may have moved: a scroll, a new layout.
  final Listenable moved;

  /// Whether the user is scrolling the history: a message picked stays the
  /// one shown as read until they do.
  final bool Function() scrolling;

  /// Scrolls to the message at [row].
  final ValueChanged<int> onPick;

  /// The history's own, for a press, the wheel or a trackpad over it: it is
  /// not over the list.
  final PointerDownEventListener? onPointerDown;
  final PointerSignalEventListener? onPointerSignal;
  final PointerPanZoomStartEventListener? onPointerPanZoomStart;
  final PointerPanZoomUpdateEventListener? onPointerPanZoomUpdate;
  final PointerPanZoomEndEventListener? onPointerPanZoomEnd;

  /// Fewer messages than this, and there is nothing to find among them.
  static const minMessages = 2;

  /// How wide it is, the dashes in its middle.
  static const width = 24.0;

  /// [text]'s first line, as the list shows it; empty with none.
  static String labelOf(String text) {
    final line = splitCodeAppendix(text).body
        .split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    // A heading's or a quote's marks are not what it says.
    final label = line.replaceFirst(RegExp(r'^[#>*+\-\s]+'), '');
    return label.characters.take(120).toString();
  }

  @override
  State<ChatMessageRail> createState() => _ChatMessageRailState();
}

class _ChatMessageRailState extends State<ChatMessageRail> {
  /// A line of the list.
  static const _lineHeight = 26.0;
  static const _listWidth = 300.0;
  static const _listPadding = 5.0;

  /// After the pointer leaves, before the list closes.
  static const _closeDelay = Duration(milliseconds: 250);

  bool _open = false;
  Timer? _closing;
  ScrollController? _list;

  /// The message read (where in [ChatMessageRail.rows]), as last laid out.
  int? _read;

  /// The one last picked: shown as read until the user scrolls.
  int? _picked;

  /// The message under the pointer, on a dash or a line: its dash brighter.
  int? _hovered;

  bool _readScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.moved.addListener(_moved);
    _scheduleRead();
  }

  @override
  void didUpdateWidget(ChatMessageRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.moved, widget.moved)) {
      oldWidget.moved.removeListener(_moved);
      widget.moved.addListener(_moved);
    }
    final count = widget.rows.length;
    if ((_picked ?? 0) >= count) _picked = null;
    if ((_hovered ?? 0) >= count) _hovered = null;
    _scheduleRead();
  }

  @override
  void dispose() {
    widget.moved.removeListener(_moved);
    _closing?.cancel();
    _list?.dispose();
    super.dispose();
  }

  void _moved() {
    if (_picked != null && widget.scrolling()) _picked = null;
    _scheduleRead();
  }

  /// Reads which message is being read once the list has laid out where
  /// it has moved to (each move brings a frame of its own).
  void _scheduleRead() {
    if (_readScheduled) return;
    _readScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _readScheduled = false;
      if (!mounted) return;
      final read = _messageAt(widget.current());
      if (read != _read) setState(() => _read = read);
    });
  }

  /// The last message at or above [row].
  int? _messageAt(int? row) {
    if (row == null) return null;
    final rows = widget.rows;
    var (low, high) = (0, rows.length);
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (rows[middle] <= row) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? null : low - 1;
  }

  int? get _shownRead => _picked ?? _read;

  void _show() {
    _closing?.cancel();
    if (_open) return;
    // The one read in the middle of a long list.
    final read = _shownRead ?? 0;
    _list?.dispose();
    _list = ScrollController(
      initialScrollOffset: math.max(0, (read - 4) * _lineHeight),
    );
    setState(() => _open = true);
  }

  void _hide() {
    _closing?.cancel();
    _closing = Timer(_closeDelay, () {
      if (mounted) {
        setState(() {
          _open = false;
          _hovered = null;
        });
      }
    });
  }

  void _pick(int place) {
    setState(() => _picked = place);
    widget.onPick(widget.rows[place]);
  }

  void _hover(int? place) {
    if (place != _hovered) setState(() => _hovered = place);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final most = math.max(120.0, constraints.maxHeight / 2);
        return Align(
          alignment: Alignment.centerRight,
          child: Listener(
            onPointerDown: widget.onPointerDown,
            onPointerSignal: widget.onPointerSignal,
            child: MouseRegion(
              onEnter: (_) => _show(),
              onExit: (_) => _hide(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_open) ...[_buildList(most), const SizedBox(width: 4)],
                  _buildDashes(most),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDashes(double most) {
    final geometry = _DashGeometry(widget.rows.length, most);
    int place(Offset at) => geometry.placeAt(at.dy);
    return Listener(
      onPointerPanZoomStart: widget.onPointerPanZoomStart,
      onPointerPanZoomUpdate: widget.onPointerPanZoomUpdate,
      onPointerPanZoomEnd: widget.onPointerPanZoomEnd,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onHover: (event) => _hover(place(event.localPosition)),
        onExit: (_) => _hover(null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) => _pick(place(details.localPosition)),
          child: CustomPaint(
            size: Size(ChatMessageRail.width, geometry.height),
            painter: _DashPainter(
              geometry,
              read: _shownRead,
              hot: _hovered ?? _shownRead,
              color: AppColors.textMuted.withValues(alpha: .45),
              hotColor: AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// The messages, numbered, the one read marked: only the lines in sight
  /// built.
  Widget _buildList(double most) {
    final count = widget.rows.length;
    final read = _shownRead;
    return Container(
      width: _listWidth,
      height: math.min(most, count * _lineHeight + 2 * _listPadding),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.partBorder),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(color: themeColors['widget.shadow'], blurRadius: 16),
        ],
      ),
      child: ListView.builder(
        controller: _list,
        padding: const EdgeInsets.all(_listPadding),
        itemExtent: _lineHeight,
        itemCount: count,
        itemBuilder: (context, place) => _buildLine(place, read: place == read),
      ),
    );
  }

  Widget _buildLine(int place, {required bool read}) {
    final hovered = place == _hovered;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => _hover(place),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _pick(place),
        child: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: read || hovered
                ? AppColors.textPrimary.withValues(alpha: read ? .12 : .07)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${place + 1}. ${widget.labelAt(widget.rows[place])}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textPrimary, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

/// Where each of [count] messages' dash is, in at most [most]: a slot each,
/// as far apart as there is room for. More than fit, the rail is [most]
/// tall and each place in it stands for the messages there.
class _DashGeometry {
  _DashGeometry(this.count, double most)
    : slot = math.min(_dash + _maxGap, most / count),
      height = math.min(count * (_dash + _maxGap), most);

  static const _dash = 2.0;
  static const _maxGap = 8.0;

  /// Below this a slot each, the dashes would run together: some are left
  /// out.
  static const _leastSlot = 3.0;

  final int count;
  final double slot;
  final double height;

  bool get sampled => slot < _leastSlot;

  /// The middle of message [place]'s dash.
  double at(int place) => (place + .5) / count * height;

  /// The message at [y].
  int placeAt(double y) => (y / height * count).floor().clamp(0, count - 1);
}

class _DashPainter extends CustomPainter {
  _DashPainter(
    this.geometry, {
    required this.read,
    required this.hot,
    required this.color,
    required this.hotColor,
  });

  final _DashGeometry geometry;
  final int? read;
  final int? hot;
  final Color color;
  final Color hotColor;

  static const _width = 14.0;

  void _dash(Canvas canvas, Size size, double y, Color color, double width) {
    final height = math.min(_DashGeometry._dash, math.max(1.0, geometry.slot));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width / 2, y),
          width: width,
          height: height,
        ),
        const Radius.circular(1),
      ),
      Paint()..color = color,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (geometry.sampled) {
      for (var y = 1.5; y < geometry.height; y += _DashGeometry._leastSlot) {
        _dash(canvas, size, y, color, _width);
      }
    } else {
      for (var place = 0; place < geometry.count; place++) {
        if (place != read && place != hot) {
          _dash(canvas, size, geometry.at(place), color, _width);
        }
      }
    }
    for (final place in {?read, ?hot}) {
      _dash(
        canvas,
        size,
        geometry.at(place),
        place == hot ? hotColor : color,
        place == read ? _width * 1.35 : _width,
      );
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) =>
      old.geometry.count != geometry.count ||
      old.geometry.height != geometry.height ||
      old.read != read ||
      old.hot != hot ||
      old.color != color ||
      old.hotColor != hotColor;
}
