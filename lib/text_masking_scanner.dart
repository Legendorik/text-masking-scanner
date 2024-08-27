import 'dart:developer';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as imglib;
import 'package:flutter/material.dart';
import 'package:text_masking_scanner/camera_view.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

export 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart'
    show BarcodeFormat, Barcode;

class TextMaskingScanner extends StatefulWidget {
  const TextMaskingScanner({
    required this.onDetect,
    this.useMorph = false,
    this.scanDelay,
    this.scanDelaySuccess,
    this.formats,
    this.onControllerCreated,
    super.key,
  });

  final void Function(List<Barcode> barcodes) onDetect;
  final bool useMorph;
  final Duration? scanDelay;
  final Duration? scanDelaySuccess;
  final List<BarcodeFormat>? formats;
  final Function(CameraController? controller)? onControllerCreated;

  @override
  State<TextMaskingScanner> createState() => _TextMaskingScannerState();
}

class _TextMaskingScannerState extends State<TextMaskingScanner> {
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  Uint8List? _processedImage;
  var _cameraLensDirection = CameraLensDirection.back;
  late final BarcodeScanner barcodeScanner;
  int frame = 0;

  static const _optimize = false;

  @override
  void initState() {
    super.initState();
    barcodeScanner =
        BarcodeScanner(formats: widget.formats ?? [BarcodeFormat.all]);
  }

  @override
  void dispose() async {
    _canProcess = false;
    barcodeScanner.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        CameraView(
          customPaint: _customPaint,
          onImage: _processImage,
          initialCameraLensDirection: _cameraLensDirection,
          onCameraLensDirectionChanged: (value) => _cameraLensDirection = value,
          onControllerCreated: widget.onControllerCreated,
        ),
        // Изображение, получаемое после конвертаций. Для дебага
        if (_processedImage != null)
          Padding(
            padding: const EdgeInsets.only(top: 50),
            child: Opacity(opacity: 1, child: Image.memory(_processedImage!)),
          ),
      ]),
    );
  }

  Future<void> _processImage(InputImage inputImage) async {
    if (!_canProcess) return;
    if (_isBusy) return;
    _isBusy = true;
    if (inputImage.metadata?.size != null &&
        inputImage.metadata?.rotation != null) {
      frame += 1;
      final stopwatch = Stopwatch();
      stopwatch.start();

      // Передаем в сканер изображение со скрытым текстом каждый третий кадр, чтобы увеличить производительность
      final imageForScan = frame % 3 == 0 && widget.useMorph
          ? await morphImage(inputImage)
          : inputImage;

      //Для просмотра изображения, прошедшего через все конвертации
      if (frame % 3 == 0) {
        // final rawTestRgbaImage =
        //     inputImage.metadata!.format == InputImageFormat.nv21
        //         ? decodeYUV420SP(imageForScan)
        //         : decodeBGRA8888(imageForScan);
        // _processedImage = imglib.encodeJpg(rawTestRgbaImage);
        // setState(() {});
      }

      final barcodes = await barcodeScanner.processImage(imageForScan);
      log('Frame without barcodes');
      if (barcodes.isNotEmpty) {
        widget.onDetect(barcodes);
        bool isClearedScan = frame % 3 == 0;
        frame = 0;
        log('RECOGNIZE ${isClearedScan ? 'from masked scan' : ''}: ${barcodes.first.displayValue} ${barcodes.first.format}');
        if (widget.scanDelaySuccess != null) {
          await Future.delayed(widget.scanDelaySuccess!);
        }
      } else {
        if (widget.scanDelay != null) {
          await Future.delayed(widget.scanDelay!);
        }
      }
      stopwatch.stop();
      // log('elapsed: ${stopwatch.elapsed.inMilliseconds} ms');
    }
    _isBusy = false;
  }

  Future<InputImage> morphImage(InputImage inputImage) async {
    final maskedImage = await _convertImage(inputImage);
    late final imglib.Image resultImage;

    if (_optimize) {
      final cvMat = cv.Mat.create(
        rows: maskedImage.width,
        cols: maskedImage.height,
        type: cv.MatType.CV_8UC3,
      );
      cvMat.data
          .setAll(0, maskedImage.getBytes(order: imglib.ChannelOrder.bgr));
      final cvGrayMat = cv.cvtColor(cvMat, cv.COLOR_BGR2GRAY);
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      final closed =
          cv.morphologyEx(cvGrayMat, cv.MORPH_CLOSE, kernel, iterations: 2);

      final closedBgr = cv.cvtColor(closed, cv.COLOR_GRAY2BGR);

      final bgrImageAfterMat = imglib.Image.fromBytes(
        width: maskedImage.width,
        height: maskedImage.height,
        bytes: closedBgr.data.buffer,
        numChannels: 3,
        order: imglib.ChannelOrder.bgr,
      );

      final rgbaImage = imglib.Image.fromBytes(
        width: maskedImage.width,
        height: maskedImage.height,
        bytes: bgrImageAfterMat
            .getBytes(order: imglib.ChannelOrder.rgba, alpha: 1)
            .buffer,
        numChannels: 4,
        order: imglib.ChannelOrder.rgba,
      );

      resultImage = rgbaImage;
    } else {
      final jpg = imglib.encodeJpg(maskedImage);
      final cvMat = cv.imdecode(jpg, cv.IMREAD_GRAYSCALE);
      final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      final closed =
          cv.morphologyEx(cvMat, cv.MORPH_CLOSE, kernel, iterations: 2);
      final jpgFromCv = cv.imencode('.jpg', closed);
      final morphedImage = imglib.decodeJpg(jpgFromCv.$2)!;

      resultImage = morphedImage;
    }

    // Конвертируем обратно для поиска баркодов

    final convertedMaskedImage =
        inputImage.metadata!.format == InputImageFormat.nv21
            ? rgbaToYuv420(resultImage)
            : rgbaToBgr(resultImage);

    final maskedInputImage = InputImage.fromBytes(
        bytes: convertedMaskedImage.buffer.asUint8List(),
        // Изображение с камеры андроида приходит повернутым. Но после обработки уже все развернуто
        metadata: InputImageMetadata(
          size: inputImage.metadata!.rotation != InputImageRotation.rotation0deg
              ? Size(
                  inputImage.metadata!.size.height,
                  inputImage.metadata!.size.width,
                )
              : Size(
                  inputImage.metadata!.size.width,
                  inputImage.metadata!.size.height,
                ),
          rotation: InputImageRotation.rotation0deg,
          format: inputImage.metadata!.format,
          bytesPerRow: inputImage.metadata?.bytesPerRow ?? 0, //4 // ??
        ));
    return maskedInputImage;
  }

  Future<imglib.Image> _convertImage(InputImage inputImage) async {
    final rawRgbaImage = inputImage.metadata!.format == InputImageFormat.nv21
        ? decodeYUV420SP(inputImage) //android
        : decodeBGRA8888(inputImage); //ios

    return rawRgbaImage;
  }
}

