import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:vigilanter_flutter/models/report_summary.dart';
import 'package:vigilanter_flutter/services/cctv_service.dart';
import 'package:vigilanter_flutter/services/location_service.dart';
import 'package:vigilanter_flutter/services/pending_cctv_focus.dart';
import 'package:vigilanter_flutter/services/report_map_service.dart';
import 'package:vigilanter_flutter/widgets/report_summary_sheets.dart';
import 'detail_laporan_screen.dart';
import 'detection_screen.dart';
import 'rtsp_player_screen.dart';

class PetaScreen extends StatefulWidget {
  final double? focusLat;
  final double? focusLng;
  final String? focusReportId;
  final LatLng? focusLatLng;

  /// Dari notifikasi deteksi senjata: id CCTV (rtsp_id) yang harus difokuskan.
  final String? focusRtspId;

  const PetaScreen({
    this.focusLat,
    this.focusLng,
    this.focusReportId,
    this.focusLatLng,
    this.focusRtspId,
    Key? key,
  }) : super(key: key);

  @override
  State<PetaScreen> createState() => _PetaPageState();
}

class _PetaPageState extends State<PetaScreen> {
  GoogleMapController? mapController;
  TextEditingController cariLokasi = TextEditingController();
  final locationService = LocationService();
  final _reportMapService = ReportMapService();
  final _cctvService = CctvService();
  StreamSubscription? _markerSub;
  StreamSubscription? _cctvSub;
  bool _fromNotification = false;
  Key _mapKey = UniqueKey();

  LatLng _currentPos = const LatLng(3.567261, 98.650062);
  bool _isTitikRawanActive = false;

  // ===================== MARKER (DIPISAH PER JENIS) =====================
  Set<Marker> _cctvMarkers = {};
  Set<Marker> _reportMarkers = {};
  Marker? _userMarker;

  /// CCTV (hijau) selalu tampil. Marker user hanya saat Titik Rawan mati.
  Set<Marker> get markers => {
    ..._cctvMarkers,
    ..._reportMarkers,
    if (!_isTitikRawanActive && _userMarker != null) _userMarker!,
  };

  // Titik CCTV dari Firestore (rtsp_streams)
  List<CctvPoint> _cctvList = [];

  // CCTV yang harus difokuskan (dari notifikasi senjata), diproses
  // begitu data CCTV dari Firestore sudah tiba.
  String? _pendingFocusRtspId;

  @override
  void initState() {
    super.initState();

    _fromNotification = widget.focusLatLng != null ||
        (widget.focusLat != null && widget.focusLng != null);

    /// PRIORITAS FOKUS DARI NOTIF
    if (widget.focusLatLng != null) {
      _currentPos = widget.focusLatLng!;
    } else if (widget.focusLat != null && widget.focusLng != null) {
      _currentPos = LatLng(widget.focusLat!, widget.focusLng!);
    }

    /// DARI NOTIFIKASI SENJATA: id CCTV bisa datang lewat parameter
    /// atau lewat PendingCctvFocus (jalur AppNavigator.toMap).
    _pendingFocusRtspId = widget.focusRtspId ?? PendingCctvFocus.take();
    if (_pendingFocusRtspId != null) {
      _fromNotification = true; // jangan pindahkan kamera ke lokasi user
    }

    /// 1. MUAT TITIK CCTV (FIRESTORE, REALTIME)
    _startCctvStream();

    /// 2. MUAT MARKER LAPORAN (FIREBASE REAL-TIME)
    _startReportStream();
  }

  @override
  void dispose() {
    _markerSub?.cancel();
    _cctvSub?.cancel();
    cariLokasi.dispose();
    mapController?.dispose();
    super.dispose();
  }

