import 'dart:math';
import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:sensors/sensors.dart';

/**
 * 用DART實現的簡單gyroscope data去噪並轉換成光標xy座標的算法。
 * AUTHOR: Mangle Kuo
 * 預設的光標座標系統：左上角為(0,0)，右為x+，下為y+
 * 用到的library有：math(三角函數和基本常量如pi)、async(拿來得到當下毫秒timestamp)、sensor(得到gyroscope的data)
 */

/// 算法設定 algorithm settings
int algorithmLevel = 1; // 0: 關閉算法, 1: 開啟算法(過去一段時間內數據從新到舊加權，最後再和平均值加權)
bool isOnGlasses = false; // true: 在眼鏡上, false: 在手機上

/// 系統參數設定
double glassesScreenWidth = 1200.0; //眼鏡螢幕寬度，單位：px
double glassesScreenHeight = 600.0; //眼鏡螢幕高度，單位：px
double glassesScreenOffsetX = 0.0;  //眼鏡螢幕x平移，單位：px 如果說你的x座標最大範圍是 [A...B]，那這個值為 (B-1*A)/2-B
double glassesScreenOffsetY = 60.0; //眼鏡螢幕y平移，單位：px 如果說你的y座標最大範圍是 [A...B]，那這個值為 (B-1*A)/2-B

double phoneScreenWidth = 400.0;  //手機螢幕寬度，單位：px
double phoneScreenHeight = 900.0; //手機螢幕高度，單位：px
double phoneScreenOffsetX = 0.0;  //手機螢幕x平移，單位：px 算法同上
double phoneScreenOffsetY = 0.0;  //手機螢幕y平移，單位：px 算法同上

///定義一個基本的三維向量類 (3 dimensional vector class)
class V3d {
  double x;
  double y;
  double z;

  /// constructor
  V3d(double x, double y, double z) {
    this.x = x;
    this.y = y;
    this.z = z;
  }
}

///定義一個基本的二維向量類 (2 dimensional vector class)
class V2d {
  double x;
  double y;

  /// constructor
  V2d(double x, double y) {
    this.x = x;
    this.y = y;
  }

  /// 求兩向量的dot product
  double dotProductWith(V2d vector) {
    return this.x * vector.x + this.y * vector.y;
  }

  /// 求向量長度
  double len() {
    return sqrt(this.x * this.x + this.y * this.y);
  }

  /// 算和 input vector 的角度差，單位為度，範圍為 -180º ~ 180º
  double getAngleWith(V2d vector) {
    if (this.len() == 0 || vector.len() == 0) {
      return 0;
    } else {
      return 180 *
          acos(this.dotProductWith(vector) / (this.len() * vector.len())) /
          pi;
    }
  }
}

///算絕對值，只收double，如果語言本身的math library有可以直接用然後把這個刪掉
double abs(num) {
  return (num < 0 ? -1 * num : num);
}

///修剪XY座標到視窗內
V2d trimXYToWindow(V2d inputCoordinate) {
  V2d coordinate = new V2d( inputCoordinate.x, inputCoordinate.y);
  //Dart不需要做這件事情，只是預留給Java。因為dart是 copy by value, Java是 copy by reference

  bool isGlasses = isOnGlasses; // true: 在眼鏡上, false: 在手機上

  double gSW = glassesScreenWidth;
  double gSH = glassesScreenHeight;
  double gSOX = glassesScreenOffsetX;
  double gSOY = glassesScreenOffsetY;

  double pSW = phoneScreenWidth;
  double pSH = phoneScreenHeight;
  double pSOX = phoneScreenOffsetX;
  double pSOY = phoneScreenOffsetY;

  double leftEdge;
  double rightEdge;
  double topEdge;
  double bottomEdge;

  if (isGlasses) {
    leftEdge = -1 * gSW / 2.0 + gSOX;
    rightEdge = gSW / 2.0 + gSOX;
    topEdge = -1 * gSH / 2.0 + gSOY;
    bottomEdge = gSH / 2.0 + gSOY;
  } else {
    leftEdge = -1 * pSW / 2.0 + pSOX;
    rightEdge = pSW / 2.0 + pSOX;
    topEdge = -1 * pSH / 2.0 + pSOY;
    bottomEdge = pSH / 2.0 + pSOY;
  }

  if (coordinate.x < leftEdge) {
    coordinate.x = leftEdge;
  } else if (coordinate.x > rightEdge) {
    coordinate.x = rightEdge;
  }
  if (coordinate.y < topEdge) {
    coordinate.y = topEdge;
  } else if (coordinate.y > bottomEdge) {
    coordinate.y = bottomEdge;
  }
  return coordinate;
}

/// 簡單gyroscope data去噪並轉換成光標xy座標的class。
/// **需要的全局變量參數:** _algorithmLevel, isOnGlass_;
/// **dependencies:** _V2d, V3d, trim, abs_;
/// **constructor:** _不需要參數_;
/// **external methods:** _pushGyroData, getLastXY, pushZeroXY_;
class GyroToCursor {
  bool isGlasses = isOnGlasses; //複製"是否為眼鏡"的設定。
  int level = algorithmLevel; //複製"算法高低階"設定。

