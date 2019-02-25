part of image_crop;

const _kCropGridColumnCount = 3;
const _kCropGridRowCount = 3;
const _kCropGridColor = const Color.fromRGBO(0xd0, 0xd0, 0xd0, 0.9);
const _kCropOverlayActiveOpacity = 0.3;
const _kCropOverlayInactiveOpacity = 0.7;
const _kCropHandleColor = const Color.fromRGBO(0xd0, 0xd0, 0xd0, 1.0);
const _kCropHandleSize = 10.0;
const _kCropHandleHitSize = 48.0;
const _kCropMinFraction = 0.1;

enum _CropAction { none, moving, cropping, scaling }
enum _CropHandleSide { none, topLeft, topRight, bottomLeft, bottomRight }

class Crop extends StatefulWidget {
  final ImageProvider image;
  final double aspectRatio;
  final double maximumScale;
  final bool alwaysShowGrid;

  const Crop({
    Key key,
    this.image,
    this.aspectRatio,
    this.maximumScale: 2.0,
    this.alwaysShowGrid: false,
  })  : assert(image != null),
        assert(maximumScale != null),
        assert(alwaysShowGrid != null),
        super(key: key);

  Crop.file(
    File file, {
    Key key,
    double scale = 1.0,
    this.aspectRatio,
    this.maximumScale: 2.0,
    this.alwaysShowGrid: false,
  })  : image = FileImage(file, scale: scale),
        assert(maximumScale != null),
        assert(alwaysShowGrid != null),
        super(key: key);

  Crop.asset(
    String assetName, {
    Key key,
    AssetBundle bundle,
    String package,
    this.aspectRatio,
    this.maximumScale: 2.0,
    this.alwaysShowGrid: false,
  })  : image = AssetImage(assetName, bundle: bundle, package: package),
        assert(maximumScale != null),
        assert(alwaysShowGrid != null),
        super(key: key);

  @override
  State<StatefulWidget> createState() => CropState();

  static CropState of(BuildContext context) {
    final state = context.ancestorStateOfType(const TypeMatcher<CropState>());
    return state;
  }
}

class CropState extends State<Crop> with TickerProviderStateMixin, Drag {
  final _surfaceKey = GlobalKey();
  AnimationController _activeController;
  AnimationController _settleController;
  ImageStream _imageStream;
  ui.Image _image;
  double _scale;
  double _ratio;
  Rect _view;
  List<Point> _area;
  Offset _lastFocalPoint;
  _CropAction _action;
  _CropHandleSide _handle;
  double _startScale;
  Rect _startView;
  Tween<Rect> _viewTween;
  Tween<double> _scaleTween;

  double get scale => 1.0; //_area.shortestSide / _scale;//TODO

  List<Point> get area {
    return _view.isEmpty ? null : List.from(_area);
  }

  bool get _isEnabled => !_view.isEmpty && _image != null;
  var _zero = [
    Point(0.0, 0.0),
    Point(0.0, 0.0),
    Point(0.0, 0.0),
    Point(0.0, 0.0),
  ];