Uint8List rgbaToYuv420(imglib.Image image) {
  int yIndex = 0;

  final width = image.width;
  final height = image.height;
  final int ySize = width * height;
  final int uvSize = ySize ~/ 2;

  final Uint8List yuvPlane = Uint8List(ySize + uvSize);

  int uvIndex = width * height;

  for (int j = 0; j < height; ++j) {
    for (int i = 0; i < width; ++i) {
      final imglib.Pixel rgba = image.getPixel(i, j);
      final int r = rgba.r.toInt();
      final int g = rgba.g.toInt();
      final int b = rgba.b.toInt();

      final int y = (0.257 * r + 0.504 * g + 0.098 * b + 16).round();
      final int u = (-0.148 * r - 0.291 * g + 0.439 * b + 128).round();
      final int v = (0.439 * r - 0.368 * g - 0.071 * b + 128).round();

      yuvPlane[yIndex++] = y.clamp(0, 255);
      if ((i & 0x01) == 0 && (j & 0x01) == 0) {
        yuvPlane[uvIndex++] = v.clamp(0, 255);
        yuvPlane[uvIndex++] = u.clamp(0, 255);
      }
    }
  }

  return yuvPlane;
}

Uint8List rgbaToBgr(imglib.Image image) {
  final bgraImage = imglib.remapColors(
    image,
    red: imglib.Channel.blue,
    blue: imglib.Channel.red,
  );
  return bgraImage.buffer.asUint8List();
}

imglib.Image decodeBGRA8888(InputImage image) {
  return imglib.Image.fromBytes(
    width: image.metadata!.size.width.toInt(),
    height: image.metadata!.size.height.toInt(),
    bytes: image.bytes!.buffer,
    numChannels: 4,
    order: imglib.ChannelOrder.bgra,
  );
}

imglib.Image decodeYUV420SP(InputImage image) {
  final width = image.metadata!.size.width.toInt();
  final height = image.metadata!.size.height.toInt();

  final yuv420sp = image.bytes!;
  // The math for converting YUV to RGB below assumes you're
  // putting the RGB into a uint32. To simplify and keep the
  // code as it is, make a 4-channel Image, get the image data bytes,
  // and view it at a Uint32List. This is the equivalent to the image
  // data of the 3.x version of the Image library. It does waste some
  // memory, the alpha channel isn't used, but it simplifies the math.

  final outImg = imglib.Image(width: width, height: height, numChannels: 4);
  final outBytes = outImg.getBytes();
  // View the image data as a Uint32List.
  final rgba = Uint32List.view(outBytes.buffer);

  final frameSize = width * height;

  for (var j = 0, yp = 0; j < height; j++) {
    var uvp = frameSize + (j >> 1) * width;
    var u = 0;
    var v = 0;
    for (int i = 0; i < width; i++, yp++) {
      var y = (0xff & (yuv420sp[yp])) - 16;
      if (y < 0) {
        y = 0;
      }
      if ((i & 1) == 0) {
        v = (0xff & yuv420sp[uvp++]) - 128;
        u = (0xff & yuv420sp[uvp++]) - 128;
      }

      final y1192 = 1192 * y;
      var r = (y1192 + 1634 * v);
      var g = (y1192 - 833 * v - 400 * u);
      var b = (y1192 + 2066 * u);

      if (r < 0) {
        r = 0;
      } else if (r > 262143) {
        r = 262143;
      }
      if (g < 0) {
        g = 0;
      } else if (g > 262143) {
        g = 262143;
      }
      if (b < 0) {
        b = 0;
      } else if (b > 262143) {
        b = 262143;
      }

      // Write directly into the image data
      rgba[yp] = 0xff000000 |
          ((b << 6) & 0xff0000) |
          ((g >> 2) & 0xff00) |
          ((r >> 10) & 0xff);
    }
  }

  // Rotate the image so it's the correct oreintation.

  return imglib.copyRotate(outImg,
      angle: switch (image.metadata!.rotation) {
        InputImageRotation.rotation0deg => 0,
        InputImageRotation.rotation90deg => 90,
        InputImageRotation.rotation180deg => 180,
        InputImageRotation.rotation270deg => 270,
      });
}
