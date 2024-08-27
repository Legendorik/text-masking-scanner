import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:image/image.dart' as imglib;
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:text_masking_scanner/painters/coordinates_translator.dart';
import 'package:text_masking_scanner/camera_view.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'painters/text_detector_painter.dart';

class TextMaskingScanner extends StatefulWidget {
  const TextMaskingScanner({required this.onBarcodes, super.key});

  final void Function(List<Barcode> barcodes) onBarcodes;

  @override
  State<TextMaskingScanner> createState() => _TextMaskingScannerState();
}

class _TextMaskingScannerState extends State<TextMaskingScanner> {
  final _textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
  bool _canProcess = true;
  bool _isBusy = false;
  CustomPaint? _customPaint;
  Uint8List? _processedImage;
  var _cameraLensDirection = CameraLensDirection.back;
  static const List<BarcodeFormat> formats = [BarcodeFormat.dataMatrix];
  final barcodeScanner = BarcodeScanner(formats: formats);
  final stopwatch = Stopwatch();
  final stats = <String, List<Map<String, String>>>{};
  int frame = 0;

  @override
  void dispose() async {
    _canProcess = false;
    _textRecognizer.close();
    barcodeScanner.close();
    super.dispose();
  }

  // Запись результатов замеров
  void watchTap() async {
    if (stopwatch.isRunning) {
      stopwatch.stop();
      stopwatch.reset();
      setState(() {});
      final jsonString = jsonEncode(stats);
      final Directory directory = await getApplicationDocumentsDirectory();
      final File file = File('${directory.path}/default_scanner.json');
      await file.writeAsString(jsonString);
    } else {
      stats[stats.length.toString()] = [];
      stopwatch.start();
      setState(() {});
    }
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
        ),
        // Изображение, получаемое после конвертаций. Для дебага
        if (_processedImage != null)
          Padding(
            padding: const EdgeInsets.only(top: 50),
            child: Opacity(opacity: 1, child: Image.memory(_processedImage!)),
          ),
        Positioned(
          bottom: 50,
          left: 0,
          right: 0,
          child: GestureDetector(
            onTap: watchTap,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10.0),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  stopwatch.isRunning ? 'Закончить замер' : 'Начать замер',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
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

      // Передаем в сканер изображение со скрытым текстом каждый третий кадр, чтобы увеличить производительность
      final imageForScan =
          frame % 3 == 0 ? await maskTextOnImage(inputImage) : inputImage;

      //Для просмотра изображения, прошедшего через все конвертации
      if (frame % 3 == 0) {
        // final rawTestRgbaImage =
        //     inputImage.metadata!.format == InputImageFormat.nv21
        //         ? decodeYUV420SP(imageForScan)
        //         : decodeBGRA8888(imageForScan);
        // _processedImage = imglib.encodeJpg(rawTestRgbaImage);
      }

      final barcodes = await barcodeScanner.processImage(imageForScan);
      log('Frame without barcodes');
      if (barcodes.isNotEmpty) {
        widget.onBarcodes(barcodes);
        bool isClearedScan = frame % 3 == 0;
        frame = 0;
        log('RECOGNIZE ${isClearedScan ? 'from masked scan' : ''}: ${barcodes.first.displayValue} ${barcodes.first.format}');
        if (stopwatch.isRunning) {
          stats[(stats.length - 1).toString()]!.add({
            'code': barcodes.first.displayValue ?? '',
            'time': stopwatch.elapsed.toString()
          });
        }
      }
    }
    _isBusy = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<InputImage> maskTextOnImage(InputImage inputImage) async {
    // final recognizedText = await _textRecognizer.processImage(inputImage);
    final recognizedText = RecognizedText(text: '', blocks: []);
    // Отображает найденный на кадре текст. Неравнозначен маскировщику текста в _removeTexts
    // Не синхронизирован с изображением с камеры, так как срабатывает раз в три кадра, так что могут быть небольшие различия, если устройство не статично.
    // Чтобы посмотреть, как именно замазался текст на изображении, нужно раскомментировать вывод изображения после конвертаций
    _customPaint = CustomPaint(
        painter: TextRecognizerPainter(
      recognizedText,
      inputImage.metadata!.size,
      inputImage.metadata!.rotation,
      _cameraLensDirection,
    ));
    final maskedImage = await _removeTexts(inputImage, recognizedText);
    // imglib.Image.fromBytes(width: width, height: height, bytes: bytes) перебрать байты, чтобы убрать альфаканал?
    // final imageCv = cv.Mat.create()
    final jpg = imglib.encodeJpg(maskedImage);
    final cvMat = cv.imdecode(jpg, cv.IMREAD_GRAYSCALE);
    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    // final dilated = cv.dilate(cvMat, kernel, iterations: 1);
    final closed =
        cv.morphologyEx(cvMat, cv.MORPH_CLOSE, kernel, iterations: 2);
    final jpgFromCv = cv.imencode('.jpg', closed);
    final morphedImage = imglib.decodeJpg(jpgFromCv.$2)!;
    // Конвертируем обратно для поиска баркодов
    final convertedMaskedImage =
        inputImage.metadata!.format == InputImageFormat.nv21
            ? rgbToYuv420(morphedImage)
            : rgbToBgr(morphedImage);

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
          bytesPerRow: 4,
        ));
    return maskedInputImage;
  }

  Future<imglib.Image> _removeTexts(
      InputImage inputImage, RecognizedText recognizedText) async {
    final rawRgbaImage = inputImage.metadata!.format == InputImageFormat.nv21
        ? decodeYUV420SP(inputImage) //android
        : decodeBGRA8888(inputImage); //ios

    final imageSize = inputImage.metadata!.size;
    final size =
        inputImage.metadata!.rotation != InputImageRotation.rotation0deg
            ? Size(
                inputImage.metadata!.size.height,
                inputImage.metadata!.size.width,
              )
            : Size(
                inputImage.metadata!.size.width,
                inputImage.metadata!.size.height,
              );

    final rotation = inputImage.metadata!.rotation;

    for (final textBlock in recognizedText.blocks) {
      // Слишком толстые блоки -- это обычно лишний текст, который нет необходимости маскировать, и который может заслонять код
      if (textBlock.boundingBox.shortestSide < 120) {
        final List<Offset> cornerPoints = <Offset>[];
        for (final point in textBlock.cornerPoints) {
          double x = translateX(
            point.x.toDouble(),
            size,
            imageSize,
            rotation,
            _cameraLensDirection,
          );
          double y = translateY(
            point.y.toDouble(),
            size,
            imageSize,
            rotation,
            _cameraLensDirection,
          );

          if (Platform.isAndroid) {
            switch (_cameraLensDirection) {
              case CameraLensDirection.front:
                switch (rotation) {
                  case InputImageRotation.rotation0deg:
                  case InputImageRotation.rotation90deg:
                    break;
                  case InputImageRotation.rotation180deg:
                    x = size.width - x;
                    y = size.height - y;
                    break;
                  case InputImageRotation.rotation270deg:
                    x = translateX(
                      point.y.toDouble(),
                      size,
                      imageSize,
                      rotation,
                      _cameraLensDirection,
                    );
                    y = size.height -
                        translateY(
                          point.x.toDouble(),
                          size,
                          imageSize,
                          rotation,
                          _cameraLensDirection,
                        );
                    break;
                }
                break;
              case CameraLensDirection.back:
                switch (rotation) {
                  case InputImageRotation.rotation0deg:
                  case InputImageRotation.rotation270deg:
                    break;
                  case InputImageRotation.rotation180deg:
                    x = size.width - x;
                    y = size.height - y;
                    break;
                  case InputImageRotation.rotation90deg:
                    x = size.width -
                        translateX(
                          point.y.toDouble(),
                          size,
                          imageSize,
                          rotation,
                          _cameraLensDirection,
                        );
                    y = translateY(
                      point.x.toDouble(),
                      size,
                      imageSize,
                      rotation,
                      _cameraLensDirection,
                    );
                    break;
                }
                break;
              case CameraLensDirection.external:
                break;
            }
          }

          cornerPoints.add(Offset(x, y));
        }

        // Add the first point to close the polygon
        cornerPoints.add(cornerPoints.first);
        imglib.fillPolygon(
          rawRgbaImage,
          vertices: [for (final p in cornerPoints) imglib.Point(p.dx, p.dy)],
          color: imglib.ColorRgb8(255, 255, 255),
        );
      }
    }
    return rawRgbaImage;
  }
}

Uint8List rgbToYuv420(imglib.Image image) {
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

Uint8List rgbToBgr(imglib.Image image) {
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
    // numChannels: 4,??
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