  // ===================== CCTV (FIRESTORE) =====================
  void _startCctvStream() {
    _cctvSub?.cancel();
    _cctvSub = _cctvService.watchAllCctv().listen((list) {
      if (!mounted) return;
      setState(() {
        _cctvList = list;
        _cctvMarkers = list.map<Marker>((cctv) {
          return Marker(
            markerId: MarkerId('cctv_${cctv.id}'),
            position: LatLng(cctv.lat, cctv.lng),
            // Warna hijau untuk CCTV
            icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen),
            onTap: () => _onCctvTap(cctv),
          );
        }).toSet();
      });
      _handlePendingFocus();
    }, onError: (e) {
      debugPrint('Gagal memuat titik CCTV: $e');
    });
  }

  /// Fokus ke CCTV dari notifikasi lalu langsung tampilkan 2 opsi.
  void _handlePendingFocus() {
    final id = _pendingFocusRtspId;
    if (id == null) return;

    CctvPoint? target;
    for (final c in _cctvList) {
      if (c.id == id) {
        target = c;
        break;
      }
    }
    final cctv = target;
    if (cctv == null) return; // data belum tiba / id tidak ada

    _pendingFocusRtspId = null; // hanya sekali

    final pos = LatLng(cctv.lat, cctv.lng);
    setState(() => _currentPos = pos);
    mapController?.animateCamera(CameraUpdate.newLatLngZoom(pos, 17));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onCctvTap(cctv);
    });
  }

  // Aksi ketika marker CCTV ditekan: pilih streaming RTSP atau deteksi AI
  void _onCctvTap(CctvPoint cctv) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1C3F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam, color: Colors.green, size: 40),
              const SizedBox(height: 10),
              Text(
                cctv.nama,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (cctv.tempat.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  cctv.tempat,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
              const SizedBox(height: 20),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                ),
                icon: const Icon(Icons.videocam),
                label: const Text("Streaming Langsung (RTSP)"),
                onPressed: () {
                  Navigator.pop(context); // tutup bottom sheet
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RtspPlayerScreen(
                        title: cctv.nama,
                        rtspId: cctv.id,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepOrange,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 50),
                ),
                icon: const Icon(Icons.security),
                label: const Text("Deteksi Objek (AI)"),
                onPressed: () {
                  Navigator.pop(context); // tutup bottom sheet
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => DetectionScreen(
                        title: cctv.nama,
                        rtspId: cctv.id,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  // ===================== LAPORAN (FIREBASE) =====================
  /// Satu-satunya tempat stream laporan dimulai.
  /// Stream lama selalu dibatalkan dulu agar listener tidak menumpuk.
  void _startReportStream() {
    _markerSub?.cancel();
    _markerSub = _reportMapService
        .listenMarkers(
      _onMarkerTap,
      hanyaTitikRawan: _isTitikRawanActive,
    )
        .listen((m) {
      if (!mounted) return;
      setState(() {
        _reportMarkers = m.toSet();
      });
    });
  }

  void _onMarkerTap(ReportSummary summary) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return ReportSummarySheet(
          data: summary,
          onDetail: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DetailLaporanScreen(reportId: summary.id),
              ),
            );
          },
        );
      },
    );
  }

  // ===================== AMBIL LOKASI USER =====================
  Future<void> _loadUserLocation() async {
    Position? position = await locationService.getPosition();
    if (position == null || !mounted) return;

    final userPos = LatLng(position.latitude, position.longitude);

    setState(() {
      // Marker user hanya ditampilkan saat Titik Rawan tidak aktif
      // (diatur di getter `markers`).
      _userMarker = Marker(
        markerId: const MarkerId("userPos"),
        position: userPos,
        icon: BitmapDescriptor.defaultMarkerWithHue(
          BitmapDescriptor.hueAzure,
        ),
        infoWindow: const InfoWindow(
          title: "Lokasi Anda",
          snippet: "Posisi saat ini",
        ),
      );
    });

    // Dari notifikasi: kamera TIDAK boleh dipindah ke lokasi user
    if (_fromNotification) return;
    _currentPos = userPos;

    if (mapController != null) {
      mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(_currentPos, 16),
      );
    }
  }

  // ===================== TOGGLE TITIK RAWAN =====================
  void _toggleTitikRawan() {
    setState(() {
      _isTitikRawanActive = !_isTitikRawanActive; // Balikkan status on/off
      _reportMarkers = {}; // Kosongkan dulu, diisi ulang oleh stream
    });

    // Mulai ulang stream dengan filter yang sesuai
    _startReportStream();

    // Saat mode dimatikan, pastikan marker user muncul kembali
    if (!_isTitikRawanActive && !_fromNotification) {
      _loadUserLocation();
    }
  }

  // ===================== CARI LOKASI =====================
  Future<void> _searchLocation(String query) async {
    if (query.isEmpty) return;
    debugPrint(query);
    try {
      final locations = await locationFromAddress(query);

      if (locations.isEmpty) return;
      debugPrint(locations.first.latitude.toString());

      final loc = locations.first;
      final target = LatLng(loc.latitude, loc.longitude);

      setState(() {
        _currentPos = target;
      });

      mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(target, 16),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Lokasi tidak ditemukan"),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            bottom: 30,
            left: 16,
            right: 16,
          ),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // ===================== REFRESH =====================
  void _refreshMap() {
    mapController?.dispose();
    setState(() {
      mapController = null;
      _reportMarkers = {};
      _mapKey = UniqueKey();
    });

    _startCctvStream();
    _startReportStream();

    if (!_fromNotification) {
      _loadUserLocation();
    }
  }

  // ===================== UI =====================
  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          GoogleMap(
            key: _mapKey,
            initialCameraPosition: CameraPosition(
              target: _currentPos,
              zoom: 16,
            ),
            markers: markers,
            myLocationEnabled: false,
            onMapCreated: (controller) {
              mapController = controller;
              if (_fromNotification) {
                // Dari notifikasi: arahkan ke posisi fokus
                controller.animateCamera(
                  CameraUpdate.newLatLngZoom(_currentPos, 16),
                );
              } else {
                _loadUserLocation();
              }
              // Jika data CCTV sudah tiba sebelum peta siap
              _handlePendingFocus();
            },
          ),

          /// --------------------- SEARCH BAR ---------------------
          Positioned(
            top: 40,
            left: 20,
            right: 20,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: screenWidth * 0.05),
              height: screenHeight * 0.05,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1C3F),
                borderRadius: BorderRadius.circular(screenWidth * 0.08),
              ),
              child: Row(
                children: [
                  Icon(Icons.location_on,
                      color: Colors.white.withValues(alpha: 0.4)),
                  SizedBox(width: screenWidth * 0.02),
                  Expanded(
                    child: TextField(
                      controller: cariLokasi,
                      textInputAction: TextInputAction.search,
                      onSubmitted: _searchLocation,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4)),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: "Cari lokasi",
                        hintStyle: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          /// --------------------- BADGE KOORDINAT ---------------------
          Positioned(
            top: 120,
            left: 20,
            right: 20,
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: screenWidth * 0.03,
                    vertical: screenWidth * 0.02,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D1234),
                    borderRadius: BorderRadius.circular(screenWidth * 0.08),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.location_on,
                          color: Colors.red, size: screenWidth * 0.04),
                      SizedBox(width: screenWidth * 0.01),
                      Text(
                        "${_currentPos.latitude.toStringAsFixed(6)}, "
                            "${_currentPos.longitude.toStringAsFixed(6)}",
                        style: const TextStyle(color: Color(0xFF808094)),
                      ),
                      SizedBox(width: screenWidth * 0.01),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(
                            ClipboardData(
                              text:
                              "${_currentPos.latitude},${_currentPos.longitude}",
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                              const Text("Koordinat disalin ke clipboard!"),
                              backgroundColor: Colors.green,
                              behavior: SnackBarBehavior.floating,
                              margin: EdgeInsets.only(
                                bottom: screenHeight * 0.025,
                                left: 16,
                                right: 16,
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        child: const Icon(Icons.copy,
                            size: 16, color: Color(0xFF808094)),
                      ),
                    ],
                  ),
                ),
                const Spacer(),

                /// --------------------- TOMBOL TITIK RAWAN ---------------------
                GestureDetector(
                  onTap: _toggleTitikRawan,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: screenWidth * 0.03,
                      vertical: screenWidth * 0.02,
                    ),
                    decoration: BoxDecoration(
                      // Warna gelap dan garis tepi putih saat aktif
                      color: _isTitikRawanActive
                          ? const Color(0xFF8B0000)
                          : Colors.red,
                      borderRadius: BorderRadius.circular(screenWidth * 0.025),
                      border: Border.all(
                        color: _isTitikRawanActive
                            ? Colors.white
                            : Colors.transparent,
                        width: _isTitikRawanActive ? 1.5 : 0,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.warning,
                            size: screenWidth * 0.045, color: Colors.white),
                        SizedBox(width: screenWidth * 0.015),
                        Text(
                          "Titik Rawan",
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: screenWidth * 0.035,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              ],
            ),
          ),

          /// --------------------- TOMBOL REFRESH MAP ---------------------
          Positioned(
            bottom: screenHeight * 0.12,
            right: screenWidth * 0.04,
            child: FloatingActionButton(
              heroTag: "refresh_map",
              backgroundColor: const Color(0xFF1A1C3F),
              onPressed: _refreshMap,
              child: const Icon(Icons.refresh, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}