  List<V2d> rawCoords = []; //存直接從Gyroscope data轉換過來，還沒有去噪的XY座標
  List<int> T = []; //存還沒有去噪的XY座標對應的毫秒timestamp值


  /// 將gyroscope的data推進本class，只收V3d。
  /// pushGyroData()會生成未去噪的XY座標放進rawCoords[]
  void pushGyroData(V3d inputLatestGyroData) {
    V3d latestGyroData = inputLatestGyroData;
    V2d convertedRawXY; // 拿來存轉換過的、尚未去噪的生XY座標

    //一進來先砍掉0.035之下的Gyro data (此數字為XR ONE 2020/12/1上機測試得出)
    latestGyroData.x = abs(latestGyroData.x) < 0.035 ? 0 : latestGyroData.x;
    latestGyroData.y = abs(latestGyroData.y) < 0.035 ? 0 : latestGyroData.y;
    latestGyroData.z = abs(latestGyroData.z) < 0.035 ? 0 : latestGyroData.z;

    if (this.isGlasses) {
      //Glasses 眼鏡
      ///glasses Conversion Coefficient
      double glassesConvCoef = 450.0; //眼鏡座標轉換Coefficient，數字越高越敏感。

      if (this.rawCoords.length > 0) {
        convertedRawXY = V2d(
            this.rawCoords.last.x + (latestGyroData.z * -1 * glassesConvCoef),
            this.rawCoords.last.y + (latestGyroData.x * -1 * glassesConvCoef));
      } else {
        //第一筆時無需和前面的做加總
        convertedRawXY = V2d((latestGyroData.z * -1 * glassesConvCoef),
            (latestGyroData.x * -1 * glassesConvCoef));
      }
    } else {
      //Phone 手機
      ///phone Conversion Coefficient
      double phoneConvCoef = 50.0; //手機座標轉換Coefficient，數字越高越敏感。

      if (this.rawCoords.length > 0) {
        convertedRawXY = V2d(
            this.rawCoords.last.x + (latestGyroData.y * -1 * phoneConvCoef),
            this.rawCoords.last.y + (latestGyroData.x * -1 * phoneConvCoef));
      } else {
        convertedRawXY = V2d((latestGyroData.y * -1 * phoneConvCoef),
            (latestGyroData.x * -1 * phoneConvCoef));
      }
    }

    convertedRawXY = trimXYToWindow(convertedRawXY); //讓座標不要超出視窗

    this.rawCoords.add(convertedRawXY);

    int now = DateTime.now().millisecondsSinceEpoch;
    this.T.add(now);

    while (now - this.T[0] > 200) {
      //刪掉超過0.2秒以前的數據
      this.T.removeAt(0);
      this.rawCoords.removeAt(0);
    }
  }

  ///低階去噪算法
  V2d getLevel1SmoothedXY() {
    /// 低階去噪算法基本上就是在加權平均
    /// 假如你有5個點{ P1, P2, P3, P4, P5 }
    /// (P1+P2+P3+P4+P5)/5 就是在算每個點權重一樣的平均
    /// 如果你想要P1權重特別高，你就可以
    /// (100*P1+P2+P3+P4+P5)/(100+4) => (n1*P1 + n2*P2 + n3*P3 + ...) / (n_total)
    ///
    /// 這個算法就是在讓200ms內，越新的點有越高的權重，（想像颱風預測圖，越後面的歷史日期的走向對預測的走向影響越高）
    /// 最後再讓（真•平均）有一個最高的權重。（這樣每一次得到的去噪後座標不會波動太大）
    ///
    /// 就這樣。
    if (this.rawCoords.length < 1) {
      return new V2d(0.0, 0.0);
    } else {
      double xTotal = 0.0;
      double yTotal = 0.0;
      double nTotal = 0.0;

      double xSumForAveraging = 0.0;
      double ySumForAveraging = 0.0;

      double j = 1.0; //權重
      for (int i = 0; i < this.rawCoords.length; i++) {
        //從最舊的點往最新的點加
        xTotal += this.rawCoords[i].x * j;
        yTotal += this.rawCoords[i].y * j;
        nTotal += j;
        j += 1.0;

        xSumForAveraging += this.rawCoords[i].x;
        ySumForAveraging += this.rawCoords[i].y;
      }
      xTotal += xSumForAveraging /
          this.rawCoords.length.toDouble() *
          this.rawCoords.length.toDouble();
      yTotal += ySumForAveraging /
          this.rawCoords.length.toDouble() *
          this.rawCoords.length.toDouble();
      nTotal += this.rawCoords.length;

      return new V2d(xTotal / nTotal, yTotal / nTotal);
    }
  }

  /// 拿結果
  V2d getLatestXY() {
    switch (level) {
      case 0:
        {
          return this.rawCoords.last;
        }
        break;

      case 1:
        {
          return this.getLevel1SmoothedXY();
        }
        break;

      default:
        {
          return this.rawCoords.last;
        }
        break;
    }
  }