  @override
  void initState() {
    super.initState();

    _area = List.from(_zero);
    _view = Rect.zero;
    _scale = 1.0;
    _ratio = 1.0;
    _lastFocalPoint = Offset.zero;
    _action = _CropAction.none;
    _handle = _CropHandleSide.none;
    _activeController = AnimationController(
      vsync: this,
      value: widget.alwaysShowGrid ? 1.0 : 0.0,
    )..addListener(() => setState(() {}));
    _settleController = AnimationController(vsync: this)..addListener(_settleAnimationChanged);
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_updateImage);
    _activeController.dispose();
    _settleController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _getImage();
  }

  @override
  void didUpdateWidget(Crop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _getImage();
    } else if (widget.aspectRatio != oldWidget.aspectRatio) {
      _area = _calculateDefaultArea(
        viewWidth: _view.width,
        viewHeight: _view.height,
        imageWidth: _image?.width,
        imageHeight: _image?.height,
      );
    }
    if (widget.alwaysShowGrid != oldWidget.alwaysShowGrid) {
      if (widget.alwaysShowGrid) {
        _activate();
      } else {
        _deactivate();
      }
    }
  }

  void _getImage({bool force: false}) {
    final oldImageStream = _imageStream;
    _imageStream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_imageStream.key != oldImageStream?.key || force) {
      oldImageStream?.removeListener(_updateImage);
      _imageStream.addListener(_updateImage);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints.expand(),
      child: GestureDetector(
        key: _surfaceKey,
        behavior: HitTestBehavior.opaque,
        onScaleStart: _isEnabled ? _handleScaleStart : null,
        onScaleUpdate: _isEnabled ? _handleScaleUpdate : null,
        onScaleEnd: _isEnabled ? _handleScaleEnd : null,
        child: CustomPaint(
          painter: _CropPainter(
            image: _image,
            ratio: _ratio,
            view: _view,
            area: _area,
            scale: _scale,
            active: _activeController.value,
          ),
        ),
      ),
    );
  }

  void _activate() {
    _activeController.animateTo(
      1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 250),
    );
  }

  void _deactivate() {
    if (!widget.alwaysShowGrid) {
      _activeController.animateTo(
        0.0,
        curve: Curves.fastOutSlowIn,
        duration: const Duration(milliseconds: 250),
      );
    }
  }

  Size get _boundaries => _surfaceKey.currentContext.size - Offset(_kCropHandleSize, _kCropHandleSize);

  Offset _getLocalPoint(Offset point) {
    final RenderBox box = _surfaceKey.currentContext.findRenderObject();
    return box.globalToLocal(point);
  }

  void _settleAnimationChanged() {
    setState(() {
      _scale = _scaleTween.transform(_settleController.value);
      _view = _viewTween.transform(_settleController.value);
    });
  }

  List<Point> _calculateDefaultArea({
    int imageWidth,
    int imageHeight,
    double viewWidth,
    double viewHeight,
  }) {
    if (imageWidth == null || imageHeight == null) {
      return List.from(_zero);
    }
    final width = 1.0;
    final height = (imageWidth * viewWidth * width) / (imageHeight * viewHeight * (widget.aspectRatio ?? 1.0));
    return [Point(0.0, 0.0), Point(100.0, 0.0), Point(100.0, 300.0), Point(0.0, 350.0)];
//    return Rect.fromLTWH((1.0 - width) / 2, (1.0 - height) / 2, width, height);
  }

  void _updateImage(ImageInfo imageInfo, bool synchronousCall) {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        _image = imageInfo.image;
        _scale = imageInfo.scale;
        _ratio = max(
          _boundaries.width / _image.width,
          _boundaries.height / _image.height,
        );

        final viewWidth = _boundaries.width / (_image.width * _scale * _ratio);
        final viewHeight = _boundaries.height / (_image.height * _scale * _ratio);
        _area = _calculateDefaultArea(
          viewWidth: viewWidth,
          viewHeight: viewHeight,
          imageWidth: _image.width,
          imageHeight: _image.height,
        );
        _view = Rect.fromLTWH(
//          (1.0 - viewWidth) / 2 + _area.left,
          (1.0 - viewWidth) / 2 + _area[0].x,
//          (1.0 - viewHeight) / 2 + _area.top,
          (1.0 - viewHeight) / 2 + _area[0].y,
          viewWidth,
          viewHeight,
        );
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  _CropHandleSide _hitCropHandle(Offset localPoint) {
    final boundaries = _boundaries;
//    final viewRect =
//    Rect.fromLTWH(
//      _boundaries.width * _area.left,
//      boundaries.height * _area.top,
//      boundaries.width * _area.width,
//      boundaries.height * _area.height,
//    ).deflate(_kCropHandleSize / 2);

    if (Rect.fromLTWH(
      area[0].x - _kCropHandleHitSize / 2,
      area[0].y - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topLeft;
    }

    if (Rect.fromLTWH(
      area[1].x - _kCropHandleHitSize / 2,
      area[1].y - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.topRight;
    }

    if (Rect.fromLTWH(
      area[3].x - _kCropHandleHitSize / 2,
      area[3].y - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomLeft;
    }

    if (Rect.fromLTWH(
      area[2].x - _kCropHandleHitSize / 2,
      area[2].y - _kCropHandleHitSize / 2,
      _kCropHandleHitSize,
      _kCropHandleHitSize,
    ).contains(localPoint)) {
      return _CropHandleSide.bottomRight;
    }

    return _CropHandleSide.none;
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _activate();
    _settleController.stop(canceled: false);
    _lastFocalPoint = details.focalPoint;
    _action = _CropAction.none;
    _handle = _hitCropHandle(_getLocalPoint(details.focalPoint));
    _startScale = _scale;
    _startView = _view;
  }

  Rect _getViewInBoundaries(double scale) {
    double left = _view.left;
    double top = _view.top;

//    if (left < 0.0) {
//      left = 0.0;
//    } else if (left > 1.0 - _view.width * _area.width / scale) {
//      left = 1.0 - _view.width * _area.width / scale;
//    }
//
//    if (top < 0.0) {
//      top = 0.0;
//    } else if (top > 1.0 - _view.height * _area.height / scale) {
//      top = 1.0 - _view.height * _area.height / scale;
//    }

    return Offset(left, top) & _view.size;
  }

  double get _maximumScale => widget.maximumScale;

  double get _minimumScale {
//    final scaleX = _boundaries.width * _area.width / (_image.width * _ratio);
//    final scaleY = _boundaries.height * _area.height / (_image.height * _ratio);
//    return min(_maximumScale, max(scaleX, scaleY));
    return 1;
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _deactivate();

    final targetScale = _scale.clamp(_minimumScale, _maximumScale);
    _scaleTween = Tween<double>(
      begin: _scale,
      end: targetScale,
    );

    _startView = _view;
    _viewTween = RectTween(
      begin: _view,
      end: _getViewInBoundaries(targetScale),
    );

    _settleController.value = 0.0;
    _settleController.animateTo(
      1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 350),
    );
  }

  void _updateArea({Point lt, Point rt, Point rb, Point lb}) {
    var areaTL = _area[0] + (lt ?? Point(0.0, 0.0));
    var areaTR = _area[1] + (rt ?? Point(0.0, 0.0));
    var areaBR = _area[2] + (rb ?? Point(0.0, 0.0));
    var areaBL = _area[3] + (lb ?? Point(0.0, 0.0));

    // ensure minimum rectangle
    var minWidth = _kCropMinFraction * _boundaries.width;

    if (areaTR.x - areaTL.x < minWidth) {
      if (lt == null) {
        //tr is moving
        areaTR = Point(areaTL.x + minWidth, areaTR.y);
      } else {
        areaTL = Point(areaTR.x - minWidth, areaTL.y);
      }
    }

    if (areaBR.x - areaBL.x < minWidth) {
      if (lb == null) {
        //tr is moving
        areaBR = Point(areaBL.x + minWidth, areaBR.y);
      } else {
        areaBL = Point(areaBR.x - minWidth, areaBL.y);
      }
    }

    var minHeight = _kCropMinFraction * _boundaries.height;
    if (areaBL.y - areaTL.y < minHeight) {
      if (lt == null) {
        areaBL = Point(areaBL.x, areaTL.y + minHeight);
      } else {
        areaTL = Point(areaTL.x, areaBL.y - minHeight);
      }
    }
    if (areaBR.y - areaTR.y < minHeight) {
      if (rt == null) {
        areaBR = Point(areaBR.x, areaTR.y + minHeight);
      } else {
        areaTR = Point(areaTR.x, areaBR.y - minHeight);
      }
    }

    //TODO add convex check
//    // adjust to aspect ratio if needed
//    if (widget.aspectRatio != null && widget.aspectRatio > 0.0) {
//      final width = areaBR - areaTL;
//      final height = (_image.width * _view.width * width) / (_image.height * _view.height * widget.aspectRatio);
//
//      if (rt != null) {
//        areaTR = areaBL - height;
//        if (areaTR < 0.0) {
//          areaTR = 0.0;
//          areaBL = height;
//        }
//      } else {
//        areaBL = areaTR + height;
//        if (areaBL > 1.0) {
//          areaTR = 1.0 - height;
//          areaBL = 1.0;
//        }
//      }
//    }
//
//    // ensure to remain within bounds of the view
//    if (areaTL < 0.0) {
//      areaTL = 0.0;
//      areaBR = _area.width;
//    } else if (areaBR > 1.0) {
//      areaTL = 1.0 - _area.width;
//      areaBR = 1.0;
//    }
//
//    if (areaTL.y < 0.0) {
//      areaTL = Point(areaTL.x, 0);
//    }
//    if (areaTR.y < 0.0) {
//      areaTR = Point(areaTR.x, 0);
//    }
//    if (areaBL.y > 1.0) {
//      areaBL = Point(areaBL.x, 1);
//    }
//    if()
//      areaTR = Point(areaTR.x, 0);
////      areaBottom = _area.height;
//    } else if (areaBottom > 1.0) {
//      areaTop = 1.0 - _area.height;
//      areaBottom = 1.0;
//    }

    setState(() {
      _area = [areaTL, areaTR, areaBR, areaBL];
    });
  }

  void _handleScaleUpdate(ScaleUpdateDetails details) {
    if (_action == _CropAction.none) {
      if (_handle == _CropHandleSide.none) {
        _action = details.rotation == 0.0 && details.scale == 1.0 ? _CropAction.moving : _CropAction.scaling;
      } else {
        _action = _CropAction.cropping;
      }
    }

    if (_action == _CropAction.cropping) {
      final delta = details.focalPoint - _lastFocalPoint;
      _lastFocalPoint = details.focalPoint;

      final dx = delta.dx / _boundaries.width;
      final dy = delta.dy / _boundaries.height;

      var point = Point(delta.dx, delta.dy);
      if (_handle == _CropHandleSide.topLeft) {
        _updateArea(lt: point);
      } else if (_handle == _CropHandleSide.topRight) {
        _updateArea(rt: point);
      } else if (_handle == _CropHandleSide.bottomLeft) {
        _updateArea(lb: point);
      } else if (_handle == _CropHandleSide.bottomRight) {
        _updateArea(rb: point);
      }
    } else if (_action == _CropAction.moving) {
      final delta = _lastFocalPoint - details.focalPoint;
      _lastFocalPoint = details.focalPoint;

      setState(() {
        _view = _view.translate(
          delta.dx / (_image.width * _scale * _ratio),
          delta.dy / (_image.height * _scale * _ratio),
        );
      });
    } else if (_action == _CropAction.scaling) {
      setState(() {
        _scale = _startScale * details.scale;

        final dx = _boundaries.width * (1.0 - details.scale) / (_image.width * _scale * _ratio);
        final dy = _boundaries.height * (1.0 - details.scale) / (_image.height * _scale * _ratio);

        _view = Rect.fromLTWH(
          _startView.left - dx / 2,
          _startView.top - dy / 2,
          _startView.width,
          _startView.height,
        );
      });
    }
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect view;
  final double ratio;
  final List<Point> area;
  final double scale;
  final double active;

  _CropPainter({
    this.image,
    this.view,
    this.ratio,
    this.area,
    this.scale,
    this.active,
  });

  @override
  bool shouldRepaint(_CropPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.view != view ||
        oldDelegate.ratio != ratio ||
        oldDelegate.area != area ||
        oldDelegate.active != active ||
        oldDelegate.scale != scale;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      _kCropHandleSize / 2,
      _kCropHandleSize / 2,
      size.width - _kCropHandleSize,
      size.height - _kCropHandleSize,
    );

    canvas.save();
    canvas.translate(rect.left, rect.top);

    final paint = Paint()..isAntiAlias = false;

    if (image != null) {
      final src = Rect.fromLTWH(
        0.0,
        0.0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final dst = Rect.fromLTWH(
        0.0,
        0.0,
        image.width * scale * ratio,
        image.height * scale * ratio,
      );

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0.0, 0.0, rect.width, rect.height));
      canvas.drawImageRect(image, src, dst, paint);
      canvas.restore();
    }

    paint.color = Color.fromRGBO(
        0x0, 0x0, 0x0, _kCropOverlayActiveOpacity * active + _kCropOverlayInactiveOpacity * (1.0 - active));
    final boundaries = area;
//    Rect.fromLTWH(
//      rect.width * area.left,
//      rect.height * area.top,
//      rect.width * area.width,
//      rect.height * area.height,
//    );
    final List<Point> cropArea = area;
//    [
//      Point(rect.width * area.left, rect.height * area.top),
//      Point(rect.width * area.left + rect.width * area.width, rect.height * area.top),
//      Point(rect.width * area.left + rect.width * area.width, rect.height * area.top + rect.height * area.height),
//      Point(rect.width * area.left, rect.height * area.top + rect.height * area.height),
//    ];

    Path outArea = new Path();
    outArea.addPolygon([
      Offset(0, 0),
      Offset(0, (image?.height?.toDouble() ?? 0) * scale * ratio),
      Offset(cropArea[3].x, cropArea[3].y),
      Offset(cropArea[0].x, cropArea[0].y),
    ], true);

    outArea.addPolygon([
      Offset(0, 0),
      Offset((image?.width?.toDouble() ?? 0) * scale * ratio, 0),
      Offset(cropArea[1].x, cropArea[1].y),
      Offset(cropArea[0].x, cropArea[0].y),
    ], true);

    outArea.addPolygon([
      Offset(cropArea[1].x, cropArea[1].y),
      Offset((image?.width?.toDouble() ?? 0) * scale * ratio, 0),
      Offset((image?.width?.toDouble() ?? 0) * scale * ratio, (image?.height?.toDouble() ?? 0) * scale * ratio),
      Offset(cropArea[2].x, cropArea[2].y),
    ], true);

    outArea.addPolygon([
      Offset(cropArea[3].x, cropArea[3].y),
      Offset(cropArea[2].x, cropArea[2].y),
      Offset((image?.width?.toDouble() ?? 0) * scale * ratio, (image?.height?.toDouble() ?? 0) * scale * ratio),
      Offset(0, (image?.height?.toDouble() ?? 0) * scale * ratio),
    ], true);

    paint.style = PaintingStyle.fill;
    canvas.drawPath(outArea, paint);

//    paint.style = PaintingStyle.stroke;
//    paint.strokeWidth = 10.0;
//    paint.strokeJoin = StrokeJoin.round;
//    paint.color = Color.fromRGBO(150, 150, 150, 1.0);
//    canvas.drawPath(outArea, paint);

//    paint
////      ..color = Colors.black
////      ..style = PaintingStyle.stroke
//      ..strokeWidth = 10.0;
//    paint.style = PaintingStyle.fill;
//    paint.strokeJoin = StrokeJoin.round;

//    //Shadow out of boundaries
//    canvas.drawPoints(
//        ui.PointMode.polygon,
//        [
//          Offset(topLeft.x, topLeft.y),
//          Offset(topRight.x, topRight.y),
//          Offset(bottomRight.x, bottomRight.y),
//          Offset(bottomLeft.x, bottomLeft.y),
//          Offset(topLeft.x, topLeft.y),
//        ],
//        paint);
//    canvas.drawLine(Offset(topLeft.x, topLeft.y), Offset(topRight.x, topRight.y), paint);
//    canvas.drawRect(Rect.fromLTRB(0.0, boundaries.bottom, rect.width, rect.height), paint);
//    canvas.drawRect(Rect.fromLTRB(0.0, boundaries.top, boundaries.left, boundaries.bottom), paint);
//    canvas.drawRect(Rect.fromLTRB(boundaries.right, boundaries.top, rect.width, boundaries.bottom), paint);

    if (boundaries.isNotEmpty == true) {
      _drawGrid(canvas, cropArea);
      _drawHandles(canvas, cropArea);
    }

    canvas.restore();
  }

  void _drawHandles(Canvas canvas, List<Point> cropArea) {
    final paint = Paint()
      ..isAntiAlias = true
      ..color = _kCropHandleColor;

    canvas.drawOval(
      Rect.fromLTWH(
        cropArea[0].x - _kCropHandleSize / 2,
        cropArea[0].y - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

//Draw oval pointers to corners
    canvas.drawOval(
      Rect.fromLTWH(
        cropArea[1].x - _kCropHandleSize / 2,
        cropArea[1].y - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        cropArea[2].x - _kCropHandleSize / 2,
        cropArea[2].y - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );

    canvas.drawOval(
      Rect.fromLTWH(
        cropArea[3].x - _kCropHandleSize / 2,
        cropArea[3].y - _kCropHandleSize / 2,
        _kCropHandleSize,
        _kCropHandleSize,
      ),
      paint,
    );
  }

  void _drawGrid(Canvas canvas, List<Point> boundaries) {
    if (active == 0.0) return;

    final paint = Paint()
      ..isAntiAlias = false
      ..color = _kCropGridColor.withOpacity(_kCropGridColor.opacity * active)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final path = Path()
      ..moveTo(boundaries[0].x, boundaries[0].y)
      ..lineTo(boundaries[1].x, boundaries[1].y)
      ..lineTo(boundaries[2].x - 1, boundaries[2].y - 1)
      ..lineTo(boundaries[3].x, boundaries[3].y - 1)
      ..lineTo(boundaries[0].x, boundaries[0].y);

//    for (var column = 1; column < _kCropGridColumnCount; column++) {
//      path
//        ..moveTo(boundaries.left + column * boundaries.width / _kCropGridColumnCount, boundaries.top)
//        ..lineTo(boundaries.left + column * boundaries.width / _kCropGridColumnCount, boundaries.bottom - 1);
//    }
//
//    for (var row = 1; row < _kCropGridRowCount; row++) {
//      path
//        ..moveTo(boundaries.left, boundaries.top + row * boundaries.height / _kCropGridRowCount)
//        ..lineTo(boundaries.right - 1, boundaries.top + row * boundaries.height / _kCropGridRowCount);
//    }

    canvas.drawPath(path, paint);
  }
}