  /// 測試用，拿來塞(0.0,0.0)
  void pushZeroXY() {
    //推送到座標的List 和時間的List
    this.rawCoords.add(V2d(0.0, 0.0));

    int now = DateTime.now().millisecondsSinceEpoch;
    this.T.add(now);

    while (now - this.T[0] > 200) {
      //刪掉超過0.2秒以前的數據
      this.T.removeAt(0);
      this.rawCoords.removeAt(0);

      if (DateTime.now().millisecondsSinceEpoch - now > 200) {
        //timeout break
        break;
      }
    }
  }
}

///////////////////////////
///Initialise 一個 instance
///////////////////////////
GyroToCursor g2c = new GyroToCursor();
///////////////////////////
///Initialise 一個 instance
///////////////////////////



void tap(Offset pos){
  final result = HitTestResult();
  WidgetsBinding.instance.hitTest(result, pos);
  result.path.forEach((element) {
    element.target.handleEvent(
      PointerDownEvent(
          position: pos,
          kind: PointerDeviceKind.touch),
      element,
    );
    element.target.handleEvent(
      PointerUpEvent(
          position: pos,
          kind: PointerDeviceKind.touch),
      element,
    );
  });
}



///主程式開始
void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // Try running your application with "flutter run". You'll see the
        // application has a blue toolbar. Then, without quitting the app, try
        // changing the primarySwatch below to Colors.green and then invoke
        // "hot reload" (press "r" in the console where you ran "flutter run",
        // or simply save your changes to "hot reload" in a Flutter IDE).
        // Notice that the counter didn't reset back to zero; the application
        // is not restarted.
        primarySwatch: Colors.blue,
      ),
      home: MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  var cursor = V2d(0.0, 0.0);

  double randomness = 0.0;

  List<double> _gyroscopeValues;
  List<StreamSubscription<dynamic>> _streamSubscriptions =
  <StreamSubscription<dynamic>>[];



  @override
  Widget build(BuildContext context) {
    final List<String> gyroscope =
    _gyroscopeValues?.map((double v) => v.toStringAsFixed(6))?.toList();

    double width = MediaQuery.of(context).size.width;
    double height = MediaQuery.of(context).size.height;
    g2c.pushGyroData(V3d(0, 0, 0));

    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Stack(
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  'Gyroscope:\n $gyroscope,\n Cursor: ' +
                      cursor.x.toString() +
                      ',' +
                      cursor.y.toString() +
                      '',
                  style: TextStyle(color: Colors.white),
                ),
                FlatButton(
                  onPressed: () {
                    setState(() {
                      g2c.pushZeroXY();
                    });
                  },
                  child: Text('RESET'),
                  color: Colors.white70,
                ),
                Text(
                  'Randomness隨機量: $randomness',
                  style: TextStyle(color: Colors.white70),
                ),
                Row(
                  children: [
                    FlatButton(
                      onPressed: () {
                        setState(() {
                          if (randomness - 0.1 > 0) {
                            randomness -= 0.1;
                          } else {
                            randomness = 0.0;
                          }
                        });
                      },
                      child: Text('Random-'),
                      color: Colors.white70,
                    ),
                    FlatButton(
                      onPressed: () {
                        setState(() {
                          randomness += 0.1;
                        });
                      },
                      child: Text('Random+'),
                      color: Colors.white70,
                    ),
                  ],
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                ),
                Row(
                  children: [
                    FlatButton(
                      onPressed: () {
                        setState(() {
                          algorithmLevel = 0;
                        });
                      },
                      child: Text('level 0'),
                      color: Colors.white70,
                    ),
                    FlatButton(
                      onPressed: () {
                        setState(() {
                          algorithmLevel = 1;
                        });
                      },
                      child: Text('level 1'),
                      color: Colors.white70,
                    ),
                  ],
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                ),
              ],
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
            ),
          ),
          Positioned(
            top: height / 2.0 + cursor.y,
            left: width / 2.0 + cursor.x,
            child: Container(
              width: 6.0,
              height: 6.0,
              decoration: BoxDecoration(
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Colors.black,
    );
  }

  @override
  void dispose() {
    super.dispose();
    for (StreamSubscription<dynamic> subscription in _streamSubscriptions) {
      subscription.cancel();
    }
  }

  @override
  void initState() {
    super.initState();
    _streamSubscriptions.add(gyroscopeEvents.listen((GyroscopeEvent event) {
      setState(() {
        _gyroscopeValues = <double>[event.x, event.y, event.z];
        Random random = new Random();
        var randomised = new V3d(
            event.x +
                randomness * ((random.nextInt(1000).toDouble() - 500) / 100000),
            event.y +
                randomness * ((random.nextInt(1000).toDouble() - 500) / 100000),
            event.z +
                randomness *
                    ((random.nextInt(1000).toDouble() - 500) / 100000));

        g2c.pushGyroData(randomised);

        cursor = g2c.getLatestXY();

      });
    }));
  }
}
